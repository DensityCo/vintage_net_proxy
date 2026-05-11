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

  @doc "Notify the Selector that an Interface's state has changed."
  def notify_changed, do: GenServer.cast(__MODULE__, :changed)

  @impl true
  def init(opts) do
    interfaces = Keyword.get(opts, :interfaces, []) || []

    Enum.each(interfaces, fn iface ->
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
    snapshots = fetch_snapshots(state)
    publish(snapshots, state.interfaces)

    active = find_active(snapshots, state.interfaces)

    by_interface =
      Map.new(snapshots, fn {iface, snap} ->
        {iface,
         %{
           intent: snap.intent,
           connection: snap.connection,
           dhcp_wpad_url: snap.dhcp_wpad_url,
           pac_url: snap.pac_url,
           pac_loaded?: snap.pac_loaded?
         }}
      end)

    active_info =
      case active do
        nil ->
          %{intent: nil, connection: nil, dhcp_wpad_url: nil, pac_url: nil, pac_loaded?: false}

        snap ->
          Map.fetch!(by_interface, snap.iface)
      end

    reply =
      Map.merge(active_info, %{
        interfaces: state.interfaces,
        active_iface: active && active.iface,
        by_interface: by_interface,
        current: VintageNet.get(@property, :unset)
      })

    {:reply, reply, state}
  end

  def handle_call({:resolve, url}, _from, state) do
    reply =
      case find_active(fetch_snapshots(state), state.interfaces) do
        nil -> :direct
        snap -> Interface.resolve(snap.iface, url)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:changed, state) do
    recompute(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp recompute(state),
    do: publish(fetch_snapshots(state), state.interfaces)

  defp publish(snapshots, interfaces) do
    value =
      case find_active(snapshots, interfaces) do
        nil ->
          :unset

        snap ->
          case snap.intent do
            %{mode: :direct} -> :direct
            %{mode: :manual} = m -> Config.to_descriptor(m)
            %{mode: :auto} -> if snap.pac_loaded?, do: :auto, else: :unset
            _ -> :unset
          end
      end

    PropertyTable.put(VintageNet, @property, value)
  end

  defp find_active(snapshots, interfaces) do
    Enum.find_value(interfaces, fn iface ->
      snap = Map.fetch!(snapshots, iface)
      if snap.intent != nil and snap.connection in @up_states, do: snap
    end)
  end

  defp fetch_snapshots(state) do
    Map.new(state.interfaces, fn iface -> {iface, Interface.snapshot(iface)} end)
  end
end
