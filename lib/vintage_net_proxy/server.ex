defmodule VintageNetProxy.Server do
  @moduledoc false
  use GenServer

  require Logger

  alias VintageNetProxy.{Config, Fetcher, PAC}

  @property ["proxy", "config"]
  @default_iface "wlan0"
  @fallback_target_url "http://localhost/"

  defstruct iface: @default_iface,
            config_property: nil,
            dhcp_property: nil,
            lower_up_property: nil,
            intent: nil,
            dhcp_wpad: nil,
            pac_script: nil,
            target_url: nil

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status, do: GenServer.call(__MODULE__, :status)
  def resolve(url), do: GenServer.call(__MODULE__, {:resolve, url})

  def set_target_url(url), do: GenServer.call(__MODULE__, {:set_target_url, url})
  def get_target_url, do: GenServer.call(__MODULE__, :get_target_url)

  @impl true
  def init(opts) do
    iface = Keyword.get(opts, :interface, @default_iface)

    state = %__MODULE__{
      iface: iface,
      config_property: ["interface", iface, "config"],
      dhcp_property: ["interface", iface, "dhcp_options"],
      lower_up_property: ["interface", iface, "lower_up"],
      target_url: Keyword.get(opts, :target_url)
    }

    VintageNet.subscribe(state.config_property)
    VintageNet.subscribe(state.dhcp_property)
    VintageNet.subscribe(state.lower_up_property)

    state =
      state
      |> load_intent_from_property()
      |> load_wpad_from_property()
      |> refresh_pac_if_needed()

    publish(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      iface: state.iface,
      target_url: state.target_url,
      intent: state.intent,
      pac_url: effective_pac_url(state),
      dhcp_wpad_url: state.dhcp_wpad,
      pac_loaded?: not is_nil(state.pac_script),
      current: value(state)
    }

    {:reply, status, state}
  end

  def handle_call({:resolve, url}, _from, state) do
    {:reply, resolve_for(state, url), state}
  end

  def handle_call({:set_target_url, url}, _from, state) do
    new_state = %{state | target_url: url}
    publish(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:get_target_url, _from, state) do
    {:reply, state.target_url, state}
  end

  @impl true
  def handle_info({VintageNet, prop, _old, _new, _meta}, %{config_property: prop} = state) do
    new_state =
      state
      |> load_intent_from_property()
      |> refresh_pac_if_needed()

    publish(new_state)
    {:noreply, new_state}
  end

  def handle_info({VintageNet, prop, _old, _new, _meta}, %{dhcp_property: prop} = state) do
    new_state =
      state
      |> load_wpad_from_property()
      |> refresh_pac_if_needed()

    publish(new_state)
    {:noreply, new_state}
  end

  def handle_info(
        {VintageNet, prop, _old, true, _meta},
        %{lower_up_property: prop} = state
      ) do
    {:noreply, refresh_pac_if_needed(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp load_intent_from_property(state) do
    case VintageNet.get(state.config_property) do
      %{proxy: raw} when is_map(raw) ->
        case Config.normalize(raw) do
          {:ok, intent} ->
            %{state | intent: intent}

          {:error, reason} ->
            Logger.warning("VintageNetProxy: invalid :proxy config on #{state.iface}: #{reason}")

            %{state | intent: nil}
        end

      _ ->
        %{state | intent: nil}
    end
  end

  defp load_wpad_from_property(state) do
    case VintageNet.get(state.dhcp_property) do
      %{wpad: url} when is_binary(url) and url != "" ->
        %{state | dhcp_wpad: url}

      _ ->
        %{state | dhcp_wpad: nil}
    end
  end

  defp refresh_pac_if_needed(state) do
    case effective_pac_url(state) do
      nil ->
        %{state | pac_script: nil}

      url ->
        fetch_pac(state, url)
    end
  end

  defp fetch_pac(state, url) do
    case Fetcher.get(url) do
      {:ok, script} ->
        %{state | pac_script: script}

      {:error, reason} ->
        Logger.warning("VintageNetProxy: PAC fetch failed (#{inspect(url)}): #{inspect(reason)}")

        state
    end
  end

  # Effective PAC URL — which URL to evaluate right now. Explicit `:pac_url`
  # in the intent wins; otherwise fall back to the DHCP-discovered WPAD URL.
  defp effective_pac_url(%{intent: %{mode: :auto, pac_url: url}}) when is_binary(url), do: url
  defp effective_pac_url(%{intent: %{mode: :auto}, dhcp_wpad: url}) when is_binary(url), do: url
  defp effective_pac_url(_), do: nil

  defp publish(state), do: PropertyTable.put(VintageNet, @property, value(state))

  defp value(%{intent: %{mode: :direct}}), do: :direct
  defp value(%{intent: %{mode: :manual} = m}), do: Config.to_descriptor(m)

  defp value(%{intent: %{mode: :auto}, pac_script: script, target_url: target})
       when is_binary(script) do
    PAC.find_proxy(script, target || @fallback_target_url)
  end

  defp value(_), do: :unset

  # Per-URL resolution evaluates PAC against the supplied URL.
  defp resolve_for(%{intent: %{mode: :direct}}, _url), do: :direct
  defp resolve_for(%{intent: %{mode: :manual} = m}, _url), do: Config.to_descriptor(m)

  defp resolve_for(%{intent: %{mode: :auto}, pac_script: script}, url) when is_binary(script) do
    PAC.find_proxy(script, url)
  end

  defp resolve_for(_, _url), do: :direct
end
