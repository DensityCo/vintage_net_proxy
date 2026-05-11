defmodule VintageNetProxy.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    server_opts = Application.get_env(:vintage_net_proxy, :server_opts, [])
    children = [{VintageNetProxy.Server, server_opts}]
    Supervisor.start_link(children, strategy: :one_for_one, name: VintageNetProxy.Supervisor)
  end
end
