defmodule VintageNetProxy do
  @moduledoc """
  Resolve the system proxy from DHCP Option 252 (WPAD) or manual
  configuration, and expose the result as a VintageNet property.

  ## Property

  The current proxy is published at `["proxy", "config"]` in the `VintageNet`
  property table as one of:

    * `:unset` — no proxy info available yet
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

  ## Runtime configuration

  Everything is settable at runtime; there's no compile-time `config` to
  wire up.

  ### Manual override

      # Simple HTTP (most common):
      VintageNetProxy.set_manual("proxy.corp.example", 8080)

      # Full descriptor (other schemes / auth):
      VintageNetProxy.set_manual(%{
        scheme: :socks5,
        host: "socks.corp.example",
        port: 1080,
        username: "alice",
        password: "secret"
      })

      VintageNetProxy.set_direct()
      VintageNetProxy.clear()

  ### Target URL (PAC evaluation context)

      VintageNetProxy.set_target_url("https://api.example.com/")
      VintageNetProxy.get_target_url()

  When a PAC script is loaded, it's evaluated against this URL and the
  result is published.

  ### WPAD URL (PAC source)

      VintageNetProxy.set_wpad_url("http://wpad.corp.example/wpad.dat")
      VintageNetProxy.clear_wpad_url()

  ## Per-URL resolution (advanced)

      VintageNetProxy.resolve("https://api.example.com/")
      #=> %{scheme: :http, host: "corp-proxy", port: 8080}

      VintageNetProxy.resolve("http://intranet/")
      #=> :direct
  """

  alias VintageNetProxy.Server

  @property ["proxy", "config"]

  @type scheme :: :http | :https | :socks4 | :socks5

  @typedoc """
  Map describing a proxy. `:scheme`, `:host`, `:port` are always present.
  `:username` and `:password` are present only for authenticated proxies
  (typically set via `set_manual/1`; the bundled PAC parser does not parse
  credentials from PAC URLs).
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
  Introspection snapshot — current internal state. Useful for IEx-side
  debugging and health checks.
  """
  @spec status() :: %{
          iface: String.t(),
          target_url: String.t() | nil,
          wpad_url: String.t() | nil,
          override: :direct | proxy_descriptor() | nil,
          pac_loaded?: boolean(),
          current: proxy()
        }
  def status, do: Server.status()

  @doc "Manually configure an HTTP proxy. Overrides any DHCP/WPAD value."
  @spec set_manual(String.t(), pos_integer()) :: :ok
  def set_manual(host, port) when is_binary(host) and is_integer(port) and port > 0 do
    Server.set_override(%{scheme: :http, host: host, port: port})
  end

  @doc """
  Manually configure a proxy via a full descriptor map. Use this for
  non-HTTP schemes or proxies requiring credentials.
  """
  @spec set_manual(proxy_descriptor()) :: :ok
  def set_manual(%{scheme: scheme, host: host, port: port} = desc)
      when scheme in [:http, :https, :socks4, :socks5] and
             is_binary(host) and is_integer(port) and port > 0 do
    Server.set_override(desc)
  end

  @doc "Force `:direct` (bypass any proxy). Overrides any DHCP/WPAD value."
  @spec set_direct() :: :ok
  def set_direct, do: Server.set_override(:direct)

  @doc "Clear any manual override; revert to whatever DHCP/WPAD provides."
  @spec clear() :: :ok
  def clear, do: Server.clear_override()

  @doc """
  Set the URL used as the evaluation context for PAC scripts.

  Typically the upstream the device cares about (the cloud API endpoint).
  Triggers re-publish of the resolved proxy.
  """
  @spec set_target_url(String.t()) :: :ok
  def set_target_url(url) when is_binary(url), do: Server.set_target_url(url)

  @doc "Read the current PAC evaluation target URL (or `nil` if unset)."
  @spec get_target_url() :: String.t() | nil
  def get_target_url, do: Server.get_target_url()

  @doc """
  Set the WPAD URL programmatically. Triggers a PAC fetch + re-publish.

  Equivalent to writing `["interface", iface, "wpad_url"]` to the
  VintageNet property table directly.
  """
  @spec set_wpad_url(String.t()) :: :ok
  def set_wpad_url(url) when is_binary(url), do: Server.set_wpad_url(url)

  @doc "Clear the WPAD URL. Reverts to `:unset` unless a manual override is in place."
  @spec clear_wpad_url() :: :ok
  def clear_wpad_url, do: Server.clear_wpad_url()

  @doc """
  Resolve the proxy for a specific URL.

  Manual overrides apply regardless of the URL. With a PAC script loaded,
  the script is evaluated for the given URL.
  """
  @spec resolve(String.t()) :: resolved()
  def resolve(url) when is_binary(url), do: Server.resolve(url)
end
