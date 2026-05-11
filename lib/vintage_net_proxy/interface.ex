defmodule VintageNetProxy.Interface do
  @moduledoc false
  use GenServer

  require Logger

  alias VintageNetProxy.{Config, Fetcher, PAC}

  @up_states [:internet, :lan]

  defstruct iface: nil,
            intent: nil,
            dhcp_wpad: nil,
            pac_script: nil,
            connection: nil

  def child_spec(opts) do
    iface = Keyword.fetch!(opts, :iface)

    %{
      id: {__MODULE__, iface},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link(opts) do
    iface = Keyword.fetch!(opts, :iface)
    GenServer.start_link(__MODULE__, iface, name: via(iface))
  end

  @doc "Registry tuple addressing the Interface for `iface`."
  def via(iface), do: {:via, Registry, {VintageNetProxy.Registry, iface}}

  @doc "Current snapshot of this interface's resolution state. Sync."
  def snapshot(iface), do: GenServer.call(via(iface), :snapshot)

  @doc "Evaluate the loaded PAC against `url` (or apply manual/direct intent)."
  def resolve(iface, url), do: GenServer.call(via(iface), {:resolve, url})

  @impl true
  def init(iface) do
    Enum.each(["config", "dhcp_options", "connection"], fn prop ->
      VintageNet.subscribe(["interface", iface, prop])
    end)

    state =
      %__MODULE__{
        iface: iface,
        connection: VintageNet.get(["interface", iface, "connection"])
      }
      |> load_intent()
      |> load_wpad()
      |> refresh_pac_if_needed()

    # No notify on init: the Selector pulls fresh state via snapshot/1
    # after it starts each Interface as a child.
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state),
    do: {:reply, snapshot_of(state), state}

  def handle_call({:resolve, url}, _from, state) do
    reply =
      case state.intent do
        %{mode: :direct} -> :direct
        %{mode: :manual} = m -> Config.to_descriptor(m)
        %{mode: :auto} when is_binary(state.pac_script) -> PAC.find_proxy(state.pac_script, url)
        _ -> :direct
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(
        {VintageNet, ["interface", iface, "config"], _o, _n, _m},
        %{iface: iface} = state
      ),
      do: {:noreply, state |> load_intent() |> settle()}

  def handle_info(
        {VintageNet, ["interface", iface, "dhcp_options"], _o, _n, _m},
        %{iface: iface} = state
      ),
      do: {:noreply, state |> load_wpad() |> settle()}

  def handle_info(
        {VintageNet, ["interface", iface, "connection"], _o, conn, _m},
        %{iface: iface} = state
      ),
      do: {:noreply, %{state | connection: conn} |> settle()}

  def handle_info(_msg, state), do: {:noreply, state}

  defp settle(state) do
    new_state = refresh_pac_if_needed(state)
    GenServer.cast(VintageNetProxy.Selector, {:iface_changed, new_state.iface})
    new_state
  end

  defp load_intent(state) do
    intent =
      case VintageNet.get(["interface", state.iface, "config"]) do
        %{proxy: raw} when is_map(raw) ->
          case Config.normalize(raw) do
            {:ok, i} ->
              i

            {:error, reason} ->
              Logger.warning(
                "VintageNetProxy: invalid :proxy config on #{state.iface}: #{reason}"
              )

              nil
          end

        _ ->
          nil
      end

    %{state | intent: intent}
  end

  defp load_wpad(state) do
    wpad =
      case VintageNet.get(["interface", state.iface, "dhcp_options"]) do
        %{wpad: url} when is_binary(url) and url != "" -> url
        _ -> nil
      end

    %{state | dhcp_wpad: wpad}
  end

  defp refresh_pac_if_needed(state) do
    cond do
      state.connection not in @up_states ->
        %{state | pac_script: nil}

      true ->
        case effective_pac_url(state) do
          nil ->
            %{state | pac_script: nil}

          url ->
            case Fetcher.get(url) do
              {:ok, script} ->
                %{state | pac_script: script}

              {:error, reason} ->
                Logger.warning(
                  "VintageNetProxy: PAC fetch failed on #{state.iface} " <>
                    "(#{inspect(url)}): #{inspect(reason)}"
                )

                state
            end
        end
    end
  end

  # Explicit :pac_url in the intent wins; otherwise fall back to DHCP wpad.
  defp effective_pac_url(%{intent: %{mode: :auto, pac_url: url}}) when is_binary(url),
    do: url

  defp effective_pac_url(%{intent: %{mode: :auto}, dhcp_wpad: url}) when is_binary(url),
    do: url

  defp effective_pac_url(_), do: nil

  defp snapshot_of(state) do
    %{
      iface: state.iface,
      intent: state.intent,
      connection: state.connection,
      pac_loaded?: not is_nil(state.pac_script),
      dhcp_wpad_url: state.dhcp_wpad,
      pac_url: effective_pac_url(state)
    }
  end
end
