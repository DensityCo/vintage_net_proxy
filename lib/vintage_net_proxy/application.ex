defmodule VintageNetProxy.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:vintage_net_proxy, :start?, true) do
        interfaces = Application.get_env(:vintage_net_proxy, :interfaces, [])
        [{VintageNetProxy.Supervisor, interfaces: interfaces}]
      else
        []
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: VintageNetProxy.AppSupervisor
    )
  end
end
