defmodule VintageNetProxy.PAC.Predicate do
  @moduledoc """
  PAC predicate language: boolean composition (`||`, `&&`, `!`,
  parentheses) over the atom predicates real WPAD files use.

  Atoms supported:

    * `shExpMatch(host, "glob")` / `shExpMatch(url, "glob")`
    * `dnsDomainIs(host, ".suffix")`
    * `isPlainHostName(host)`
    * `localHostOrDomainIs(host, "hostdom")` — matches `host` if it
      equals `hostdom` *or* if `host` is the unqualified version
      (`intranet` matches `intranet.corp.example`)
    * `isInNet(host, "network", "mask")` — IP-literal hosts only
    * `isInNet(myIpAddress(), "network", "mask")` — checks the device's
      own IP (supplied by the caller via `:local_ip`)
    * `isInNet(dnsResolve(host), "network", "mask")` — resolves the
      URL's host via DNS first (the canonical PAC pattern for
      bypassing the proxy on internal subnets)
    * `isResolvable(host)` — true if `host` resolves to any IP
    * `weekdayRange("MON", ["FRI"], ["GMT"])` — current weekday in
      range; wraps when `wd2 < wd1` (e.g. `"FRI"`–`"MON"`)
    * `timeRange(...)` — current time-of-day in `[start, end)`;
      arities 1 / 2 (hour), 4 (hh:mm), 6 (hh:mm:ss), each
      optionally with a trailing `"GMT"`
    * `dateRange(...)` — current date in range. Arities 1, 2, 4, 6;
      args classified by type (string → month, int [1..31] → day,
      int [1000..9999] → year). Day, month, and day-month ranges
      wrap; year, month-year, and full-date ranges do not. Optional
      trailing `"GMT"`.
    * `host == "literal"` / `host === "literal"`

  Parse errors and unsupported atoms evaluate to false. That matches
  the surrounding evaluator's "rule with unmatchable predicate falls
  through" semantic — callers don't need to distinguish "false" from
  "couldn't parse" because in both cases the next rule (or the
  default) wins.
  """

  alias VintageNetProxy.PAC.{Clock, IP}

  @doc """
  Evaluate a predicate expression against runtime context.

  `opts` is a keyword list of values predicates can read:

    * `:host` — host pulled from the URL (`isPlainHostName`, etc.).
      Defaults to `""`.
    * `:url` — the full URL the host came from (`shExpMatch(url, …)`).
      Defaults to `""`.
    * `:local_ip` — the device's own IPv4 address as a dotted-quad
      string. Used by `myIpAddress()` inside `isInNet(myIpAddress(), …)`.
      Defaults to `nil` (no IP available → `myIpAddress()` resolves
      to "no IP" and the wrapping `isInNet` falls through).
    * `:resolver` — function used to evaluate `dnsResolve` /
      `isResolvable`. Signature `(String.t() -> {:ok, String.t()} |
      :error)`. Defaults to `&VintageNetProxy.PAC.DNS.resolve/1`,
      which itself returns `:error` when the cache GenServer isn't
      running (so tests that don't bring up DNS get graceful
      fall-through without having to stub).
    * `:now` — wallclock function used by `weekdayRange` /
      `timeRange`. Signature `(:utc | :local -> NaiveDateTime.t())`.
      Defaults to `&VintageNetProxy.PAC.Clock.now/1`. Tests pass a
      stub that returns a fixed time, e.g. `fn _ -> ~N[2025-01-07 14:30:00] end`.

  Parse errors and unsupported atoms evaluate to false.
  """
  @spec eval(String.t(), keyword()) :: boolean()
  def eval(expr, opts \\ []) when is_binary(expr) and is_list(opts) do
    ctx = %{
      host: Keyword.get(opts, :host, ""),
      url: Keyword.get(opts, :url, ""),
      local_ip: Keyword.get(opts, :local_ip),
      resolver: Keyword.get(opts, :resolver, &VintageNetProxy.PAC.DNS.resolve/1),
      now: Keyword.get(opts, :now, &VintageNetProxy.PAC.Clock.now/1)
    }

    with {:ok, tokens} <- tokenize(expr, []),
         {:ok, ast, []} <- parse_or(tokens) do
      evaluate(ast, ctx)
    else
      _ -> false
    end
  end

  # ---- Lexer ----

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r],
    do: tokenize(rest, acc)

  defp tokenize("||" <> rest, acc), do: tokenize(rest, [:or | acc])
  defp tokenize("&&" <> rest, acc), do: tokenize(rest, [:and | acc])
  defp tokenize("===" <> rest, acc), do: tokenize(rest, [:eq | acc])
  defp tokenize("==" <> rest, acc), do: tokenize(rest, [:eq | acc])
  defp tokenize("!" <> rest, acc), do: tokenize(rest, [:not | acc])
  defp tokenize("(" <> rest, acc), do: tokenize(rest, [:lparen | acc])
  defp tokenize(")" <> rest, acc), do: tokenize(rest, [:rparen | acc])
  defp tokenize("," <> rest, acc), do: tokenize(rest, [:comma | acc])

  defp tokenize(<<q, _::binary>> = bin, acc) when q in [?", ?'] do
    case read_string(bin) do
      {:ok, s, rest} -> tokenize(rest, [{:str, s} | acc])
      :error -> :error
    end
  end

  defp tokenize(<<c, _::binary>> = bin, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {ident, rest} = read_ident(bin, "")
    tokenize(rest, [{:ident, ident} | acc])
  end

  defp tokenize(<<c, _::binary>> = bin, acc) when c in ?0..?9 do
    {digits, rest} = read_int(bin, "")
    tokenize(rest, [{:int, String.to_integer(digits)} | acc])
  end

  defp tokenize(_, _), do: :error

  defp read_string(<<q, rest::binary>>) when q in [?", ?'],
    do: read_string_body(rest, q, "")

  defp read_string_body(<<q, rest::binary>>, q, acc), do: {:ok, acc, rest}
  defp read_string_body(<<c, rest::binary>>, q, acc), do: read_string_body(rest, q, acc <> <<c>>)
  defp read_string_body("", _, _), do: :error

  defp read_ident(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
       do: read_ident(rest, acc <> <<c>>)

  defp read_ident(rest, acc), do: {acc, rest}

  defp read_int(<<c, rest::binary>>, acc) when c in ?0..?9,
    do: read_int(rest, acc <> <<c>>)

  defp read_int(rest, acc), do: {acc, rest}

  # ---- Parser ----  (left-associative, || lowest precedence, ! highest)

  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens) do
      parse_or_rest(left, rest)
    end
  end

  defp parse_or_rest(left, [:or | rest]) do
    with {:ok, right, rest} <- parse_and(rest) do
      parse_or_rest({:or, left, right}, rest)
    end
  end

  defp parse_or_rest(left, rest), do: {:ok, left, rest}

  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_unary(tokens) do
      parse_and_rest(left, rest)
    end
  end

  defp parse_and_rest(left, [:and | rest]) do
    with {:ok, right, rest} <- parse_unary(rest) do
      parse_and_rest({:and, left, right}, rest)
    end
  end

  defp parse_and_rest(left, rest), do: {:ok, left, rest}

  defp parse_unary([:not | rest]) do
    with {:ok, inner, rest} <- parse_unary(rest) do
      {:ok, {:not, inner}, rest}
    end
  end

  defp parse_unary(tokens), do: parse_primary(tokens)

  defp parse_primary([:lparen | rest]) do
    with {:ok, ast, [:rparen | rest]} <- parse_or(rest) do
      {:ok, ast, rest}
    else
      _ -> :error
    end
  end

  defp parse_primary([{:ident, "host"}, :eq, {:str, value} | rest]),
    do: {:ok, {:eq, value}, rest}

  defp parse_primary([{:ident, name}, :lparen | rest]) do
    with {:ok, args, rest} <- parse_args(rest, []) do
      {:ok, {:call, name, args}, rest}
    end
  end

  defp parse_primary(_), do: :error

  defp parse_args([:rparen | rest], acc), do: {:ok, Enum.reverse(acc), rest}

  # Nested call: ident immediately followed by `(`. Use parse_primary
  # to consume the whole call expression as a single argument. Needed
  # for patterns like `isInNet(myIpAddress(), …)`.
  defp parse_args([{:ident, _}, :lparen | _] = tokens, acc) do
    with {:ok, call_ast, rest} <- parse_primary(tokens) do
      parse_args_more(rest, [call_ast | acc])
    end
  end

  defp parse_args([{:ident, _} = t | rest], acc), do: parse_args_more(rest, [t | acc])
  defp parse_args([{:str, _} = t | rest], acc), do: parse_args_more(rest, [t | acc])
  defp parse_args([{:int, _} = t | rest], acc), do: parse_args_more(rest, [t | acc])
  defp parse_args(_, _), do: :error

  defp parse_args_more([:rparen | rest], acc), do: {:ok, Enum.reverse(acc), rest}
  defp parse_args_more([:comma | rest], acc), do: parse_args(rest, acc)
  defp parse_args_more(_, _), do: :error

  # ---- Evaluator ----

  defp evaluate({:or, l, r}, ctx), do: evaluate(l, ctx) or evaluate(r, ctx)
  defp evaluate({:and, l, r}, ctx), do: evaluate(l, ctx) and evaluate(r, ctx)
  defp evaluate({:not, inner}, ctx), do: not evaluate(inner, ctx)

  defp evaluate({:eq, literal}, %{host: host}),
    do: String.downcase(host) == String.downcase(literal)

  defp evaluate({:call, name, args}, ctx), do: call(name, args, ctx)

  defp call("shExpMatch", [{:ident, "host"}, {:str, pattern}], %{host: host}),
    do: glob_match?(host, pattern)

  defp call("shExpMatch", [{:ident, "url"}, {:str, pattern}], %{url: url}),
    do: glob_match?(url, pattern)

  defp call("dnsDomainIs", [{:ident, "host"}, {:str, suffix}], %{host: host}),
    do: String.ends_with?(String.downcase(host), String.downcase(suffix))

  defp call("isPlainHostName", [{:ident, "host"}], %{host: host}),
    do: not String.contains?(host, ".")

  defp call("localHostOrDomainIs", [{:ident, "host"}, {:str, hostdom}], %{host: host}),
    do: local_host_or_domain_is?(host, hostdom)

  defp call("isInNet", [first, {:str, net}, {:str, mask}], ctx) do
    case resolve_to_ip(first, ctx) do
      ip when is_binary(ip) -> IP.in_net?(ip, net, mask)
      _ -> false
    end
  end

  defp call("isResolvable", [{:ident, "host"}], %{host: host, resolver: resolver}),
    do: match?({:ok, _}, resolver.(host))

  defp call("isResolvable", [{:str, hostname}], %{resolver: resolver}),
    do: match?({:ok, _}, resolver.(hostname))

  defp call("weekdayRange", args, ctx) do
    case parse_weekday_args(args) do
      {:ok, wd1, wd2, tz} -> Clock.in_weekday_range?(wd1, wd2, ctx.now.(tz))
      :error -> false
    end
  end

  defp call("timeRange", args, ctx) do
    case parse_time_args(args) do
      {:ok, h1, m1, s1, h2, m2, s2, tz} ->
        Clock.in_time_range?(h1, m1, s1, h2, m2, s2, ctx.now.(tz))

      :error ->
        false
    end
  end

  defp call("dateRange", args, ctx) do
    {core, tz} = split_gmt_suffix(args)

    case raw_values(core) do
      {:ok, values} -> Clock.in_date_range?(values, ctx.now.(tz))
      :error -> false
    end
  end

  defp call(_, _, _), do: false

  # weekdayRange args: one or two day strings, with an optional
  # trailing "GMT" picked off first. When `wd2` is absent, the range
  # is the single day.
  defp parse_weekday_args(args) do
    {core, tz} = split_gmt_suffix(args)

    case core do
      [{:str, d1}] -> {:ok, d1, d1, tz}
      [{:str, d1}, {:str, d2}] -> {:ok, d1, d2, tz}
      _ -> :error
    end
  end

  # timeRange args: integers with optional trailing "GMT". Arities
  # 1 / 2 / 4 / 6 map to single-hour / hour-range / hh:mm range /
  # hh:mm:ss range. The end of a single-arg range is hour+1 so
  # `timeRange(9)` covers 9:00:00 through 9:59:59.
  defp parse_time_args(args) do
    {core, tz} = split_gmt_suffix(args)

    case core do
      [{:int, h}] ->
        {:ok, h, 0, 0, h + 1, 0, 0, tz}

      [{:int, h1}, {:int, h2}] ->
        {:ok, h1, 0, 0, h2, 0, 0, tz}

      [{:int, h1}, {:int, m1}, {:int, h2}, {:int, m2}] ->
        {:ok, h1, m1, 0, h2, m2, 0, tz}

      [{:int, h1}, {:int, m1}, {:int, s1}, {:int, h2}, {:int, m2}, {:int, s2}] ->
        {:ok, h1, m1, s1, h2, m2, s2, tz}

      _ ->
        :error
    end
  end

  # Trailing "GMT" picks UTC; otherwise local time. Shared by
  # weekdayRange / timeRange / dateRange.
  defp split_gmt_suffix(args) do
    case List.last(args) do
      {:str, "GMT"} -> {Enum.drop(args, -1), :utc}
      _ -> {args, :local}
    end
  end

  # Unwrap a token list to raw values. `dateRange` does its own
  # type classification (string ↔ month, int ↔ day/year) inside
  # `Clock.in_date_range?/2`, so Predicate just hands over the
  # unwrapped values and lets Clock decide whether they're a valid
  # PAC shape.
  defp raw_values(tokens) do
    Enum.reduce_while(tokens, {:ok, []}, fn
      {:str, s}, {:ok, acc} -> {:cont, {:ok, acc ++ [s]}}
      {:int, n}, {:ok, acc} -> {:cont, {:ok, acc ++ [n]}}
      _, _ -> {:halt, :error}
    end)
  end

  # Reduce an `isInNet` first-argument expression to a dotted-quad
  # string. Three shapes real WPADs use:
  #
  #   * `isInNet(host, …)` — the literal identifier `host`; use the
  #     host extracted from the URL.
  #   * `isInNet(myIpAddress(), …)` — the device's own IP, supplied
  #     by the caller via `ctx.local_ip`. Returns `nil` if no local
  #     IP is available (interface down, IPv6-only, etc.).
  #   * `isInNet(dnsResolve(host), …)` — resolve the URL's host via
  #     DNS. Returns `nil` on resolution failure.
  #
  # `nil` makes the wrapping `isInNet` evaluate to false and the rule
  # fall through.
  defp resolve_to_ip({:ident, "host"}, %{host: host}), do: host

  defp resolve_to_ip({:call, "myIpAddress", []}, %{local_ip: ip}) when is_binary(ip), do: ip

  defp resolve_to_ip({:call, "dnsResolve", [{:ident, "host"}]}, %{host: host, resolver: r}),
    do: ok_or_nil(r.(host))

  defp resolve_to_ip({:call, "dnsResolve", [{:str, hostname}]}, %{resolver: r}),
    do: ok_or_nil(r.(hostname))

  defp resolve_to_ip(_, _), do: nil

  defp ok_or_nil({:ok, ip}), do: ip
  defp ok_or_nil(_), do: nil

  defp glob_match?(string, pattern) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(~r/^#{regex}$/i, string)
  end

  # `localHostOrDomainIs(host, hostdom)` matches when:
  #   * `host` equals `hostdom` exactly (e.g. host=`intranet.corp`,
  #     hostdom=`intranet.corp`), or
  #   * `host` has no dots *and* equals the first segment of `hostdom`
  #     (e.g. host=`intranet`, hostdom=`intranet.corp` → true).
  defp local_host_or_domain_is?(host, hostdom) do
    host_lc = String.downcase(host)
    hostdom_lc = String.downcase(hostdom)

    host_lc == hostdom_lc or
      (not String.contains?(host_lc, ".") and
         hostdom_lc |> String.split(".", parts: 2) |> hd() == host_lc)
  end
end
