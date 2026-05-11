defmodule VintageNetProxy.PAC do
  @moduledoc """
  Minimal PAC (Proxy Auto-Config) evaluator.

  Supports the subset of PAC grammar found in typical corporate WPAD files:
  a `FindProxyForURL(url, host)` body containing a chain of
  `if (predicate) return "<directive>";` rules and a final default
  `return "<directive>";`.

  Predicates are evaluated by `VintageNetProxy.PAC.Predicate` and support
  `||`, `&&`, `!`, and parentheses over these atoms:

    * `shExpMatch(host, "<glob>")` — `*` and `?` wildcards
    * `dnsDomainIs(host, ".suffix")` — case-insensitive suffix match
    * `isPlainHostName(host)` — host has no dot
    * `isInNet(host, "<net>", "<mask>")` — IPv4 literal hosts only (no DNS)
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
  predicate) evaluates to false and the rule falls through. Malformed
  scripts return `:direct`.
  """

  alias VintageNetProxy.PAC.Predicate

  @type proxy_descriptor :: %{
          required(:scheme) => :http | :https | :socks4 | :socks5,
          required(:host) => String.t(),
          required(:port) => pos_integer()
        }

  @type directive :: :direct | proxy_descriptor()

  @if_re ~r/if\s*\(\s*(.+?)\s*\)\s*\{?\s*return\s*["']([^"']+)["']/us
  @return_re ~r/return\s*["']([^"']+)["']/u

  @spec find_proxy(String.t(), String.t()) :: directive()
  def find_proxy(script, url) when is_binary(script) and is_binary(url) do
    host = host_from_url(url)
    rules = extract_rules(script)

    matched =
      Enum.find_value(rules, fn {expr, directive} ->
        if Predicate.eval(expr, host), do: directive
      end)

    (matched || extract_default(script) || "DIRECT")
    |> parse_directive()
  end

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
      "HTTPS" -> :https
      "SOCKS" -> :socks4
      "SOCKS4" -> :socks4
      "SOCKS5" -> :socks5
      _ -> nil
    end
  end
end
