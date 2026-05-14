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
    * `isInNet(host, "network", "mask")` — IP-literal hosts only (no DNS)
    * `host == "literal"` / `host === "literal"`

  Parse errors and unsupported atoms evaluate to false. That matches
  the surrounding evaluator's "rule with unmatchable predicate falls
  through" semantic — callers don't need to distinguish "false" from
  "couldn't parse" because in both cases the next rule (or the
  default) wins.
  """

  alias VintageNetProxy.PAC.IP

  @doc """
  Evaluate a predicate expression against runtime context.

  `opts` is a keyword list of values predicates can read:

    * `:host` — host pulled from the URL (`isPlainHostName`, etc.).
      Defaults to `""`.
    * `:url` — the full URL the host came from (`shExpMatch(url, …)`).
      Defaults to `""`.

  Future context (local IP, DNS resolver, wallclock) slots into the
  same opts shape; tests pass only the keys they need.

  Parse errors and unsupported atoms evaluate to false.
  """
  @spec eval(String.t(), keyword()) :: boolean()
  def eval(expr, opts \\ []) when is_binary(expr) and is_list(opts) do
    ctx = %{
      host: Keyword.get(opts, :host, ""),
      url: Keyword.get(opts, :url, "")
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
  defp parse_args([{:ident, _} = t | rest], acc), do: parse_args_more(rest, [t | acc])
  defp parse_args([{:str, _} = t | rest], acc), do: parse_args_more(rest, [t | acc])
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

  defp call("isInNet", [{:ident, "host"}, {:str, net}, {:str, mask}], %{host: host}),
    do: IP.in_net?(host, net, mask)

  defp call(_, _, _), do: false

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
