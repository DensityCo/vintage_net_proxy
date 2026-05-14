defmodule VintageNetProxy.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Tracks URLs we've already surfaced a "PAC evaluated to DIRECT" log
    # for. First occurrence per URL logs at :info; subsequent at :debug.
    # See `VintageNetProxy.Interface.resolve/2`.
    :ets.new(:vintage_net_proxy_pac_seen, [:set, :public, :named_table])

    children =
      if Application.get_env(:vintage_net_proxy, :start?, true) do
        interfaces = Application.get_env(:vintage_net_proxy, :interfaces, [])

        [{VintageNetProxy.Supervisor, interfaces: interfaces}] ++
          connectivity_children()
      else
        []
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: VintageNetProxy.AppSupervisor
    )
  end

  # The Connectivity checker is mounted as a sibling of the main
  # supervisor so a crash in either tree doesn't cascade. Off by
  # default; flip on with `config :vintage_net_proxy, connectivity:
  # [...]` (or `true` for defaults).
  defp connectivity_children do
    case Application.get_env(:vintage_net_proxy, :connectivity) do
      nil -> []
      false -> []
      true -> [{VintageNetProxy.Connectivity, []}]
      opts when is_list(opts) -> [{VintageNetProxy.Connectivity, opts}]
    end
  end
end
