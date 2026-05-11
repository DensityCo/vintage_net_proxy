defmodule VintageNetProxy.Selector do
  @moduledoc false
  use GenServer

  alias VintageNetProxy.{Interface, Published, Roster}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status, do: GenServer.call(__MODULE__, :status)
  def resolve(url), do: GenServer.call(__MODULE__, {:resolve, url})

  @impl true
  def init(opts) do
    interfaces = Keyword.get(opts, :interfaces, []) || []
    Interface.subscribe(interfaces)
    roster = Roster.load(interfaces)
    Published.put(Roster.value(roster))
    {:ok, roster}
  end

  @impl true
  def handle_call(:status, _from, roster),
    do: {:reply, Roster.status(roster, Published.get()), roster}

  def handle_call({:resolve, url}, _from, roster),
    do: {:reply, Roster.resolve(roster, url), roster}

  @impl true
  def handle_info({VintageNet, ["interface", iface, "config"], _o, new, _m}, roster),
    do: {:noreply, update(roster, iface, &Interface.on_config(&1, new))}

  def handle_info({VintageNet, ["interface", iface, "dhcp_options"], _o, new, _m}, roster),
    do: {:noreply, update(roster, iface, &Interface.on_dhcp_options(&1, new))}

  def handle_info({VintageNet, ["interface", iface, "connection"], _o, new, _m}, roster),
    do: {:noreply, update(roster, iface, &Interface.on_connection(&1, new))}

  def handle_info(_msg, roster), do: {:noreply, roster}

  defp update(roster, iface, fun) do
    roster = Roster.update_iface(roster, iface, fun)
    Published.put(Roster.value(roster))
    roster
  end
end
