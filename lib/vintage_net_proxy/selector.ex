defmodule VintageNetProxy.Selector do
  @moduledoc false
  use GenServer

  alias VintageNetProxy.Interface
  alias VintageNetProxy.Selector.State

  @property ["proxy", "config"]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status, do: GenServer.call(__MODULE__, :status)
  def resolve(url), do: GenServer.call(__MODULE__, {:resolve, url})

  @impl true
  def init(opts) do
    interfaces = Keyword.get(opts, :interfaces, []) || []
    Enum.each(interfaces, &Interface.subscribe/1)
    states = Map.new(interfaces, fn iface -> {iface, Interface.load(iface)} end)
    state = State.new(interfaces, states)
    publish(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, State.status(state, VintageNet.get(@property, :unset)), state}

  def handle_call({:resolve, url}, _from, state),
    do: {:reply, State.resolve(state, url), state}

  @impl true
  def handle_info({VintageNet, ["interface", iface, "config"], _o, new, _m}, state),
    do: {:noreply, update(state, iface, &Interface.on_config(&1, new))}

  def handle_info({VintageNet, ["interface", iface, "dhcp_options"], _o, new, _m}, state),
    do: {:noreply, update(state, iface, &Interface.on_dhcp_options(&1, new))}

  def handle_info({VintageNet, ["interface", iface, "connection"], _o, new, _m}, state),
    do: {:noreply, update(state, iface, &Interface.on_connection(&1, new))}

  def handle_info(_msg, state), do: {:noreply, state}

  defp update(state, iface, fun) do
    new_state = State.update_iface(state, iface, fun)
    publish(new_state)
    new_state
  end

  defp publish(state),
    do: PropertyTable.put(VintageNet, @property, State.value(state))
end
