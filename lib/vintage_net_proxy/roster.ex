defmodule VintageNetProxy.Roster do
  @moduledoc """
  Pure aggregator over per-interface routing.

  Holds the priority list of interfaces plus `%{iface => Routing.t}`.
  Knows how to find the active interface and compute the published
  `value/1`, the `resolve/2` result, and the `status/2` map. Used by
  the Selector — never spawns a process or touches the PropertyTable
  itself.
  """

  alias VintageNetProxy.Interface.Routing

  defstruct interfaces: [], states: %{}

  @type t :: %__MODULE__{
          interfaces: [String.t()],
          states: %{optional(String.t()) => Routing.t()}
        }

  @doc "Build a new roster from the priority list and the per-iface routing."
  @spec new([String.t()], %{optional(String.t()) => Routing.t()}) :: t()
  def new(interfaces, iface_states),
    do: %__MODULE__{interfaces: interfaces, states: iface_states}

  @doc """
  Store the latest routing for `iface`. No-op if `iface` isn't in this
  roster's priority list (interfaces outside the configured set are ignored).
  """
  @spec put_iface(t(), String.t(), Routing.t()) :: t()
  def put_iface(state, iface, routing) do
    if iface in state.interfaces do
      %{state | states: Map.put(state.states, iface, routing)}
    else
      state
    end
  end

  @doc """
  Return the cached routing for `iface`, or `nil` if none has been
  stored yet.
  """
  @spec get_iface(t(), String.t()) :: Routing.t() | nil
  def get_iface(state, iface), do: Map.get(state.states, iface)

  @doc """
  Apply `fun` to the routing of `iface`. No-op if `iface` isn't in this
  roster's priority list, or has no routing yet.
  """
  @spec update_iface(t(), String.t(), (Routing.t() -> Routing.t())) :: t()
  def update_iface(state, iface, fun) do
    case Map.fetch(state.states, iface) do
      {:ok, routing} ->
        %{state | states: Map.put(state.states, iface, fun.(routing))}

      :error ->
        state
    end
  end

  @doc "The proxy value the active interface would publish; `:unset` if no interface is active."
  @spec value(t()) :: term()
  def value(state) do
    case active(state) do
      nil -> :unset
      routing -> Routing.value(routing)
    end
  end

  @doc """
  Resolve `url` against the active interface. Returns the active
  interface's `Routing.resolve/2` result, or
  `{:error, :no_proxy_resolved}` if no interface is currently active.
  """
  @spec resolve(t(), String.t()) :: Routing.resolve_result()
  def resolve(state, url) do
    case active(state) do
      nil -> {:error, :no_proxy_resolved}
      routing -> Routing.resolve(routing, url)
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
               pac_fetch_error: nil,
               local_ip: nil
             }}

          s ->
            snap = Routing.snapshot(s)

            {iface,
             %{
               intent: snap.intent,
               connection: snap.connection,
               dhcp_wpad_url: snap.dhcp_wpad_url,
               dhcp_domain: snap.dhcp_domain,
               pac_url: snap.pac_url,
               pac_loaded?: snap.pac_loaded?,
               pac_fetch_error: snap.pac_fetch_error,
               local_ip: snap.local_ip
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
      if s && Routing.eligible?(s), do: s
    end)
  end

  defp active_iface(nil), do: nil
  defp active_iface(iface_state), do: iface_state.iface
end
