defmodule VintageNetProxy.Selector do
  @moduledoc false
  use GenServer

  alias VintageNetProxy.{Config, Interface, PAC}

  @property ["proxy", "config"]
  @fallback_target_url "http://localhost/"
  @up_states [:internet, :lan]

  defstruct interfaces: [], snapshots: %{}, target_url: nil

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status, do: GenServer.call(__MODULE__, :status)
  def resolve(url), do: GenServer.call(__MODULE__, {:resolve, url})
  def set_target_url(url), do: GenServer.call(__MODULE__, {:set_target_url, url})
  def get_target_url, do: GenServer.call(__MODULE__, :get_target_url)

  @impl true
  def init(opts) do
    interfaces = Keyword.get(opts, :interfaces, []) || []

    # Subscribe before starting children so we don't miss their initial publishes.
    Enum.each(interfaces, fn iface ->
      VintageNet.subscribe(["proxy", "interface", iface, "snapshot"])
    end)

    Enum.each(interfaces, fn iface ->
      case DynamicSupervisor.start_child(
             VintageNetProxy.InterfaceSupervisor,
             {Interface, iface: iface}
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end)

    snapshots =
      Map.new(interfaces, fn iface ->
        snap =
          VintageNet.get(["proxy", "interface", iface, "snapshot"]) ||
            empty_snapshot(iface)

        {iface, snap}
      end)

    state = %__MODULE__{
      interfaces: interfaces,
      snapshots: snapshots,
      target_url: Keyword.get(opts, :target_url)
    }

    publish(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    # Pull fresh snapshots so a status call doubles as a full sync barrier
    # across Selector ← Interface(s).
    snapshots =
      Map.new(state.interfaces, fn iface ->
        {iface, Interface.snapshot(iface)}
      end)

    new_state = %{state | snapshots: snapshots}
    publish(new_state)
    {:reply, build_status(new_state), new_state}
  end

  def handle_call({:resolve, url}, _from, state),
    do: {:reply, do_resolve(state, url), state}

  def handle_call({:set_target_url, url}, _from, state) do
    new_state = %{state | target_url: url}
    publish(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:get_target_url, _from, state),
    do: {:reply, state.target_url, state}

  @impl true
  def handle_info(
        {VintageNet, ["proxy", "interface", iface, "snapshot"], _old, snap, _meta},
        state
      ) do
    if iface in state.interfaces do
      snap = snap || empty_snapshot(iface)
      new_state = %{state | snapshots: Map.put(state.snapshots, iface, snap)}
      publish(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp pick_active(state) do
    Enum.find(state.interfaces, fn iface ->
      snap = Map.get(state.snapshots, iface, empty_snapshot(iface))
      snap.intent != nil and snap.connection in @up_states
    end)
  end

  defp value(state) do
    case pick_active(state) do
      nil -> :unset
      iface -> snapshot_value(Map.fetch!(state.snapshots, iface), state.target_url)
    end
  end

  defp snapshot_value(%{intent: %{mode: :direct}}, _), do: :direct
  defp snapshot_value(%{intent: %{mode: :manual} = m}, _), do: Config.to_descriptor(m)

  defp snapshot_value(%{intent: %{mode: :auto}, pac_script: script}, target)
       when is_binary(script),
       do: PAC.find_proxy(script, target || @fallback_target_url)

  defp snapshot_value(_, _), do: :unset

  defp do_resolve(state, url) do
    case pick_active(state) do
      nil -> :direct
      iface -> Interface.resolve(iface, url)
    end
  end

  defp publish(state),
    do: PropertyTable.put(VintageNet, @property, value(state))

  defp empty_snapshot(iface) do
    %{
      iface: iface,
      intent: nil,
      connection: nil,
      pac_script: nil,
      dhcp_wpad_url: nil,
      pac_url: nil
    }
  end

  defp build_status(state) do
    active = pick_active(state)

    by_interface =
      Map.new(state.snapshots, fn {iface, snap} ->
        {iface,
         %{
           intent: snap.intent,
           connection: snap.connection,
           dhcp_wpad_url: snap.dhcp_wpad_url,
           pac_url: snap.pac_url,
           pac_loaded?: not is_nil(snap.pac_script)
         }}
      end)

    active_info =
      case active do
        nil ->
          %{intent: nil, connection: nil, dhcp_wpad_url: nil, pac_url: nil, pac_loaded?: false}

        iface ->
          Map.fetch!(by_interface, iface)
      end

    Map.merge(active_info, %{
      interfaces: state.interfaces,
      active_iface: active,
      target_url: state.target_url,
      by_interface: by_interface,
      current: value(state)
    })
  end
end
