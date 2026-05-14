defmodule VintageNetProxy.Interface do
  @moduledoc """
  Per-interface GenServer.

  One process per network interface. Subscribes to the interface's
  PropertyTable keys (`config`, `dhcp_options`, `connection`,
  `addresses`), keeps an `Interface.Routing` value up to date, runs
  `Fetcher.get/1` synchronously inside its own mailbox, and pushes the
  updated routing to the Selector on every change.

  All decisions — what URL to fetch, what proxy to publish, what to
  resolve a URL to — live in `VintageNetProxy.Interface.Routing`.
  This module only orchestrates: subscribe, parse the payload, hand
  to Routing, perform the fetch, log, send the result upstream.

  See the Architecture section of the README for the full picture.
  """
  use GenServer

  require Logger

  alias VintageNetProxy.{Fetcher, Intent}
  alias VintageNetProxy.Interface.Routing

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

  @doc "Synchronously fetch the current `Routing` for `iface` (blocks on its mailbox)."
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
    {:ok, {Routing.new(iface), parent}, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, {routing, parent}) do
    iface = routing.iface

    Enum.each(["config", "dhcp_options", "connection", "addresses"], fn prop ->
      VintageNet.subscribe(["interface", iface, prop])
    end)

    routing =
      routing
      |> Routing.put_connection(VintageNet.get(["interface", iface, "connection"]))
      |> apply_intent(VintageNet.get(["interface", iface, "config"]))
      |> Routing.put_dhcp_options(VintageNet.get(["interface", iface, "dhcp_options"]))
      |> Routing.put_addresses(VintageNet.get(["interface", iface, "addresses"]))
      |> maybe_fetch()

    push(parent, routing)
    {:noreply, {routing, parent}}
  end

  @impl true
  def handle_call(:get_state, _from, {routing, _parent} = ps), do: {:reply, routing, ps}

  @impl true
  def handle_info({VintageNet, ["interface", _, "config"], _o, new, _m}, ps),
    do: handle_event(ps, &apply_intent(&1, new))

  def handle_info({VintageNet, ["interface", _, "dhcp_options"], _o, new, _m}, ps),
    do: handle_event(ps, &Routing.put_dhcp_options(&1, new))

  def handle_info({VintageNet, ["interface", _, "connection"], _o, new, _m}, ps),
    do: handle_event(ps, &Routing.put_connection(&1, new))

  def handle_info({VintageNet, ["interface", _, "addresses"], _o, new, _m}, ps),
    do: handle_event(ps, &Routing.put_addresses(&1, new))

  def handle_info(_msg, ps), do: {:noreply, ps}

  # --- Internals ---

  defp handle_event({routing, parent}, change_fn) do
    routing =
      routing
      |> Routing.transition(change_fn)
      |> maybe_fetch()

    push(parent, routing)
    {:noreply, {routing, parent}}
  end

  # Normalize the VintageNet config payload into an intent; log and
  # clear on invalid input. Logging is a side effect, so it lives in
  # the shell rather than in `Intent`.
  defp apply_intent(routing, config) do
    case Intent.from_vintage_net_config(config) do
      {:ok, intent} ->
        Routing.put_intent(routing, intent)

      {:error, reason} ->
        Logger.warning("VintageNetProxy: invalid :proxy config on #{routing.iface}: #{reason}")
        Routing.put_intent(routing, nil)
    end
  end

  # Synchronous fetch inside the Interface's own mailbox. Blocking is
  # fine here — the Selector and other interfaces are unaffected. The
  # decision of whether to fetch (and the URL) comes from `Routing`;
  # the GenServer just performs it and feeds the result back.
  defp maybe_fetch(routing) do
    case Routing.fetch_target(routing) do
      nil ->
        routing

      url ->
        case Fetcher.get(url) do
          {:ok, script} ->
            Routing.cache_script(routing, script)

          {:error, reason} ->
            Logger.warning(
              "VintageNetProxy: PAC fetch failed on #{routing.iface} (#{inspect(url)}): #{inspect(reason)}"
            )

            Routing.cache_error(routing, reason)
        end
    end
  end

  defp push(parent, routing), do: send(parent, {:interface_changed, routing.iface, routing})
end
