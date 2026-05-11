defmodule VintageNetProxy.Supervisor do
  @moduledoc """
  Top-level supervision tree for the proxy library.

  Owns a single child — `VintageNetProxy.Selector` — which holds
  per-interface state, subscribes to the relevant VintageNet
  PropertyTable keys, picks the active interface, and publishes the
  global `["proxy", "config"]` property.

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
    Supervisor.init([{VintageNetProxy.Selector, interfaces: interfaces}], strategy: :one_for_one)
  end
end
