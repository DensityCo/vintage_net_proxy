defmodule VintageNetProxy.Roster do
  @moduledoc """
  Pure aggregator over per-interface snapshots.

  Holds the priority list of interfaces plus `%{iface => Interface.t}`.
  Knows how to find the active interface and compute the published
  `value/1`, the `resolve/2` result, and the `status/2` map. Used by
  the Selector — never spawns a process or touches the PropertyTable
  itself.
  """

  alias VintageNetProxy.Interface

  defstruct interfaces: [], states: %{}

  @type t :: %__MODULE__{
          interfaces: [String.t()],
          states: %{optional(String.t()) => Interface.t()}
        }

  @doc "Build a new roster from the priority list and the per-iface states."
  @spec new([String.t()], %{optional(String.t()) => Interface.t()}) :: t()
  def new(interfaces, iface_states),
    do: %__MODULE__{interfaces: interfaces, states: iface_states}

  @doc """
  Store the latest snapshot for `iface`. No-op if `iface` isn't in this
  roster's priority list (interfaces outside the configured set are ignored).
  """
  @spec put_iface(t(), String.t(), Interface.t()) :: t()
  def put_iface(state, iface, iface_state) do
    if iface in state.interfaces do
      %{state | states: Map.put(state.states, iface, iface_state)}
    else
      state
    end
  end

  @doc """
  Apply `fun` to the state of `iface`. No-op if `iface` isn't in this
  roster's priority list, or has no state yet.
  """
  @spec update_iface(t(), String.t(), (Interface.t() -> Interface.t())) :: t()
  def update_iface(state, iface, fun) do
    case Map.fetch(state.states, iface) do
      {:ok, iface_state} ->
        %{state | states: Map.put(state.states, iface, fun.(iface_state))}

      :error ->
        state
    end
  end

  @doc "The proxy value the active interface would publish; `:unset` if no interface is active."
  @spec value(t()) :: term()
  def value(state) do
    case active(state) do
      nil -> :unset
      iface_state -> Interface.value(iface_state)
    end
  end

  @doc "Resolve `url` against the active interface's PAC; `:direct` if no interface is active."
  @spec resolve(t(), String.t()) :: term()
  def resolve(state, url) do
    case active(state) do
      nil -> :direct
      iface_state -> Interface.resolve(iface_state, url)
    end
  end

  @doc "Introspection map. `published` is whatever is currently in `[\"proxy\", \"config\"]`."
  @spec status(t(), term()) :: map()
  def status(state, published) do
    by_interface =
      Map.new(state.interfaces, fn iface ->
        case Map.get(state.states, iface) do
          nil ->
            {iface,
             %{
               intent: nil,
               connection: nil,
               dhcp_wpad_url: nil,
               dhcp_domain: nil,
               pac_url: nil,
               pac_loaded?: false,
               pac_fetch_error: nil
             }}

          s ->
            snap = Interface.snapshot(s)

            {iface,
             %{
               intent: snap.intent,
               connection: snap.connection,
               dhcp_wpad_url: snap.dhcp_wpad_url,
               dhcp_domain: snap.dhcp_domain,
               pac_url: snap.pac_url,
               pac_loaded?: snap.pac_loaded?,
               pac_fetch_error: snap.pac_fetch_error
             }}
        end
      end)

    %{
      interfaces: state.interfaces,
      active_iface: active(state) |> active_iface(),
      by_interface: by_interface,
      current: published
    }
  end

  defp active(state) do
    Enum.find_value(state.interfaces, fn iface ->
      s = Map.get(state.states, iface)
      if s && Interface.eligible?(s), do: s
    end)
  end

  defp active_iface(nil), do: nil
  defp active_iface(iface_state), do: iface_state.iface
end
