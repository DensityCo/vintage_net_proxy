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
            target_url: nil,
            # Transient override for the deprecated set_override/set_wpad_url APIs.
            # New code should drive everything through `VintageNet.configure/3`.
            legacy_override: nil,
            legacy_pac_url: nil

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status, do: GenServer.call(__MODULE__, :status)
  def resolve(url), do: GenServer.call(__MODULE__, {:resolve, url})

  def set_target_url(url), do: GenServer.call(__MODULE__, {:set_target_url, url})
  def get_target_url, do: GenServer.call(__MODULE__, :get_target_url)

  # Deprecated paths preserved for back-compat. These all log a warning and
  # store a transient override that survives until the next interface config
  # change or process restart.
  def set_override(value), do: GenServer.call(__MODULE__, {:legacy_set_override, value})
  def clear_override, do: GenServer.call(__MODULE__, :legacy_clear_override)
  def set_wpad_url(url), do: GenServer.call(__MODULE__, {:legacy_set_wpad_url, url})
  def clear_wpad_url, do: GenServer.call(__MODULE__, :legacy_clear_wpad_url)

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
      wpad_url: effective_pac_url(state),
      dhcp_wpad_url: state.dhcp_wpad,
      legacy_override: state.legacy_override,
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

  def handle_call({:legacy_set_override, value}, _from, state) do
    deprecation_warning("set_override/1 (set_manual/set_direct)")
    new_state = %{state | legacy_override: value}
    publish(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:legacy_clear_override, _from, state) do
    new_state = %{state | legacy_override: nil}
    publish(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:legacy_set_wpad_url, url}, _from, state) do
    deprecation_warning("set_wpad_url/1")
    new_state = %{state | legacy_pac_url: url} |> refresh_pac_if_needed()
    publish(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:legacy_clear_wpad_url, _from, state) do
    new_state = %{state | legacy_pac_url: nil, pac_script: nil} |> refresh_pac_if_needed()
    publish(new_state)
    {:reply, :ok, new_state}
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

  # Effective PAC URL = whichever PAC URL we should be evaluating right now.
  # Priority: legacy override (set_wpad_url) > explicit pac_url in intent >
  # DHCP-discovered WPAD URL when intent is :auto. Nil otherwise.
  defp effective_pac_url(%{legacy_pac_url: url}) when is_binary(url), do: url

  defp effective_pac_url(%{intent: %{mode: :auto, pac_url: url}}) when is_binary(url), do: url

  defp effective_pac_url(%{intent: %{mode: :auto}, dhcp_wpad: url}) when is_binary(url), do: url

  defp effective_pac_url(_), do: nil

  defp publish(state), do: PropertyTable.put(VintageNet, @property, value(state))

  # Resolved proxy value priority:
  #   1. Transient legacy override (set_manual/set_direct) — deprecated
  #   2. Interface config intent (:direct | :manual | :auto + PAC result)
  #   3. :unset (no intent and no override)
  defp value(%{legacy_override: o}) when not is_nil(o), do: o

  defp value(%{intent: %{mode: :direct}}), do: :direct

  defp value(%{intent: %{mode: :manual} = m}), do: Config.to_descriptor(m)

  defp value(%{intent: %{mode: :auto}, pac_script: script, target_url: target})
       when is_binary(script) do
    PAC.find_proxy(script, target || @fallback_target_url)
  end

  defp value(_), do: :unset

  # Per-URL resolution mirrors `value/1` but evaluates the PAC against the
  # supplied URL instead of the global target.
  defp resolve_for(%{legacy_override: o}, _url) when not is_nil(o), do: o

  defp resolve_for(%{intent: %{mode: :direct}}, _url), do: :direct

  defp resolve_for(%{intent: %{mode: :manual} = m}, _url), do: Config.to_descriptor(m)

  defp resolve_for(%{intent: %{mode: :auto}, pac_script: script}, url) when is_binary(script) do
    PAC.find_proxy(script, url)
  end

  defp resolve_for(_, _url), do: :direct

  defp deprecation_warning(api) do
    Logger.warning(
      "VintageNetProxy.#{api} is deprecated. Drive proxy configuration through " <>
        "VintageNet.configure/3 by adding a `:proxy` field to the interface config. " <>
        "See VintageNetProxy.Config for the schema."
    )
  end
end
