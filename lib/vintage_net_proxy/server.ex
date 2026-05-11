defmodule VintageNetProxy.Server do
  @moduledoc false
  use GenServer

  require Logger

  alias VintageNetProxy.{Config, Fetcher, PAC}

  @property ["proxy", "config"]
  @fallback_target_url "http://localhost/"
  @up_states [:internet, :lan]

  defmodule InterfaceState do
    @moduledoc false
    defstruct intent: nil, dhcp_wpad: nil, pac_script: nil, connection: nil
  end

  defstruct interfaces: [], ifaces: %{}, target_url: nil

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status, do: GenServer.call(__MODULE__, :status)
  def resolve(url), do: GenServer.call(__MODULE__, {:resolve, url})

  def set_target_url(url), do: GenServer.call(__MODULE__, {:set_target_url, url})
  def get_target_url, do: GenServer.call(__MODULE__, :get_target_url)

  @impl true
  def init(opts) do
    interfaces = Keyword.get(opts, :interfaces, [])

    state = %__MODULE__{
      interfaces: interfaces,
      ifaces: Map.new(interfaces, fn name -> {name, %InterfaceState{}} end),
      target_url: Keyword.get(opts, :target_url)
    }

    state =
      Enum.reduce(interfaces, state, fn name, acc ->
        Enum.each(["config", "dhcp_options", "connection"], fn prop ->
          VintageNet.subscribe(["interface", name, prop])
        end)

        acc
        |> load_intent(name)
        |> load_wpad(name)
        |> load_connection(name)
        |> refresh_pac_if_needed(name)
      end)

    publish(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, build_status(state), state}

  def handle_call({:resolve, url}, _from, state) do
    {:reply, resolve_for(state, url), state}
  end

  def handle_call({:set_target_url, url}, _from, state) do
    new_state = %{state | target_url: url}
    publish(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:get_target_url, _from, state), do: {:reply, state.target_url, state}

  @impl true
  def handle_info({VintageNet, ["interface", name, "config"], _o, _n, _m}, state) do
    if Map.has_key?(state.ifaces, name) do
      new_state =
        state
        |> load_intent(name)
        |> refresh_pac_if_needed(name)

      publish(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({VintageNet, ["interface", name, "dhcp_options"], _o, _n, _m}, state) do
    if Map.has_key?(state.ifaces, name) do
      new_state =
        state
        |> load_wpad(name)
        |> refresh_pac_if_needed(name)

      publish(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({VintageNet, ["interface", name, "connection"], _o, conn, _m}, state) do
    if Map.has_key?(state.ifaces, name) do
      new_state =
        state
        |> put_iface(name, &%{&1 | connection: conn})
        |> on_connection_change(name, conn)

      publish(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp on_connection_change(state, name, conn) when conn in @up_states,
    do: refresh_pac_if_needed(state, name)

  defp on_connection_change(state, name, _conn),
    do: put_iface(state, name, &%{&1 | pac_script: nil})

  defp load_intent(state, name) do
    intent =
      case VintageNet.get(["interface", name, "config"]) do
        %{proxy: raw} when is_map(raw) ->
          case Config.normalize(raw) do
            {:ok, i} ->
              i

            {:error, reason} ->
              Logger.warning("VintageNetProxy: invalid :proxy config on #{name}: #{reason}")
              nil
          end

        _ ->
          nil
      end

    put_iface(state, name, &%{&1 | intent: intent})
  end

  defp load_wpad(state, name) do
    wpad =
      case VintageNet.get(["interface", name, "dhcp_options"]) do
        %{wpad: url} when is_binary(url) and url != "" -> url
        _ -> nil
      end

    put_iface(state, name, &%{&1 | dhcp_wpad: wpad})
  end

  defp load_connection(state, name) do
    conn = VintageNet.get(["interface", name, "connection"])
    put_iface(state, name, &%{&1 | connection: conn})
  end

  defp put_iface(state, name, fun) do
    case Map.fetch(state.ifaces, name) do
      {:ok, iface} -> %{state | ifaces: Map.put(state.ifaces, name, fun.(iface))}
      :error -> state
    end
  end

  defp refresh_pac_if_needed(state, name) do
    iface = Map.get(state.ifaces, name) || %InterfaceState{}

    cond do
      iface.connection not in @up_states ->
        put_iface(state, name, &%{&1 | pac_script: nil})

      true ->
        case effective_pac_url(iface) do
          nil -> put_iface(state, name, &%{&1 | pac_script: nil})
          url -> fetch_pac(state, name, url)
        end
    end
  end

  defp fetch_pac(state, name, url) do
    case Fetcher.get(url) do
      {:ok, script} ->
        put_iface(state, name, &%{&1 | pac_script: script})

      {:error, reason} ->
        Logger.warning(
          "VintageNetProxy: PAC fetch failed on #{name} (#{inspect(url)}): #{inspect(reason)}"
        )

        state
    end
  end

  # Explicit `:pac_url` in the intent wins; otherwise fall back to the
  # DHCP-discovered WPAD URL.
  defp effective_pac_url(%InterfaceState{intent: %{mode: :auto, pac_url: url}})
       when is_binary(url),
       do: url

  defp effective_pac_url(%InterfaceState{intent: %{mode: :auto}, dhcp_wpad: url})
       when is_binary(url),
       do: url

  defp effective_pac_url(_), do: nil

  defp publish(state), do: PropertyTable.put(VintageNet, @property, value(state))

  defp pick_active(state) do
    Enum.find(state.interfaces, fn name ->
      case Map.fetch(state.ifaces, name) do
        {:ok, %{intent: intent, connection: conn}}
        when not is_nil(intent) and conn in @up_states ->
          true

        _ ->
          false
      end
    end)
  end

  defp value(state) do
    case pick_active(state) do
      nil -> :unset
      name -> iface_value(Map.fetch!(state.ifaces, name), state.target_url)
    end
  end

  defp iface_value(%{intent: %{mode: :direct}}, _target), do: :direct
  defp iface_value(%{intent: %{mode: :manual} = m}, _target), do: Config.to_descriptor(m)

  defp iface_value(%{intent: %{mode: :auto}, pac_script: script}, target)
       when is_binary(script) do
    PAC.find_proxy(script, target || @fallback_target_url)
  end

  defp iface_value(_, _), do: :unset

  defp resolve_for(state, url) do
    case pick_active(state) do
      nil -> :direct
      name -> iface_resolve(Map.fetch!(state.ifaces, name), url)
    end
  end

  defp iface_resolve(%{intent: %{mode: :direct}}, _url), do: :direct
  defp iface_resolve(%{intent: %{mode: :manual} = m}, _url), do: Config.to_descriptor(m)

  defp iface_resolve(%{intent: %{mode: :auto}, pac_script: script}, url)
       when is_binary(script) do
    PAC.find_proxy(script, url)
  end

  defp iface_resolve(_, _url), do: :direct

  defp build_status(state) do
    active = pick_active(state)

    by_interface =
      Map.new(state.ifaces, fn {name, s} ->
        {name,
         %{
           intent: s.intent,
           connection: s.connection,
           dhcp_wpad_url: s.dhcp_wpad,
           pac_url: effective_pac_url(s),
           pac_loaded?: not is_nil(s.pac_script)
         }}
      end)

    active_info =
      case active do
        nil ->
          %{intent: nil, connection: nil, dhcp_wpad_url: nil, pac_url: nil, pac_loaded?: false}

        name ->
          Map.fetch!(by_interface, name)
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
