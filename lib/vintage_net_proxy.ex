defmodule VintageNetProxy do
  @moduledoc """
  Resolve the system proxy from a per-interface `:proxy` config field
  (combined with DHCP-discovered WPAD URLs) and expose the result as a
  VintageNet property.

  ## Property

  The current proxy is published at `["proxy", "config"]` in the `VintageNet`
  property table as one of:

    * `:unset` — no proxy intent and no PAC has resolved yet
    * `:direct` — connect directly, no proxy
    * `proxy_descriptor()` map — a proxy to use; see `t:proxy_descriptor/0`

  Consumers subscribe and react:

      VintageNet.subscribe(VintageNetProxy.property())

      def handle_info({VintageNet, ["proxy", "config"], _old, proxy, _meta}, state) do
        case proxy do
          :unset -> {:noreply, state}
          :direct -> {:noreply, connect_direct(state)}
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

  ## Target URL (PAC evaluation context)

  When a PAC script is loaded, it's evaluated against this URL and the
  result is published. Typically the upstream the device cares about.

      VintageNetProxy.set_target_url("https://api.example.com/")
      VintageNetProxy.get_target_url()

  ## Per-URL resolution (advanced)

      VintageNetProxy.resolve("https://api.example.com/")
      #=> %{scheme: :http, host: "corp-proxy", port: 8080}

      VintageNetProxy.resolve("http://intranet/")
      #=> :direct
  """

  alias VintageNetProxy.{Config, Selector}

  @property ["proxy", "config"]

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

  @type proxy :: :unset | :direct | proxy_descriptor()
  @type resolved :: :direct | proxy_descriptor()

  @doc "Property table key under which the resolved proxy is published."
  @spec property() :: [String.t()]
  def property, do: @property

  @doc "Subscribe to changes on the resolved proxy property."
  @spec subscribe() :: :ok
  def subscribe, do: VintageNet.subscribe(@property)

  @doc "Unsubscribe from the resolved proxy property."
  @spec unsubscribe() :: :ok
  def unsubscribe, do: VintageNet.unsubscribe(@property)

  @doc "Current proxy configuration."
  @spec get() :: proxy()
  def get, do: VintageNet.get(@property, :unset)

  @doc """
  Introspection snapshot — current internal state.

  The flat `:intent`, `:pac_url`, `:dhcp_wpad_url`, `:pac_loaded?` fields
  mirror the *currently active* interface (or are `nil`/`false` when no
  interface is active). `:by_interface` gives the same information per
  configured interface.
  """
  @spec status() :: %{
          interfaces: [String.t()],
          active_iface: String.t() | nil,
          target_url: String.t() | nil,
          intent: Config.t() | nil,
          pac_url: String.t() | nil,
          dhcp_wpad_url: String.t() | nil,
          pac_loaded?: boolean(),
          by_interface: %{optional(String.t()) => map()},
          current: proxy()
        }
  def status, do: Selector.status()

  @doc """
  Set the URL used as the evaluation context for PAC scripts.

  Typically the upstream the device cares about (the cloud API endpoint).
  """
  @spec set_target_url(String.t()) :: :ok
  def set_target_url(url) when is_binary(url), do: Selector.set_target_url(url)

  @doc "Read the current PAC evaluation target URL (or `nil` if unset)."
  @spec get_target_url() :: String.t() | nil
  def get_target_url, do: Selector.get_target_url()

  @doc """
  Resolve the proxy for a specific URL.

  With a PAC script loaded, the script is evaluated for the given URL.
  Manual configurations apply regardless of the URL.
  """
  @spec resolve(String.t()) :: resolved()
  def resolve(url) when is_binary(url), do: Selector.resolve(url)
end
