defmodule VintageNetProxy do
  @moduledoc """
  Resolve the system proxy from a per-interface `:proxy` config field
  (combined with DHCP-discovered WPAD URLs) and expose the result as a
  VintageNet property.

  ## Property

  The current proxy *model* is published at `["proxy", "config"]` in the
  `VintageNet` property table as one of:

    * `:unset` — no proxy intent, or PAC intent without a loaded script
    * `:direct` — connect directly, no proxy
    * `proxy_descriptor()` map — a fixed proxy to use; see `t:proxy_descriptor/0`
    * `:auto` — PAC-managed; call `resolve/1` per request

  PAC is inherently per-URL, so for `:auto` the library does *not*
  compress the script down to a single answer. Consumers call
  `resolve/1` with the URL they're about to fetch.

  Consumers subscribe and react:

      VintageNet.subscribe(VintageNetProxy.property())

      def handle_info({VintageNet, ["proxy", "config"], _old, proxy, _meta}, state) do
        case proxy do
          :unset -> {:noreply, state}
          :direct -> {:noreply, connect_direct(state)}
          :auto -> {:noreply, state}  # call resolve(url) per request
          %{scheme: :http} = px -> {:noreply, connect_http(state, px)}
          %{scheme: :socks5} = px -> {:noreply, connect_socks5(state, px)}
        end
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

  alias VintageNetProxy.{Publisher, Selector}

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

  @type proxy :: :unset | :direct | :auto | proxy_descriptor()
  @type resolved :: :direct | proxy_descriptor()

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

  @doc """
  Resolve the proxy for a specific URL.

  With a PAC script loaded, the script is evaluated for the given URL.
  Manual configurations apply regardless of the URL.
  """
  @spec resolve(String.t()) :: resolved()
  def resolve(url) when is_binary(url), do: Selector.resolve(url)
end
