defmodule VintageNetProxy.Supervisor do
  @moduledoc """
  Top-level supervision tree for the proxy library.

  Children, in start order:

    1. `VintageNetProxy.InterfaceRegistry` — registry that maps an iface
       name to its `Interface` GenServer.
    2. `VintageNetProxy.PAC.DNS` — DNS cache for PAC's `dnsResolve` /
       `isResolvable` functions. Owns a named ETS table that any
       process can read from directly; reads bypass the GenServer
       mailbox so they don't serialize.
    3. `VintageNetProxy.Selector` — aggregates per-interface snapshots and
       publishes the chosen proxy value.
    4. An internal interface supervisor — one `Interface` GenServer
       per configured interface, supervised `:one_for_one` so a crash in
       one interface doesn't disturb the others.

  Top-level strategy is `:rest_for_one`: a Selector crash also restarts
  the InterfaceSupervisor (so Interfaces re-push their state to a fresh
  Selector). An Interface crash is isolated within the
  InterfaceSupervisor and doesn't ripple to siblings.

  Start it with the list of interfaces to track:

      VintageNetProxy.Supervisor.start_link(interfaces: ["eth0", "wlan0"])

  Or, more commonly, let the Application start it from config:

      config :vintage_net_proxy, interfaces: ["eth0", "wlan0"]
  """
  use Supervisor

  alias VintageNetProxy.{InterfaceSupervisor, Selector}
  alias VintageNetProxy.PAC

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interfaces = Keyword.get(opts, :interfaces, []) || []
    iface_opts = Keyword.take(opts, [:fetcher, :retry_backoff_ms])

    children = [
      {Registry, keys: :unique, name: VintageNetProxy.InterfaceRegistry},
      PAC.DNS,
      {Selector, interfaces: interfaces},
      {InterfaceSupervisor, [interfaces: interfaces] ++ iface_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
