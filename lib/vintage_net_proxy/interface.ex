defmodule VintageNetProxy.Interface do
  @moduledoc """
  Per-interface GenServer.

  One process per network interface. Subscribes to the interface's
  PropertyTable keys (`config`, `dhcp_options`, `connection`,
  `addresses`), keeps an `Interface.Proxy` value up to date, runs the
  injected `fetcher` synchronously inside its own mailbox, and pushes
  the updated proxy to the Selector on every change.

  All decisions — what URL to fetch, what proxy to publish, what to
  resolve a URL to — live in `VintageNetProxy.Interface.Proxy`. The
  shell here only subscribes, reads the raw payloads, dispatches them
  through `Proxy.put_*` functions, supplies the fetcher, schedules
  retries on transient failures, and forwards the result.

  ### PAC fetch retry

  PAC fetches can fail transiently — most commonly a DNS race where
  `dhcp_options` delivers the WPAD URL milliseconds before
  `wpad.<domain>` becomes resolvable. `Proxy.refresh_cache/2` doesn't
  store the error, so without help the interface would sit at
  `pac_script: nil` until the next VintageNet event happened to nudge
  it. We avoid that: whenever `refresh_cache/2` leaves `pac_script`
  unset *and* `effective_pac_url/1` is non-nil, the interface
  schedules `:retry_fetch` with exponential backoff. Any inbound
  VintageNet event cancels the pending retry and resets the attempt
  counter — a real state change should re-fetch immediately. Success
  cancels the chain.

  See the Architecture section of the README for the full picture.
  """
  use GenServer
  require Logger

  alias VintageNetProxy.Fetcher
  alias VintageNetProxy.Interface.Proxy

  @default_backoff_ms [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000]

  defmodule State do
    @moduledoc false
    defstruct [:proxy, :parent, :fetcher, :backoff_ms, :retry_ref, retry_attempt: 0]
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
    fetcher = Keyword.get(opts, :fetcher, &Fetcher.get/1)
    backoff_ms = Keyword.get(opts, :retry_backoff_ms, @default_backoff_ms)

    state = %State{
      proxy: Proxy.new(iface),
      parent: parent,
      fetcher: fetcher,
      backoff_ms: backoff_ms
    }

    {:ok, state, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, %State{proxy: proxy, fetcher: fetcher} = state) do
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
      |> Proxy.refresh_cache(fetcher)

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

  def handle_info(:retry_fetch, %State{proxy: proxy, fetcher: fetcher} = state) do
    proxy = Proxy.refresh_cache(proxy, fetcher)
    push(state.parent, proxy)

    state = %{state | proxy: proxy, retry_ref: nil, retry_attempt: state.retry_attempt + 1}
    {:noreply, maybe_schedule_retry(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---

  defp handle_event(%State{fetcher: fetcher} = state, change_fn) do
    state = cancel_retry(state)

    proxy =
      state.proxy
      |> Proxy.transition(change_fn)
      |> Proxy.refresh_cache(fetcher)

    push(state.parent, proxy)
    {:noreply, maybe_schedule_retry(%{state | proxy: proxy, retry_attempt: 0})}
  end

  # `Proxy.fetch_target/1` is the functional-core predicate for "is a
  # fetch still owed?" — `:none` covers both success (script cached)
  # and no-URL (intent isn't auto, link is down, no WPAD source). The
  # shell only has to translate that into "schedule a retry timer or
  # don't."
  defp maybe_schedule_retry(%State{proxy: proxy} = state) do
    case Proxy.fetch_target(proxy) do
      :none -> state
      {:ok, _url} -> schedule_retry(state)
    end
  end

  defp schedule_retry(%State{proxy: proxy} = state) do
    delay = retry_delay(state)
    ref = Process.send_after(self(), :retry_fetch, delay)

    Logger.debug(fn ->
      "VintageNetProxy.Interface(#{proxy.iface}): PAC fetch did not populate cache; " <>
        "retrying in #{delay}ms (attempt #{state.retry_attempt + 1})"
    end)

    %{state | retry_ref: ref}
  end

  defp cancel_retry(%State{retry_ref: nil} = state), do: state

  defp cancel_retry(%State{retry_ref: ref} = state) do
    Process.cancel_timer(ref)
    flush_retry()
    %{state | retry_ref: nil}
  end

  defp flush_retry do
    receive do
      :retry_fetch -> :ok
    after
      0 -> :ok
    end
  end

  defp retry_delay(%State{backoff_ms: schedule, retry_attempt: attempt}) do
    Enum.at(schedule, min(attempt, length(schedule) - 1))
  end

  defp push(parent, proxy), do: send(parent, {:interface_changed, proxy.iface, proxy})
end
