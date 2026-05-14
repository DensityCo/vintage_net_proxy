defmodule VintageNetProxy.PAC do
  @moduledoc """
  Minimal PAC (Proxy Auto-Config) evaluator.

  Supports the subset of PAC grammar found in typical corporate WPAD files:
  a `FindProxyForURL(url, host)` body containing a chain of
  `if (predicate) return "<directive>";` rules and a final default
  `return "<directive>";`.

  Predicates are evaluated by `VintageNetProxy.PAC.Predicate` and support
  `||`, `&&`, `!`, and parentheses over these atoms:

    * `shExpMatch(host, "<glob>")` / `shExpMatch(url, "<glob>")`
    * `dnsDomainIs(host, ".suffix")` — case-insensitive suffix match
    * `isPlainHostName(host)` — host has no dot
    * `localHostOrDomainIs(host, "<hostdom>")` — matches the
      fully-qualified `hostdom`, or `host` when it's the unqualified
      form of `hostdom`
    * `isInNet(host, "<net>", "<mask>")` — IPv4 literal hosts only (no DNS)
    * `isInNet(myIpAddress(), "<net>", "<mask>")` — checks the device's
      own IPv4 (passed in via `:local_ip` on `find_proxy/3`)
    * `host == "<literal>"` / `host === "<literal>"`

  Directives supported:

    * `"DIRECT"` → `:direct`
    * `"PROXY host:port"` → `%{scheme: :http, host: host, port: port}`
    * `"HTTPS host:port"` → `%{scheme: :https, ...}`
    * `"SOCKS host:port"` / `"SOCKS4 host:port"` → `%{scheme: :socks4, ...}`
    * `"SOCKS5 host:port"` → `%{scheme: :socks5, ...}`
    * Fallback lists (`"PROXY a:1; PROXY b:2; DIRECT"`) — only the first
      recognized entry is returned. Per-request failover is the caller's
      responsibility.

  Anything outside this subset (parse error, unsupported atom, malformed
  predicate) evaluates to false and the rule falls through.

  ## Result shape

  `find_proxy/2` returns `{:ok, directive}` when the script produced a
  decisive answer — either a rule's predicate matched, or the script's
  default fired — and `{:error, :pac_fallthrough}` when neither
  happened (no rule matched *and* no default could be extracted). The
  fall-through case is logged at `:warning` because it indicates the
  script was malformed or used syntax this evaluator silently skips;
  the parser itself couldn't reach a verdict.

  The library treats the rule vs. default distinction as PAC's
  internal business. "PAC's default is `DIRECT`" is just what the
  script says — whether that's wrong for a given deployment is a
  policy question and belongs in CI-level lints over the PAC source,
  not in a runtime branch here.
  """

  require Logger

  alias VintageNetProxy.PAC.Predicate

  @type proxy_descriptor :: %{
          required(:scheme) => :http | :https | :socks4 | :socks5,
          required(:host) => String.t(),
          required(:port) => pos_integer()
        }

  @type directive :: :direct | proxy_descriptor()

  @type result :: {:ok, directive()} | {:error, :pac_fallthrough}

  @if_re ~r/if\s*\(\s*(.+?)\s*\)\s*\{?\s*return\s*["']([^"']+)["']/us
  @return_re ~r/return\s*["']([^"']+)["']/u

  @doc """
  Evaluate `script` for the given `url`.

  Options:

    * `:local_ip` — the device's own IPv4 address as a dotted-quad
      string. Required for PAC scripts that use `myIpAddress()`
      (typically inside `isInNet(myIpAddress(), …)` for
      subnet-aware routing). When absent or `nil`, `myIpAddress()`
      evaluates to "no IP," `isInNet` returns false, and the rule
      falls through.

  Future context (DNS resolver, wallclock for `weekdayRange`, etc.)
  will slot into the same opts.
  """
  @spec find_proxy(String.t(), String.t(), keyword()) :: result()
  def find_proxy(script, url, opts \\ [])
      when is_binary(script) and is_binary(url) and is_list(opts) do
    script = strip_comments(script)
    host = host_from_url(url)
    rules = extract_rules(script)
    eval_opts = [host: host, url: url] ++ opts

    matched =
      Enum.find_value(rules, fn {expr, directive} ->
        if Predicate.eval(expr, eval_opts), do: directive
      end)

    cond do
      matched -> {:ok, parse_directive(matched)}
      default = extract_default(script) -> {:ok, parse_directive(default)}
      true -> fallthrough(url)
    end
  end

  defp fallthrough(url) do
    Logger.warning(
      "VintageNetProxy.PAC: no rules and no default matched for #{inspect(url)}",
      pac: :fallthrough,
      url: url
    )

    {:error, :pac_fallthrough}
  end

  # Strip JS-style line (`// ...`) and block (`/* ... */`) comments,
  # but only when they appear outside string literals. URL-pattern
  # rules like `shExpMatch(url, "https://*")` carry `//` inside
  # strings, so a naïve regex replacement would cut the rest of the
  # rule along with the false-positive comment. Walk the script
  # char by char, tracking whether we're inside a `"` or `'` string,
  # and only recognize comment starts in code state. Escape sequences
  # (`\"`, `\'`, `\\`) inside strings are honored so a `"foo\"bar"`
  # doesn't terminate prematurely.
  defp strip_comments(script) do
    script |> walk(:code, []) |> IO.iodata_to_binary()
  end

  defp walk("", _state, acc), do: Enum.reverse(acc)

  defp walk("//" <> rest, :code, acc), do: walk(rest, :line_comment, [?\s | acc])
  defp walk("/*" <> rest, :code, acc), do: walk(rest, :block_comment, [?\s | acc])

  defp walk(<<q, rest::binary>>, :code, acc) when q in [?", ?'],
    do: walk(rest, {:string, q}, [q | acc])

  defp walk(<<c, rest::binary>>, :code, acc), do: walk(rest, :code, [c | acc])

  defp walk("\n" <> rest, :line_comment, acc), do: walk(rest, :code, [?\n | acc])
  defp walk(<<_, rest::binary>>, :line_comment, acc), do: walk(rest, :line_comment, acc)

  defp walk("*/" <> rest, :block_comment, acc), do: walk(rest, :code, acc)
  defp walk(<<_, rest::binary>>, :block_comment, acc), do: walk(rest, :block_comment, acc)

  defp walk(<<q, rest::binary>>, {:string, q}, acc), do: walk(rest, :code, [q | acc])

  defp walk(<<?\\, c, rest::binary>>, {:string, _} = s, acc),
    do: walk(rest, s, [c, ?\\ | acc])

  defp walk(<<c, rest::binary>>, {:string, _} = s, acc), do: walk(rest, s, [c | acc])

  defp extract_rules(script) do
    @if_re
    |> Regex.scan(script, capture: :all_but_first)
    |> Enum.map(fn [expr, directive] -> {expr, directive} end)
  end

  defp extract_default(script) do
    case Regex.scan(@return_re, script, capture: :all_but_first) do
      [] -> nil
      matches -> matches |> List.last() |> hd()
    end
  end

  defp host_from_url(url) do
    case URI.parse(url) do
      %URI{host: h} when is_binary(h) -> h
      _ -> ""
    end
  end

  defp parse_directive(s) do
    s
    |> String.split(";")
    |> Enum.map(&parse_one/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [first | _] -> first
      [] -> :direct
    end
  end

  defp parse_one(s) do
    case String.split(s) do
      [] -> nil
      [word] -> if String.upcase(word) == "DIRECT", do: :direct
      [scheme_str, host_port] -> parse_proxy(scheme_str, host_port)
      _ -> nil
    end
  end

  defp parse_proxy(scheme_str, host_port) do
    with scheme when not is_nil(scheme) <- scheme_atom(scheme_str),
         [host, port_str] when host != "" <- String.split(host_port, ":", parts: 2),
         {port, ""} when port > 0 <- Integer.parse(port_str) do
      %{scheme: scheme, host: host, port: port}
    else
      _ -> nil
    end
  end

  defp scheme_atom(str) do
    case String.upcase(str) do
      "PROXY" -> :http
      # `HTTP` is an alias for `PROXY` used by some PAC authors.
      "HTTP" -> :http
      "HTTPS" -> :https
      "SOCKS" -> :socks4
      "SOCKS4" -> :socks4
      "SOCKS5" -> :socks5
      _ -> nil
    end
  end
end
