defmodule VintageNetProxy.Interface do
  @moduledoc """
  Per-interface GenServer.

  One process per network interface. Subscribes to the interface's
  PropertyTable keys (`config`, `dhcp_options`, `connection`,
  `addresses`), keeps an `Interface.Proxy` value up to date, runs
  `Fetcher.get/1` synchronously inside its own mailbox, and pushes
  the updated proxy to the Selector on every change.

  All decisions — what URL to fetch, what proxy to publish, what to
  resolve a URL to — live in `VintageNetProxy.Interface.Proxy`. The
  shell here only subscribes, reads the raw payloads, dispatches them
  through `Proxy.put_*` functions, schedules retries on transient
  failures, and forwards the result.

  ### PAC fetch retry

  PAC fetches can fail transiently — most commonly a DNS race where
  `dhcp_options` delivers the WPAD URL milliseconds before
  `wpad.<domain>` becomes resolvable. `Proxy.refresh_cache/2` doesn't
  store the error, so without help the interface would sit at
  `pac_script: nil` until the next VintageNet event happened to nudge
  it. We avoid that: whenever `Proxy.fetch_target/1` reports a fetch
  is still owed after `refresh_cache/2`, the interface schedules a
  `{:retry_fetch, token}` message on a backoff schedule. Each
  scheduled retry carries a fresh token; the handler only acts when
  the token matches the state's current one, so a VintageNet event
  invalidates pending retries by simply clearing the token. Success
  ends the chain.

  The backoff schedule defaults to `[1s, 2s, 4s, 8s, 16s, 32s, 60s]`
  (caps at 60s thereafter) and is overridable via
  `config :vintage_net_proxy, :retry_backoff_ms, [...]` — mainly used
  by the test suite to shrink delays.

  See the Architecture section of the README for the full picture.
  """
  use GenServer
  require Logger

  alias VintageNetProxy.Fetcher
  alias VintageNetProxy.Interface.Proxy

  @default_backoff_ms [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000]

  defmodule State do
    @moduledoc false
    defstruct [:proxy, :parent, :retry_token, retry_attempt: 0]
  end

  # --- Client API ---

  def start_link(opts) do
    iface = Keyword.fetch!(opts, :iface)
    GenServer.start_link(__MODULE__, opts, name: via(iface))
  end

  def child_spec(opts) do
    iface = Keyword.fetch!(opts, :iface)

    %{
      id: {__MODULE__, iface},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc "Synchronously fetch the current `Proxy` for `iface` (blocks on its mailbox)."
  def get(iface), do: GenServer.call(via(iface), :get_state)

  defp via(iface), do: {:via, Registry, {VintageNetProxy.InterfaceRegistry, iface}}

  # --- GenServer ---

  # Keep `init` a no-op: just stash the iface and parent on the
  # struct and hand off to `handle_continue/2`. All the actual work —
  # PropertyTable subscriptions, reading current values, the PAC
  # fetch — happens after init returns, so `Supervisor.start_link`
  # comes back in microseconds regardless of VintageNet's
  # responsiveness or whether the network is up.
  @impl true
  def init(opts) do
    iface = Keyword.fetch!(opts, :iface)
    parent = Keyword.fetch!(opts, :parent)
    state = %State{proxy: Proxy.new(iface), parent: parent}
    {:ok, state, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, %State{proxy: proxy} = state) do
    iface = proxy.iface

    Enum.each(["config", "dhcp_options", "connection", "addresses"], fn prop ->
      VintageNet.subscribe(["interface", iface, prop])
    end)

    proxy =
      proxy
      |> Proxy.put_connection(VintageNet.get(["interface", iface, "connection"]))
      |> Proxy.put_intent_from_config(VintageNet.get(["interface", iface, "config"]))
      |> Proxy.put_dhcp_options(VintageNet.get(["interface", iface, "dhcp_options"]))
      |> Proxy.put_addresses(VintageNet.get(["interface", iface, "addresses"]))
      |> Proxy.refresh_cache(&Fetcher.get/1)

    push(state.parent, proxy)
    {:noreply, maybe_schedule_retry(%{state | proxy: proxy})}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state.proxy, state}

  @impl true
  def handle_info({VintageNet, ["interface", _, "config"], _o, new, _m}, state),
    do: handle_event(state, &Proxy.put_intent_from_config(&1, new))

  def handle_info({VintageNet, ["interface", _, "dhcp_options"], _o, new, _m}, state),
    do: handle_event(state, &Proxy.put_dhcp_options(&1, new))

  def handle_info({VintageNet, ["interface", _, "connection"], _o, new, _m}, state),
    do: handle_event(state, &Proxy.put_connection(&1, new))

  def handle_info({VintageNet, ["interface", _, "addresses"], _o, new, _m}, state),
    do: handle_event(state, &Proxy.put_addresses(&1, new))

  def handle_info(
        {:retry_fetch, token},
        %State{retry_token: token, proxy: proxy} = state
      ) do
    proxy = Proxy.refresh_cache(proxy, &Fetcher.get/1)
    push(state.parent, proxy)

    state = %{state | proxy: proxy, retry_token: nil, retry_attempt: state.retry_attempt + 1}
    {:noreply, maybe_schedule_retry(state)}
  end

  # Stale retry from a timer that fired after a VintageNet event cleared
  # the token. Ignore — the event already drove a fresh refresh_cache.
  def handle_info({:retry_fetch, _stale}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---

  # Any VintageNet event nils the retry token (invalidating any pending
  # timer) and resets the attempt counter, then re-evaluates whether a
  # fresh retry is owed against the post-event state.
  defp handle_event(state, change_fn) do
    proxy =
      state.proxy
      |> Proxy.transition(change_fn)
      |> Proxy.refresh_cache(&Fetcher.get/1)

    push(state.parent, proxy)
    {:noreply, maybe_schedule_retry(%{state | proxy: proxy, retry_token: nil, retry_attempt: 0})}
  end

  # `Proxy.fetch_target/1` is the functional-core predicate for "is a
  # fetch still owed?" — `:none` covers both success (script cached)
  # and no-URL (intent isn't auto, link is down, no WPAD source). The
  # shell only has to translate that into "schedule a retry or don't."
  defp maybe_schedule_retry(%State{proxy: proxy} = state) do
    case Proxy.fetch_target(proxy) do
      :none -> state
      {:ok, _url} -> schedule_retry(state)
    end
  end

  defp schedule_retry(%State{proxy: proxy} = state) do
    delay = retry_delay(state)
    token = make_ref()
    Process.send_after(self(), {:retry_fetch, token}, delay)

    Logger.debug(fn ->
      "VintageNetProxy.Interface(#{proxy.iface}): PAC fetch did not populate cache; " <>
        "retrying in #{delay}ms (attempt #{state.retry_attempt + 1})"
    end)

    %{state | retry_token: token}
  end

  defp retry_delay(%State{retry_attempt: attempt}) do
    schedule = Application.get_env(:vintage_net_proxy, :retry_backoff_ms, @default_backoff_ms)
    Enum.at(schedule, min(attempt, length(schedule) - 1))
  end

  defp push(parent, proxy), do: send(parent, {:interface_changed, proxy.iface, proxy})
end
