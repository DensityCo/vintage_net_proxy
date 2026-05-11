defmodule VintageNetProxy.Interface do
  @moduledoc false

  require Logger

  alias VintageNetProxy.{Config, Fetcher, PAC}

  @up_states [:internet, :lan]

  defstruct iface: nil,
            intent: nil,
            dhcp_wpad_url: nil,
            pac_script: nil,
            connection: nil

  @doc "Build initial state by reading current PropertyTable values."
  def load(iface) do
    %__MODULE__{iface: iface}
    |> put_connection(VintageNet.get(["interface", iface, "connection"]))
    |> put_intent(VintageNet.get(["interface", iface, "config"]))
    |> put_dhcp_options(VintageNet.get(["interface", iface, "dhcp_options"]))
    |> refresh_pac()
  end

  @doc "Handle a `[\"interface\", iface, \"config\"]` change."
  def on_config(state, raw), do: state |> put_intent(raw) |> refresh_pac()

  @doc "Handle a `[\"interface\", iface, \"dhcp_options\"]` change."
  def on_dhcp_options(state, opts), do: state |> put_dhcp_options(opts) |> refresh_pac()

  @doc "Handle a `[\"interface\", iface, \"connection\"]` change."
  def on_connection(state, conn), do: state |> put_connection(conn) |> refresh_pac()

  @doc "True iff this interface has an intent and is connected enough to serve it."
  def eligible?(state),
    do: state.intent != nil and state.connection in @up_states

  @doc "The proxy value this interface would publish if it were active."
  def value(state) do
    case state.intent do
      %{mode: :direct} -> :direct
      %{mode: :manual} = m -> Config.to_descriptor(m)
      %{mode: :auto} -> if not is_nil(state.pac_script), do: :auto, else: :unset
      _ -> :unset
    end
  end

  @doc "Evaluate the loaded PAC against `url` (or apply manual/direct intent)."
  def resolve(state, url) do
    case state.intent do
      %{mode: :direct} -> :direct
      %{mode: :manual} = m -> Config.to_descriptor(m)
      %{mode: :auto} when is_binary(state.pac_script) -> PAC.find_proxy(state.pac_script, url)
      _ -> :direct
    end
  end

  @doc "Introspection snapshot."
  def snapshot(state) do
    %{
      iface: state.iface,
      eligible?: eligible?(state),
      value: value(state),
      intent: state.intent,
      connection: state.connection,
      pac_loaded?: not is_nil(state.pac_script),
      dhcp_wpad_url: state.dhcp_wpad_url,
      pac_url: effective_pac_url(state)
    }
  end

  # --- pure setters ---

  defp put_connection(state, conn), do: %{state | connection: conn}

  defp put_intent(state, %{proxy: raw}) when is_map(raw) do
    case Config.normalize(raw) do
      {:ok, intent} ->
        %{state | intent: intent}

      {:error, reason} ->
        Logger.warning("VintageNetProxy: invalid :proxy config on #{state.iface}: #{reason}")
        %{state | intent: nil}
    end
  end

  defp put_intent(state, _), do: %{state | intent: nil}

  defp put_dhcp_options(state, %{wpad: url}) when is_binary(url) and url != "",
    do: %{state | dhcp_wpad_url: url}

  defp put_dhcp_options(state, _), do: %{state | dhcp_wpad_url: nil}

  # --- side-effecting: PAC fetch ---

  defp refresh_pac(%{connection: c} = state) when c not in @up_states,
    do: %{state | pac_script: nil}

  defp refresh_pac(state) do
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

  # Explicit :pac_url in the intent wins; otherwise fall back to DHCP wpad.
  defp effective_pac_url(%{intent: %{mode: :auto, pac_url: url}}) when is_binary(url),
    do: url

  defp effective_pac_url(%{intent: %{mode: :auto}, dhcp_wpad_url: url}) when is_binary(url),
    do: url

  defp effective_pac_url(_), do: nil
end
