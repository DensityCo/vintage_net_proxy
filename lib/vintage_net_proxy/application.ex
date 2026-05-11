defmodule VintageNetProxy.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      case Application.get_env(:vintage_net_proxy, :server_opts, []) do
        false -> []
        opts -> [{VintageNetProxy.Server, opts}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: VintageNetProxy.Supervisor)
  end
end
