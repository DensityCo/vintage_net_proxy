defmodule VintageNetProxy.Interface do
  @moduledoc """
  Per-interface GenServer + state struct.

  One process per network interface. Subscribes to the interface's
  three PropertyTable keys (`config`, `dhcp_options`, `connection`),
  holds the per-interface state (intent, connection, DHCP wpad,
  cached `pac_script`), runs `Fetcher.get/1` synchronously inside its
  own mailbox, and pushes a snapshot to the Selector on every change.

  See the Architecture section of the README for the full picture.
  """
  use GenServer

  require Logger

  alias VintageNetProxy.{Config, Fetcher, PAC, Wpad}

  @up_states [:internet, :lan]

  defstruct iface: nil,
            intent: nil,
            dhcp_wpad_url: nil,
            dhcp_domain: nil,
            pac_script: nil,
            pac_fetch_error: nil,
            connection: nil

  @type t :: %__MODULE__{
          iface: String.t() | nil,
          intent: map() | nil,
          dhcp_wpad_url: String.t() | nil,
          dhcp_domain: String.t() | nil,
          pac_script: String.t() | nil,
          pac_fetch_error: term() | nil,
          connection: atom() | nil
        }

  # --- Client API ---

  def start_link(opts) do
    iface = Keyword.fetch!(opts, :iface)
    GenServer.start_link(__MODULE__, opts, name: via(iface))
  end

  def child_spec(opts) do
    iface = Keyword.fetch!(opts, :iface)

    %{
      id: {__MODULE__, iface},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc "Synchronously fetch the current state for `iface` (blocks on its mailbox)."
  def get(iface), do: GenServer.call(via(iface), :get_state)

  defp via(iface), do: {:via, Registry, {VintageNetProxy.InterfaceRegistry, iface}}

  # --- Pure helpers (operate on the struct) ---

  @doc """
  The URL the Interface will fetch right now, or `nil` if no fetch is
  applicable (intent isn't `:auto`, connection isn't up, or no URL is
  available from intent or DHCP).
  """
  @spec effective_pac_url(t()) :: String.t() | nil
  def effective_pac_url(%{connection: c}) when c not in @up_states, do: nil

  def effective_pac_url(%{intent: %{mode: :auto, pac_url: url}}) when is_binary(url),
    do: url

  def effective_pac_url(%{intent: %{mode: :auto}, dhcp_wpad_url: url}) when is_binary(url),
    do: url

  def effective_pac_url(%{intent: %{mode: :auto}, dhcp_domain: domain}) when is_binary(domain),
    do: Wpad.dns_url(domain)

  def effective_pac_url(_), do: nil

  @doc "True iff this interface has an intent and is connected enough to serve it."
  def eligible?(state),
    do: state.intent != nil and state.connection in @up_states

  @doc """
  The proxy value this interface would publish if it were active.

  Returns one of:

    * `:unset` — no intent, or `:auto` intent with no URL to fetch yet
    * `:direct` — direct mode
    * `{:manual, descriptor}` — explicit proxy from manual mode
    * `{:auto, :ready}` — auto mode, PAC script loaded
    * `{:auto, {:error, reason}}` — auto mode, last fetch attempt failed
  """
  def value(state) do
    case state.intent do
      %{mode: :direct} ->
        :direct

      %{mode: :manual} = m ->
        {:manual, Config.to_descriptor(m)}

      %{mode: :auto} ->
        cond do
          not is_nil(state.pac_script) -> {:auto, :ready}
          not is_nil(state.pac_fetch_error) -> {:auto, {:error, state.pac_fetch_error}}
          true -> :unset
        end

      _ ->
        :unset
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
      pac_fetch_error: state.pac_fetch_error,
      dhcp_wpad_url: state.dhcp_wpad_url,
      dhcp_domain: state.dhcp_domain,
      pac_url: configured_pac_url(state)
    }
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    iface = Keyword.fetch!(opts, :iface)
    parent = Keyword.fetch!(opts, :parent)

    Enum.each(["config", "dhcp_options", "connection"], fn prop ->
      VintageNet.subscribe(["interface", iface, prop])
    end)

    # Read current PropertyTable values synchronously (fast) but defer the
    # blocking PAC fetch to handle_continue so Supervisor.start_link returns
    # promptly. Fetches across multiple interfaces run in parallel because
    # each Interface owns its own process.
    state =
      %__MODULE__{iface: iface}
      |> put_connection(VintageNet.get(["interface", iface, "connection"]))
      |> put_intent(VintageNet.get(["interface", iface, "config"]))
      |> put_dhcp_options(VintageNet.get(["interface", iface, "dhcp_options"]))

    {:ok, {state, parent}, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, {state, parent}) do
    state = maybe_fetch(state)
    push(parent, state)
    {:noreply, {state, parent}}
  end

  @impl true
  def handle_call(:get_state, _from, {state, _parent} = ps), do: {:reply, state, ps}

  @impl true
  def handle_info({VintageNet, ["interface", _, "config"], _o, new, _m}, ps),
    do: handle_event(ps, &put_intent(&1, new))

  def handle_info({VintageNet, ["interface", _, "dhcp_options"], _o, new, _m}, ps),
    do: handle_event(ps, &put_dhcp_options(&1, new))

  def handle_info({VintageNet, ["interface", _, "connection"], _o, new, _m}, ps),
    do: handle_event(ps, &put_connection(&1, new))

  def handle_info(_msg, ps), do: {:noreply, ps}

  # --- Internals ---

  defp handle_event({state, parent}, change_fn) do
    state =
      state
      |> transition(change_fn)
      |> maybe_fetch()

    push(parent, state)
    {:noreply, {state, parent}}
  end

  # Apply the field-level change, then drop pac_script and any cached
  # fetch error if the effective PAC URL changed. Same URL before-and-
  # after preserves the cached script (free dedup); any other transition
  # invalidates so the next fetch can populate from the new URL.
  defp transition(state, change_fn) do
    old_url = effective_pac_url(state)
    new_state = change_fn.(state)

    if effective_pac_url(new_state) == old_url do
      new_state
    else
      %{new_state | pac_script: nil, pac_fetch_error: nil}
    end
  end

  # Synchronous fetch inside the Interface's own mailbox. Blocking is fine
  # here — the Selector and other interfaces are unaffected. On success
  # caches the script and clears any prior error; on failure caches the
  # error so the published value can carry it.
  defp maybe_fetch(state) do
    case fetch_target(state) do
      nil ->
        state

      url ->
        case Fetcher.get(url) do
          {:ok, script} ->
            %{state | pac_script: script, pac_fetch_error: nil}

          {:error, reason} ->
            Logger.warning(
              "VintageNetProxy: PAC fetch failed on #{state.iface} (#{inspect(url)}): #{inspect(reason)}"
            )

            %{state | pac_fetch_error: reason}
        end
    end
  end

  defp fetch_target(state) do
    if is_nil(state.pac_script), do: effective_pac_url(state), else: nil
  end

  defp push(parent, state), do: send(parent, {:interface_changed, state.iface, state})

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

  # Pulls both DHCP option 252 (`:wpad`) and option 15 (`:domain`) out of
  # `dhcp_options`. Either is sufficient for `:auto` mode to find a PAC
  # URL; option 252 wins via the priority order in `effective_pac_url/1`.
  defp put_dhcp_options(state, opts) when is_map(opts) do
    %{
      state
      | dhcp_wpad_url: extract_wpad(opts),
        dhcp_domain: extract_domain(opts)
    }
  end

  defp put_dhcp_options(state, _),
    do: %{state | dhcp_wpad_url: nil, dhcp_domain: nil}

  defp extract_wpad(%{wpad: url}) when is_binary(url) and url != "", do: url
  defp extract_wpad(_), do: nil

  defp extract_domain(%{domain: d}) when is_binary(d) and d != "", do: d
  defp extract_domain(_), do: nil

  defp configured_pac_url(%{intent: %{mode: :auto, pac_url: url}}) when is_binary(url),
    do: url

  defp configured_pac_url(%{intent: %{mode: :auto}, dhcp_wpad_url: url}) when is_binary(url),
    do: url

  defp configured_pac_url(%{intent: %{mode: :auto}, dhcp_domain: domain}) when is_binary(domain),
    do: Wpad.dns_url(domain)

  defp configured_pac_url(_), do: nil
end
