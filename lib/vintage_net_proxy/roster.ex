defmodule VintageNetProxy.Roster do
  @moduledoc false

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
  Build a roster for `interfaces` by reading each one's initial state from the
  VintageNet PropertyTable (impure counterpart to `new/2`).
  """
  @spec load([String.t()]) :: t()
  def load(interfaces),
    do: new(interfaces, Map.new(interfaces, fn iface -> {iface, Interface.load(iface)} end))

  @doc """
  Apply `fun` to the state of `iface`. No-op if `iface` isn't in this Selector's list.
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
      Map.new(state.states, fn {iface, s} ->
        snap = Interface.snapshot(s)

        {iface,
         %{
           intent: snap.intent,
           connection: snap.connection,
           dhcp_wpad_url: snap.dhcp_wpad_url,
           pac_url: snap.pac_url,
           pac_loaded?: snap.pac_loaded?
         }}
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
