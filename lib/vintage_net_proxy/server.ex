defmodule VintageNetProxy.Server do
  @moduledoc false
  use GenServer

  require Logger

  alias VintageNetProxy.{Fetcher, PAC, Persistence}

  @property ["proxy", "config"]
  @default_iface "wlan0"
  @fallback_target_url "http://localhost/"

  defstruct iface: @default_iface,
            wpad_property: nil,
            target_url: nil,
            override: nil,
            wpad_url: nil,
            pac_script: nil

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def set_override(value), do: GenServer.call(__MODULE__, {:set_override, value})
  def clear_override, do: GenServer.call(__MODULE__, :clear_override)
  def resolve(url), do: GenServer.call(__MODULE__, {:resolve, url})

  def set_target_url(url), do: GenServer.call(__MODULE__, {:set_target_url, url})
  def get_target_url, do: GenServer.call(__MODULE__, :get_target_url)

  def set_wpad_url(url), do: GenServer.call(__MODULE__, {:set_wpad_url, url})
  def clear_wpad_url, do: GenServer.call(__MODULE__, :clear_wpad_url)

  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(opts) do
    iface = Keyword.get(opts, :interface, @default_iface)
    wpad_property = ["interface", iface, "wpad_url"]

    persisted =
      case Persistence.load() do
        {:ok, p} ->
          p

        {:error, reason} ->
          Logger.warning("VintageNetProxy: persistence load failed: #{inspect(reason)}")
          %{}
      end

    state = %__MODULE__{
      iface: iface,
      wpad_property: wpad_property,
      target_url: Keyword.get(opts, :target_url) || Map.get(persisted, :target_url),
      override: Map.get(persisted, :override),
      wpad_url: Map.get(persisted, :wpad_url)
    }

    VintageNet.subscribe(wpad_property)
    VintageNet.subscribe(["interface", iface, "lower_up"])

    if state.wpad_url do
      PropertyTable.put(VintageNet, wpad_property, state.wpad_url)
    end

    publish(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:set_override, value}, _from, state) do
    new_state = %{state | override: value}
    persist_and_publish(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:clear_override, _from, state) do
    new_state = %{state | override: nil}
    persist_and_publish(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:resolve, url}, _from, state) do
    {:reply, resolve_for(state, url), state}
  end

  def handle_call({:set_target_url, url}, _from, state) do
    new_state = %{state | target_url: url}
    persist_and_publish(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:get_target_url, _from, state) do
    {:reply, state.target_url, state}
  end

  def handle_call({:set_wpad_url, url}, _from, state) do
    PropertyTable.put(VintageNet, state.wpad_property, url)
    {:reply, :ok, state}
  end

  def handle_call(:clear_wpad_url, _from, state) do
    PropertyTable.delete(VintageNet, state.wpad_property)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      iface: state.iface,
      target_url: state.target_url,
      wpad_url: state.wpad_url,
      override: state.override,
      pac_loaded?: not is_nil(state.pac_script),
      current: value(state)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({VintageNet, prop, _old, url, _meta}, %{wpad_property: prop} = state)
      when is_binary(url) do
    state = %{state | wpad_url: url}
    persist(state)
    {:noreply, refresh_pac(state, url)}
  end

  def handle_info({VintageNet, prop, _old, _gone, _meta}, %{wpad_property: prop} = state) do
    new_state = %{state | wpad_url: nil, pac_script: nil}
    persist_and_publish(new_state)
    {:noreply, new_state}
  end

  def handle_info(
        {VintageNet, ["interface", _, "lower_up"], _old, true, _meta},
        %{wpad_url: url} = state
      )
      when is_binary(url) do
    {:noreply, refresh_pac(state, url)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp refresh_pac(state, url) do
    case Fetcher.get(url) do
      {:ok, script} ->
        new_state = %{state | pac_script: script}
        publish(new_state)
        new_state

      {:error, reason} ->
        Logger.warning("VintageNetProxy: PAC fetch failed (#{inspect(url)}): #{inspect(reason)}")
        state
    end
  end

  defp persist_and_publish(state) do
    persist(state)
    publish(state)
  end

  defp persist(state) do
    snapshot =
      state
      |> Map.take([:target_url, :wpad_url, :override])
      |> Map.reject(fn {_, v} -> is_nil(v) end)

    case Persistence.save(snapshot) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("VintageNetProxy: persistence save failed: #{inspect(reason)}")
    end
  end

  defp publish(state), do: PropertyTable.put(VintageNet, @property, value(state))

  defp value(%{override: o}) when not is_nil(o), do: o
  defp value(%{pac_script: nil}), do: :unset
  defp value(%{pac_script: script, target_url: target}) do
    PAC.find_proxy(script, target || @fallback_target_url)
  end

  defp resolve_for(%{override: o}, _url) when not is_nil(o), do: o
  defp resolve_for(%{pac_script: nil}, _url), do: :direct
  defp resolve_for(%{pac_script: script}, url), do: PAC.find_proxy(script, url)
end
