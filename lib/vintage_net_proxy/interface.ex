defmodule VintageNetProxy.Interface do
  @moduledoc """
  Per-interface GenServer.

  One process per network interface. Subscribes to the interface's
  PropertyTable keys (`config`, `dhcp_options`, `connection`,
  `addresses`), keeps an `Interface.Proxy` value up to date, runs
  `Fetcher.get/1` synchronously inside its own mailbox, and pushes the
  updated proxy to the Selector on every change.

  All decisions — what URL to fetch, what proxy to publish, what to
  resolve a URL to — live in `VintageNetProxy.Interface.Proxy`.
  This module only orchestrates: subscribe, parse the payload, hand
  to Proxy, perform the fetch, log, send the result upstream.

  See the Architecture section of the README for the full picture.
  """
  use GenServer

  require Logger

  alias VintageNetProxy.{Fetcher, Intent}
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
      |> apply_intent(VintageNet.get(["interface", iface, "config"]))
      |> Proxy.put_dhcp_options(VintageNet.get(["interface", iface, "dhcp_options"]))
      |> Proxy.put_addresses(VintageNet.get(["interface", iface, "addresses"]))
      |> maybe_fetch()

    push(parent, proxy)
    {:noreply, {proxy, parent}}
  end

  @impl true
  def handle_call(:get_state, _from, {proxy, _parent} = ps), do: {:reply, proxy, ps}

  @impl true
  def handle_info({VintageNet, ["interface", _, "config"], _o, new, _m}, ps),
    do: handle_event(ps, &apply_intent(&1, new))

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
      |> maybe_fetch()

    push(parent, proxy)
    {:noreply, {proxy, parent}}
  end

  # Normalize the VintageNet config payload into an intent; log and
  # clear on invalid input. Logging is a side effect, so it lives in
  # the shell rather than in `Intent`.
  defp apply_intent(proxy, config) do
    case Intent.from_vintage_net_config(config) do
      {:ok, intent} ->
        Proxy.put_intent(proxy, intent)

      {:error, reason} ->
        Logger.warning("VintageNetProxy: invalid :proxy config on #{proxy.iface}: #{reason}")
        Proxy.put_intent(proxy, nil)
    end
  end

  # Synchronous fetch inside the Interface's own mailbox. Blocking is
  # fine here — the Selector and other interfaces are unaffected. The
  # decision of whether to fetch (and the URL) comes from `Proxy`,
  # the failure logging from `Fetcher`; this just dispatches the
  # result back to the proxy's cache.
  defp maybe_fetch(proxy) do
    with {:ok, url} <- Proxy.fetch_target(proxy),
         {:ok, script} <- Fetcher.get(url) do
      Proxy.cache_script(proxy, script)
    else
      _ -> proxy
    end
  end

  defp push(parent, proxy), do: send(parent, {:interface_changed, proxy.iface, proxy})
end
