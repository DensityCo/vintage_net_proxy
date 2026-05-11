defmodule VintageNetProxy.Selector do
  @moduledoc false
  use GenServer

  alias VintageNetProxy.Interface

  @property ["proxy", "config"]

  defstruct interfaces: [], states: %{}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status, do: GenServer.call(__MODULE__, :status)
  def resolve(url), do: GenServer.call(__MODULE__, {:resolve, url})

  @impl true
  def init(opts) do
    interfaces = Keyword.get(opts, :interfaces, []) || []

    Enum.each(interfaces, fn iface ->
      Enum.each(["config", "dhcp_options", "connection"], fn prop ->
        VintageNet.subscribe(["interface", iface, prop])
      end)
    end)

    states = Map.new(interfaces, fn iface -> {iface, Interface.load(iface)} end)
    state = %__MODULE__{interfaces: interfaces, states: states}
    publish(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    by_interface =
      Map.new(state.states, fn {iface, s} ->
        snap = Interface.snapshot(s)

        {iface,
         %{
           intent: snap.intent,
           connection: snap.connection,
           dhcp_wpad_url: snap.dhcp_wpad_url,
           pac_url: snap.pac_url,
           pac_loaded?: snap.pac_loaded?
         }}
      end)

    active = find_active(state)

    reply = %{
      interfaces: state.interfaces,
      active_iface: active && active.iface,
      by_interface: by_interface,
      current: VintageNet.get(@property, :unset)
    }

    {:reply, reply, state}
  end

  def handle_call({:resolve, url}, _from, state) do
    reply =
      case find_active(state) do
        nil -> :direct
        iface_state -> Interface.resolve(iface_state, url)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({VintageNet, ["interface", iface, "config"], _o, new, _m}, state),
    do: {:noreply, update(state, iface, &Interface.on_config(&1, new))}

  def handle_info({VintageNet, ["interface", iface, "dhcp_options"], _o, new, _m}, state),
    do: {:noreply, update(state, iface, &Interface.on_dhcp_options(&1, new))}

  def handle_info({VintageNet, ["interface", iface, "connection"], _o, new, _m}, state),
    do: {:noreply, update(state, iface, &Interface.on_connection(&1, new))}

  def handle_info(_msg, state), do: {:noreply, state}

  defp update(state, iface, fun) do
    case Map.fetch(state.states, iface) do
      {:ok, iface_state} ->
        new_state = %{state | states: Map.put(state.states, iface, fun.(iface_state))}
        publish(new_state)
        new_state

      :error ->
        state
    end
  end

  defp publish(state) do
    value =
      case find_active(state) do
        nil -> :unset
        iface_state -> Interface.value(iface_state)
      end

    PropertyTable.put(VintageNet, @property, value)
  end

  defp find_active(state) do
    Enum.find_value(state.interfaces, fn iface ->
      s = Map.get(state.states, iface)
      if s && Interface.eligible?(s), do: s
    end)
  end
end
