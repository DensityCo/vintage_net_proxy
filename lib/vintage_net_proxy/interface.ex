defmodule VintageNetProxy.Interface do
  @moduledoc """
  Per-interface GenServer.

  One process per network interface. Subscribes to the interface's
  PropertyTable keys (`config`, `dhcp_options`, `connection`,
  `addresses`), keeps an `Interface.Proxy` value up to date, runs
  `Fetcher.get/1` synchronously inside its own mailbox, and pushes the
  updated proxy to the Selector on every change.

  All decisions — what URL to fetch, what proxy to publish, what to
  resolve a URL to — live in `VintageNetProxy.Interface.Proxy`. The
  shell here only subscribes, reads the raw payloads, dispatches them
  through `Proxy.put_*` functions, supplies the real fetcher, and
  forwards the result.

  See the Architecture section of the README for the full picture.
  """
  use GenServer

  alias VintageNetProxy.Fetcher
  alias VintageNetProxy.Interface.Proxy

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
    {:ok, {Proxy.new(iface), parent}, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, {proxy, parent}) do
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

    push(parent, proxy)
    {:noreply, {proxy, parent}}
  end

  @impl true
  def handle_call(:get_state, _from, {proxy, _parent} = ps), do: {:reply, proxy, ps}

  @impl true
  def handle_info({VintageNet, ["interface", _, "config"], _o, new, _m}, ps),
    do: handle_event(ps, &Proxy.put_intent_from_config(&1, new))

  def handle_info({VintageNet, ["interface", _, "dhcp_options"], _o, new, _m}, ps),
    do: handle_event(ps, &Proxy.put_dhcp_options(&1, new))

  def handle_info({VintageNet, ["interface", _, "connection"], _o, new, _m}, ps),
    do: handle_event(ps, &Proxy.put_connection(&1, new))

  def handle_info({VintageNet, ["interface", _, "addresses"], _o, new, _m}, ps),
    do: handle_event(ps, &Proxy.put_addresses(&1, new))

  def handle_info(_msg, ps), do: {:noreply, ps}

  # --- Internals ---

  defp handle_event({proxy, parent}, change_fn) do
    proxy =
      proxy
      |> Proxy.transition(change_fn)
      |> Proxy.refresh_cache(&Fetcher.get/1)

    push(parent, proxy)
    {:noreply, {proxy, parent}}
  end

  defp push(parent, proxy), do: send(parent, {:interface_changed, proxy.iface, proxy})
end
