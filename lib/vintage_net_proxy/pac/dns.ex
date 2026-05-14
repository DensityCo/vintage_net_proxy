defmodule VintageNetProxy.PAC.DNS do
  @moduledoc """
  DNS resolver for PAC's `dnsResolve` and `isResolvable` functions.

  Wraps `:inet_res.lookup/4` with an ETS-backed cache (60s TTL on
  hits, 10s on misses) and a 500ms per-call timeout. The cache is
  owned by a tiny GenServer in `VintageNetProxy.Supervisor`'s child
  list.

  When the cache GenServer isn't running (unit tests that don't bring
  up the supervision tree), `resolve/1` returns `:error` instead of
  crashing — which matches PAC's "function returned false → rule
  falls through" semantics, so any predicate test that doesn't care
  about DNS Just Works.

  IPv4 literals short-circuit: `resolve("10.1.2.3")` returns
  `{:ok, "10.1.2.3"}` without touching DNS or the cache. This is the
  conventional PAC behavior — passing an already-resolved IP through
  `dnsResolve` should be a no-op.
  """

  use GenServer

  @table __MODULE__
  @positive_ttl 60_000
  @negative_ttl 10_000
  @timeout 500

  @doc """
  Resolve `host` to a dotted-quad IPv4 string.

  Returns `{:ok, ip}` on success or `:error` when resolution fails
  (DNS error, timeout, no A record, cache GenServer not running).
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | :error
  def resolve(host) when is_binary(host) do
    case :inet.parse_ipv4_address(String.to_charlist(host)) do
      {:ok, _} -> {:ok, host}
      _ -> cached_resolve(host)
    end
  end

  defp cached_resolve(host) do
    case :ets.whereis(@table) do
      :undefined ->
        :error

      _ref ->
        now = System.monotonic_time(:millisecond)

        case :ets.lookup(@table, host) do
          [{^host, value, expires_at}] when expires_at > now -> value
          _ -> resolve_and_cache(host, now)
        end
    end
  end

  defp resolve_and_cache(host, now) do
    result =
      case :inet_res.lookup(String.to_charlist(host), :in, :a, timeout: @timeout) do
        [{a, b, c, d} | _] -> {:ok, "#{a}.#{b}.#{c}.#{d}"}
        _ -> :error
      end

    ttl = if match?({:ok, _}, result), do: @positive_ttl, else: @negative_ttl
    :ets.insert(@table, {host, result, now + ttl})
    result
  end

  @doc false
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
