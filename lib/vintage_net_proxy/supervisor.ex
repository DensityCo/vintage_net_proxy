defmodule VintageNetProxy.Supervisor do
  @moduledoc """
  Top-level supervision tree for the proxy library.

  Children, in :rest_for_one order:

    1. `VintageNetProxy.Registry` — maps interface names to Interface pids.
    2. `VintageNetProxy.InterfaceSupervisor` — `DynamicSupervisor` that
       owns one `VintageNetProxy.Interface` per tracked interface.
    3. `VintageNetProxy.Selector` — singleton that aggregates per-interface
       snapshots, picks the active interface, and publishes the global
       `["proxy", "config"]` property.

  Start it with the list of interfaces to track:

      VintageNetProxy.Supervisor.start_link(interfaces: ["eth0", "wlan0"])

  Or, more commonly, let the Application start it from config:

      config :vintage_net_proxy, interfaces: ["eth0", "wlan0"]
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interfaces = Keyword.get(opts, :interfaces, [])

    children = [
      {Registry, keys: :unique, name: VintageNetProxy.Registry},
      {DynamicSupervisor, name: VintageNetProxy.InterfaceSupervisor, strategy: :one_for_one},
      {VintageNetProxy.Selector, interfaces: interfaces}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
