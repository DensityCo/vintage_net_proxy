defmodule VintageNetProxy.Interface.Routing do
  @moduledoc """
  Per-interface routing data and the pure queries over it.

  This is everything one interface knows about how to route a URL —
  the user's intent, the connectivity and DHCP options observed from
  VintageNet, the cached PAC script (or last fetch error), and the
  local IP that PAC scripts may inspect via `myIpAddress()`.

  All functions here are pure. The `VintageNetProxy.Interface`
  GenServer subscribes to PropertyTable, executes the `Fetcher.get/1`
  call, and logs. Decisions — what URL to fetch, whether the cache is
  still valid, what proxy `url` should use — live here.
  """

  alias VintageNetProxy.{Addresses, Intent, PAC, Wpad}

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
          intent: Intent.t() | nil,
          dhcp_wpad_url: String.t() | nil,
          dhcp_domain: String.t() | nil,
          pac_script: String.t() | nil,
          pac_fetch_error: term() | nil,
          connection: atom() | nil,
          local_ip: String.t() | nil
        }

  @typep proxy_descriptor :: %{
           required(:scheme) => :http | :https | :socks4 | :socks5,
           required(:host) => String.t(),
           required(:port) => pos_integer()
         }

  @typedoc """
  Resolve result. `:ok` means the resolution was decisive; the caller
  should connect using the returned directive. `:error` means the
  library couldn't confidently route this URL through a proxy and
  the caller should decide what to do — refuse, wait, alert, or
  explicitly collapse the error to a direct connection.
  """
  @type resolve_result :: {:ok, :direct | proxy_descriptor()} | {:error, term()}

  @doc "Empty routing for `iface`, before any property has been observed."
  @spec new(String.t()) :: t()
  def new(iface), do: %__MODULE__{iface: iface}

  # --- Pure field setters ---

  @doc "Set the normalized intent. Pass `nil` to clear."
  @spec put_intent(t(), Intent.t() | nil) :: t()
  def put_intent(routing, intent), do: %{routing | intent: intent}

  @doc "Set the connection status (`:internet | :lan | :disconnected | ...`)."
  @spec put_connection(t(), atom() | nil) :: t()
  def put_connection(routing, conn), do: %{routing | connection: conn}

  @doc "Extract option 252 (wpad URL) and option 15 (domain) from VintageNet's `dhcp_options` payload."
  @spec put_dhcp_options(t(), term()) :: t()
  def put_dhcp_options(routing, opts) do
    {wpad, domain} = Wpad.from_dhcp_options(opts)
    %{routing | dhcp_wpad_url: wpad, dhcp_domain: domain}
  end

  @doc "Extract the first IPv4 string from VintageNet's `addresses` payload."
  @spec put_addresses(t(), term()) :: t()
  def put_addresses(routing, addresses),
    do: %{routing | local_ip: Addresses.first_ipv4(addresses)}

  # --- Cache machinery ---

  @doc """
  Apply `change_fn` to the routing, then invalidate the PAC cache if
  the effective URL changed. Same-URL transitions preserve the cached
  script (free dedup); any other transition clears `pac_script` and
  `pac_fetch_error` so the next fetch can populate from the new URL.
  """
  @spec transition(t(), (t() -> t())) :: t()
  def transition(routing, change_fn) do
    old_url = effective_pac_url(routing)
    new_routing = change_fn.(routing)

    if effective_pac_url(new_routing) == old_url do
      new_routing
    else
      %{new_routing | pac_script: nil, pac_fetch_error: nil}
    end
  end

  @doc """
  The URL to fetch right now, or `nil` if either no fetch is
  applicable (see `effective_pac_url/1`) or the script is already
  cached.
  """
  @spec fetch_target(t()) :: String.t() | nil
  def fetch_target(routing) do
    if is_nil(routing.pac_script), do: effective_pac_url(routing), else: nil
  end

  @doc "Record a successful PAC fetch. Clears any prior fetch error."
  @spec cache_script(t(), String.t()) :: t()
  def cache_script(routing, script),
    do: %{routing | pac_script: script, pac_fetch_error: nil}

  @doc "Record a failed PAC fetch."
  @spec cache_error(t(), term()) :: t()
  def cache_error(routing, reason),
    do: %{routing | pac_fetch_error: reason}

  # --- Queries ---

  @doc """
  The URL the interface will fetch right now, or `nil` if no fetch is
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
  @spec eligible?(t()) :: boolean()
  def eligible?(routing),
    do: routing.intent != nil and routing.connection in @up_states

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
  @spec value(t()) :: term()
  def value(%{intent: nil}), do: :unset
  def value(%{intent: %{mode: :direct}}), do: :direct
  def value(%{intent: %{mode: :manual} = m}), do: {:manual, Intent.to_descriptor(m)}

  def value(%{intent: %{mode: :auto}, pac_script: script}) when is_binary(script),
    do: {:auto, :ready}

  def value(%{intent: %{mode: :auto}, pac_fetch_error: reason}) when not is_nil(reason),
    do: {:auto, {:error, reason}}

  def value(%{intent: %{mode: :auto}}), do: {:auto, :no_url}

  def value(_), do: :unset

  @doc """
  Resolve the proxy for `url` given this routing.

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
  def resolve(routing, url)

  def resolve(%{intent: %{mode: :direct}}, _url), do: {:ok, :direct}

  def resolve(%{intent: %{mode: :manual} = m}, _url),
    do: {:ok, Intent.to_descriptor(m)}

  def resolve(%{intent: %{mode: :auto}, pac_script: script, local_ip: local_ip}, url)
      when is_binary(script),
      do: PAC.find_proxy(script, url, local_ip: local_ip)

  def resolve(%{intent: %{mode: :auto}, pac_fetch_error: e}, _url)
      when not is_nil(e),
      do: {:error, {:pac_fetch_failed, e}}

  def resolve(%{intent: %{mode: :auto}}, _url), do: {:error, :no_pac_url}

  def resolve(_routing, _url), do: {:error, :no_proxy_resolved}

  @doc "Introspection snapshot."
  @spec snapshot(t()) :: map()
  def snapshot(routing) do
    %{
      iface: routing.iface,
      eligible?: eligible?(routing),
      value: value(routing),
      intent: routing.intent,
      connection: routing.connection,
      pac_loaded?: not is_nil(routing.pac_script),
      pac_fetch_error: routing.pac_fetch_error,
      dhcp_wpad_url: routing.dhcp_wpad_url,
      dhcp_domain: routing.dhcp_domain,
      pac_url: configured_pac_url(routing),
      local_ip: routing.local_ip
    }
  end

  defp configured_pac_url(%{intent: %{mode: :auto, pac_url: url}}) when is_binary(url),
    do: url

  defp configured_pac_url(%{intent: %{mode: :auto}, dhcp_wpad_url: url}) when is_binary(url),
    do: url

  defp configured_pac_url(%{intent: %{mode: :auto}, dhcp_domain: domain}) when is_binary(domain),
    do: Wpad.dns_url(domain)

  defp configured_pac_url(_), do: nil
end
