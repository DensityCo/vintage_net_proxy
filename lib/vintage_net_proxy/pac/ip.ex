defmodule VintageNetProxy.PAC.IP do
  @moduledoc """
  IPv4 helpers for the limited `isInNet()` subset this library supports:
  match only when the host is already an IPv4 literal. No DNS
  resolution — embedding blocking name resolution inside PAC evaluation
  would defeat the offline/synchronous guarantees the rest of the
  library relies on.
  """

  import Bitwise

  @doc """
  True iff `host` is an IPv4 literal that falls inside `network`/`mask`.
  Returns false for non-literal hosts (DNS names) — by design.
  """
  @spec in_net?(String.t(), String.t(), String.t()) :: boolean()
  def in_net?(host, network, mask) do
    with {:ok, h} <- parse(host),
         {:ok, n} <- parse(network),
         {:ok, m} <- parse(mask) do
      band(h, m) == band(n, m)
    else
      _ -> false
    end
  end

  @doc "Parse a dotted-quad IPv4 string into a 32-bit integer."
  @spec parse(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse(s) when is_binary(s) do
    with [a, b, c, d] <- String.split(s, "."),
         {:ok, a} <- octet(a),
         {:ok, b} <- octet(b),
         {:ok, c} <- octet(c),
         {:ok, d} <- octet(d) do
      {:ok, bsl(a, 24) ||| bsl(b, 16) ||| bsl(c, 8) ||| d}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  defp octet(s) do
    case Integer.parse(s) do
      {n, ""} when n in 0..255 -> {:ok, n}
      _ -> :error
    end
  end
end
