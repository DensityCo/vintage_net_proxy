defmodule VintageNetProxy.InterfaceSupervisor do
  @moduledoc false
  use Supervisor

  alias VintageNetProxy.{Interface, Selector}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interfaces = Keyword.get(opts, :interfaces, []) || []
    iface_opts = Keyword.take(opts, [:fetcher, :retry_backoff_ms])

    children =
      Enum.map(interfaces, fn iface ->
        Supervisor.child_spec(
          {Interface, [iface: iface, parent: Selector] ++ iface_opts},
          id: {Interface, iface}
        )
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
