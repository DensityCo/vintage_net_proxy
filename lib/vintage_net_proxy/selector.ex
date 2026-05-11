defmodule VintageNetProxy.Selector do
  @moduledoc false
  use GenServer

  alias VintageNetProxy.{Config, Interface}

  @property ["proxy", "config"]
  @up_states [:internet, :lan]

  defstruct interfaces: []

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status, do: GenServer.call(__MODULE__, :status)
  def resolve(url), do: GenServer.call(__MODULE__, {:resolve, url})

  @impl true
  def init(opts) do
    interfaces = Keyword.get(opts, :interfaces, []) || []

    Enum.each(interfaces, fn iface ->
      VintageNet.subscribe(["proxy", "interface", iface, "snapshot"])

      case DynamicSupervisor.start_child(
             VintageNetProxy.InterfaceSupervisor,
             {Interface, iface: iface}
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end)

    state = %__MODULE__{interfaces: interfaces}
    recompute(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    # Drain each Interface's mailbox so any pending property events
    # produce fresh snapshots in the PropertyTable before we read them.
    Enum.each(state.interfaces, &Interface.snapshot/1)
    recompute(state)

    active = pick_active(state)

    by_interface =
      Map.new(state.interfaces, fn iface ->
        snap = read_snapshot(iface)

        {iface,
         %{
           intent: snap[:intent],
           connection: snap[:connection],
           dhcp_wpad_url: snap[:dhcp_wpad_url],
           pac_url: snap[:pac_url],
           pac_loaded?: not is_nil(snap[:pac_script])
         }}
      end)

    active_info =
      case active do
        nil ->
          %{intent: nil, connection: nil, dhcp_wpad_url: nil, pac_url: nil, pac_loaded?: false}

        iface ->
          Map.fetch!(by_interface, iface)
      end

    reply =
      Map.merge(active_info, %{
        interfaces: state.interfaces,
        active_iface: active,
        by_interface: by_interface,
        current: compute_value(state)
      })

    {:reply, reply, state}
  end

  def handle_call({:resolve, url}, _from, state) do
    reply =
      case pick_active(state) do
        nil -> :direct
        iface -> Interface.resolve(iface, url)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({VintageNet, ["proxy", "interface", _, "snapshot"], _o, _n, _m}, state) do
    recompute(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp recompute(state),
    do: PropertyTable.put(VintageNet, @property, compute_value(state))

  defp compute_value(state) do
    case pick_active(state) do
      nil ->
        :unset

      iface ->
        snap = read_snapshot(iface)

        case snap[:intent] do
          %{mode: :direct} -> :direct
          %{mode: :manual} = m -> Config.to_descriptor(m)
          %{mode: :auto} when is_binary(snap[:pac_script]) -> :auto
          _ -> :unset
        end
    end
  end

  defp pick_active(state) do
    Enum.find(state.interfaces, fn iface ->
      snap = read_snapshot(iface)
      snap[:intent] != nil and snap[:connection] in @up_states
    end)
  end

  defp read_snapshot(iface),
    do: VintageNet.get(["proxy", "interface", iface, "snapshot"]) || %{}
end
