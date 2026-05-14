defmodule VintageNetProxy do
  @moduledoc """
  Resolve the system proxy from a per-interface `:proxy` config field
  (combined with DHCP-discovered WPAD URLs) and expose the result as a
  VintageNet property.

  ## Property

  The current proxy *model* is published at `["proxy", "config"]` in
  the `VintageNet` property table. Stateful modes carry a `{mode,
  sub_state}` tuple so that loading / error states are first-class
  instead of being collapsed onto `:unset`:

    * `:unset` — no eligible interface, or eligible interface has no
      `:proxy` intent
    * `:direct` — direct mode; bypass any proxy
    * `{:manual, descriptor}` — explicit proxy from manual mode
    * `{:auto, :ready}` — PAC loaded; call `resolve/1` per request
    * `{:auto, :no_url}` — auto mode but no PAC URL is available
      (no `:pac_url`, no DHCP wpad, no DHCP domain). Stays here until
      the network advertises something to fetch.
    * `{:auto, {:error, reason}}` — PAC fetch failed; the cached
      failure stays until something invalidates it (URL changes,
      interface flaps, next external event re-fetches)

  PAC is inherently per-URL, so under `{:auto, :ready}` the library
  does *not* compress the script down to a single answer. Consumers
  call `resolve/1` with the URL they're about to fetch.

  Consumers subscribe and react:

      VintageNet.subscribe(VintageNetProxy.property())

      def handle_info({VintageNet, ["proxy", "config"], _old, proxy, _}, state) do
        case proxy do
          :unset                 -> {:noreply, state}
          :direct                -> {:noreply, connect_direct(state)}
          {:manual, desc}        -> {:noreply, connect_via(state, desc)}
          {:auto, :ready}        -> {:noreply, state}  # call resolve(url) per request
          {:auto, :no_url}       -> {:noreply, wait_for_network(state)}
          {:auto, {:error, _}}   -> {:noreply, alert_or_wait(state)}
        end
      end

  Consumers that don't care about the breakdown can match `:unset`
  and treat anything else as "we have something actionable, attempt
  the connection":

      case proxy do
        :unset -> wait()
        _      -> attempt(proxy)
      end

  ## Configuration

  Tell the library which interfaces to track, in priority order:

      config :vintage_net_proxy, interfaces: ["eth0", "wlan0"]

  Then add a `:proxy` field to each interface configuration. The schema
  is documented in `VintageNetProxy.Config`.

      VintageNet.configure("wlan0", %{
        type: VintageNetWiFi,
        ipv4: %{method: :dhcp},
        proxy: %{mode: :auto}            # use DHCP Option 252 (WPAD)
      })

      VintageNet.configure("wlan0", %{
        type: VintageNetWiFi,
        ipv4: %{method: :dhcp},
        proxy: %{
          mode: :manual,
          host: "proxy.corp",
          port: 8080
        }
      })

      VintageNet.configure("eth0", %{
        type: VintageNetEthernet,
        ipv4: %{method: :dhcp},
        proxy: %{mode: :direct}
      })

  At runtime, the library picks the first interface in the list that is
  both connected (`:internet` or `:lan`) and carries a `:proxy` intent.
  When that interface goes down, the next eligible one takes over; when
  it returns, it reclaims.

  Persistence and reboot-restore come for free — vintage_net already
  persists interface configurations.

  ## Per-URL resolution

      VintageNetProxy.resolve("https://api.example.com/")
      #=> %{scheme: :http, host: "corp-proxy", port: 8080}

      VintageNetProxy.resolve("http://intranet/")
      #=> :direct

  Use this in your HTTP client to pick a proxy per request. For
  `:manual` / `:direct` configs, the answer is the same regardless of
  URL; for `:auto` configs, the PAC script is evaluated against the
  supplied URL.
  """

  alias VintageNetProxy.{Connectivity, Publisher, Selector}

  @type scheme :: :http | :https | :socks4 | :socks5

  @typedoc """
  Map describing a proxy. `:scheme`, `:host`, `:port` are always present.
  `:username` and `:password` are present only for authenticated proxies.
  """
  @type proxy_descriptor :: %{
          required(:scheme) => scheme(),
          required(:host) => String.t(),
          required(:port) => pos_integer(),
          optional(:username) => String.t(),
          optional(:password) => String.t()
        }

  @typedoc """
  Published proxy model. See the module docs for the meaning of each
  shape.
  """
  @type proxy ::
          :unset
          | :direct
          | {:manual, proxy_descriptor()}
          | {:auto, :ready}
          | {:auto, :no_url}
          | {:auto, {:error, term()}}

  @type resolved :: :direct | proxy_descriptor()

  @typedoc """
  Connectivity check result. `:unknown` until the first probe completes
  (or always, if the connectivity checker isn't running).
  """
  @type connectivity :: :unknown | :ok | {:error, term()}

  @doc "Property table key under which the resolved proxy is published."
  @spec property() :: [String.t()]
  def property, do: Publisher.property()

  @doc "Subscribe to changes on the resolved proxy property."
  @spec subscribe() :: :ok
  def subscribe, do: VintageNet.subscribe(Publisher.property())

  @doc "Unsubscribe from the resolved proxy property."
  @spec unsubscribe() :: :ok
  def unsubscribe, do: VintageNet.unsubscribe(Publisher.property())

  @doc "Current proxy model."
  @spec get() :: proxy()
  def get, do: Publisher.get()

  @doc """
  Introspection snapshot — current internal state.

  `:active_iface` is the currently selected interface (or `nil`).
  `:by_interface` maps each configured interface to its `:intent`,
  `:connection`, `:dhcp_wpad_url`, `:pac_url`, `:pac_loaded?`. The
  published proxy is `:current`.
  """
  @spec status() :: %{
          interfaces: [String.t()],
          active_iface: String.t() | nil,
          by_interface: %{optional(String.t()) => map()},
          current: proxy()
        }
  def status, do: Selector.status()

  @typedoc """
  `resolve/1` result. `:ok` means the resolution was decisive; the
  caller should connect using the returned directive. `:error` means
  the library couldn't confidently route this URL through a proxy
  and the caller should decide what to do — refuse, wait, alert, or
  explicitly collapse the error to a direct connection.

  Error reasons:

    * `:pac_fallthrough` — PAC mode active, the script matched no
      rule *and* had no extractable default. Malformed script or
      syntax this evaluator silently skips. `VintageNetProxy.PAC`
      logs at `:warning` when this happens.
    * `:no_pac_url` — auto mode but no `:pac_url`, no DHCP wpad, no
      DHCP domain.
    * `{:pac_fetch_failed, reason}` — auto mode, the last fetch
      attempt failed.
    * `:no_proxy_resolved` — no eligible interface (no intent, or
      none up).

  PAC results — whether they came from a matched rule or the
  script's default — are returned faithfully as `{:ok, directive}`.
  "The script's default is `DIRECT`" is information about what the
  script says, not an error; deployments that consider default-
  DIRECT misconfigured should lint the PAC source.
  """
  @type resolve_result :: {:ok, resolved()} | {:error, term()}

  @doc """
  Resolve the proxy for a specific URL.

  With a PAC script loaded, the script is evaluated for the given URL.
  Manual configurations apply regardless of the URL. Returns
  `{:ok, directive}` on a decisive answer or `{:error, reason}` when
  the library can't confidently route this URL — see `t:resolve_result/0`.

  Consumers that don't care about the distinctions collapse:

      case VintageNetProxy.resolve(url) do
        {:ok, decision} -> connect(url, decision)
        {:error, _}     -> connect(url, :direct)
      end

  Consumers in mandatory-proxy deployments handle the error reasons
  individually (refuse, wait, alert).
  """
  @spec resolve(String.t()) :: resolve_result()
  def resolve(url) when is_binary(url), do: Selector.resolve(url)

  @doc """
  Property table key under which the connectivity check result is
  published. See `VintageNetProxy.Connectivity` for details.
  """
  @spec connectivity_property() :: [String.t()]
  def connectivity_property, do: Connectivity.property()

  @doc "Subscribe to connectivity state changes."
  @spec subscribe_connectivity() :: :ok
  def subscribe_connectivity, do: Connectivity.subscribe()

  @doc "Unsubscribe from connectivity state changes."
  @spec unsubscribe_connectivity() :: :ok
  def unsubscribe_connectivity, do: Connectivity.unsubscribe()

  @doc """
  Current connectivity state — `:unknown` if no probe has run yet (or
  the connectivity checker isn't enabled), `:ok` if the most recent
  probe succeeded, `{:error, reason}` if it failed.
  """
  @spec connectivity() :: connectivity()
  def connectivity, do: Connectivity.get()

  @doc """
  Run a connectivity probe right now and return its result. Returns
  `:unknown` if the connectivity checker isn't running.
  """
  @spec check_connectivity() :: connectivity()
  def check_connectivity, do: Connectivity.check_now()
end
