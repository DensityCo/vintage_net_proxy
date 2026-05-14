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
            connection: nil,
            local_ip: nil

  @type t :: %__MODULE__{
          iface: String.t() | nil,
          intent: map() | nil,
          dhcp_wpad_url: String.t() | nil,
          dhcp_domain: String.t() | nil,
          pac_script: String.t() | nil,
          pac_fetch_error: term() | nil,
          connection: atom() | nil,
          local_ip: String.t() | nil
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

    * `:unset` — no intent
    * `:direct` — direct mode
    * `{:manual, descriptor}` — explicit proxy from manual mode
    * `{:auto, :ready}` — auto mode, PAC script loaded
    * `{:auto, {:error, reason}}` — auto mode, last fetch attempt failed
    * `{:auto, :no_url}` — auto mode, but no PAC URL is available
      (no `:pac_url`, no DHCP wpad option, no DHCP domain to derive
      one from). Stays here until the network advertises something
      to fetch.
  """
  def value(%{intent: nil}), do: :unset
  def value(%{intent: %{mode: :direct}}), do: :direct
  def value(%{intent: %{mode: :manual} = m}), do: {:manual, Config.to_descriptor(m)}

  def value(%{intent: %{mode: :auto}, pac_script: script}) when is_binary(script),
    do: {:auto, :ready}

  def value(%{intent: %{mode: :auto}, pac_fetch_error: reason}) when not is_nil(reason),
    do: {:auto, {:error, reason}}

  def value(%{intent: %{mode: :auto}}), do: {:auto, :no_url}

  def value(_), do: :unset

  @typedoc """
  Resolve result. `:ok` means the resolution was decisive; the caller
  should connect using the returned directive. `:error` means the
  library couldn't confidently route this URL through a proxy and
  the caller should decide what to do — refuse, wait, alert, or
  explicitly collapse the error to a direct connection.
  """
  @type resolve_result :: {:ok, :direct | proxy_descriptor()} | {:error, term()}

  @typep proxy_descriptor :: %{
           required(:scheme) => :http | :https | :socks4 | :socks5,
           required(:host) => String.t(),
           required(:port) => pos_integer()
         }

  @doc """
  Resolve the proxy for `url` given this interface's snapshot.

  Returns `{:ok, directive}` when a decisive answer was reached and
  `{:error, reason}` when it wasn't. `directive` is `:direct` or a
  proxy descriptor.

  Error reasons:

    * `:pac_fallthrough` — PAC matched no rule *and* no extractable
      default. The script is malformed or uses syntax this evaluator
      silently skips. `VintageNetProxy.PAC` logs at `:warning` when
      this happens.
    * `:no_pac_url` — auto mode, no `:pac_url`, no DHCP wpad, no
      DHCP domain to derive one from.
    * `{:pac_fetch_failed, reason}` — auto mode, the last fetch
      attempt failed.
    * `:no_proxy_resolved` — no intent on this interface.

  PAC results — whether they came from a matched rule or from the
  script's default — are returned faithfully as `{:ok, directive}`.
  "The script's default is `DIRECT`" is information about what the
  script says, not an error; deployments that consider default-DIRECT
  misconfigured should lint the PAC source.
  """
  @spec resolve(t(), String.t()) :: resolve_result()
  def resolve(state, url)

  def resolve(%{intent: %{mode: :direct}}, _url), do: {:ok, :direct}

  def resolve(%{intent: %{mode: :manual} = m}, _url),
    do: {:ok, Config.to_descriptor(m)}

  def resolve(%{intent: %{mode: :auto}, pac_script: script, local_ip: local_ip}, url)
      when is_binary(script),
      do: PAC.find_proxy(script, url, local_ip: local_ip)

  def resolve(%{intent: %{mode: :auto}, pac_fetch_error: e}, _url)
      when not is_nil(e),
      do: {:error, {:pac_fetch_failed, e}}

  def resolve(%{intent: %{mode: :auto}}, _url), do: {:error, :no_pac_url}

  def resolve(_state, _url), do: {:error, :no_proxy_resolved}

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
      pac_url: configured_pac_url(state),
      local_ip: state.local_ip
    }
  end

  # --- GenServer ---

  # Keep `init` a no-op: just stash the iface and parent on the
  # struct and hand off to `handle_continue/2`. All the actual work —
  # PropertyTable subscriptions, reading current values, the PAC
  # fetch — happens after init returns, so `Supervisor.start_link`
  # comes back in microseconds regardless of VintageNet's
  # responsiveness or whether the network is up.
  @impl true
  def init(opts) do
    iface = Keyword.fetch!(opts, :iface)
    parent = Keyword.fetch!(opts, :parent)
    {:ok, {%__MODULE__{iface: iface}, parent}, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, {state, parent}) do
    iface = state.iface

    Enum.each(["config", "dhcp_options", "connection", "addresses"], fn prop ->
      VintageNet.subscribe(["interface", iface, prop])
    end)

    state =
      state
      |> put_connection(VintageNet.get(["interface", iface, "connection"]))
      |> put_intent(VintageNet.get(["interface", iface, "config"]))
      |> put_dhcp_options(VintageNet.get(["interface", iface, "dhcp_options"]))
      |> put_addresses(VintageNet.get(["interface", iface, "addresses"]))
      |> maybe_fetch()

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

  def handle_info({VintageNet, ["interface", _, "addresses"], _o, new, _m}, ps),
    do: handle_event(ps, &put_addresses(&1, new))

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

  # Pick the first IPv4 address out of VintageNet's `addresses`
  # property — used by PAC scripts that call `myIpAddress()` (typically
  # inside `isInNet(myIpAddress(), …)` for subnet-aware routing). If
  # no IPv4 address is present (interface down, IPv6-only lease, etc.)
  # `local_ip` becomes nil, which makes `myIpAddress()` evaluate to
  # "no IP" and the surrounding `isInNet` falls through.
  defp put_addresses(state, addresses) when is_list(addresses),
    do: %{state | local_ip: first_ipv4_string(addresses)}

  defp put_addresses(state, _), do: %{state | local_ip: nil}

  defp first_ipv4_string(addresses) do
    Enum.find_value(addresses, fn
      %{family: :inet, address: {a, b, c, d}} -> "#{a}.#{b}.#{c}.#{d}"
      _ -> nil
    end)
  end

  defp configured_pac_url(%{intent: %{mode: :auto, pac_url: url}}) when is_binary(url),
    do: url

  defp configured_pac_url(%{intent: %{mode: :auto}, dhcp_wpad_url: url}) when is_binary(url),
    do: url

  defp configured_pac_url(%{intent: %{mode: :auto}, dhcp_domain: domain}) when is_binary(domain),
    do: Wpad.dns_url(domain)

  defp configured_pac_url(_), do: nil
end
