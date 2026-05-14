defmodule VintageNetProxy.Interface.Proxy do
  @moduledoc """
  Per-interface proxy model and the pure queries over it.

  This is everything one interface knows about its proxy situation —
  the user's intent, the connectivity and DHCP options observed from
  VintageNet, the cached PAC script (if any), and the local IP that
  PAC scripts may inspect via `myIpAddress()`.

  Fetch failures aren't stored. `VintageNetProxy.Fetcher` logs every
  failure on the way out; the proxy state simply reflects "we don't
  have a PAC script right now," and the next PropertyTable event will
  trigger another fetch attempt.

  Functions here are pure given their arguments. Two operations
  bridge to the outside world via supplied callbacks or helpers:
  `refresh_cache/2` takes a fetcher function and invokes it, and
  `put_intent_from_config/2` delegates to `Intent.adopt/2` (which
  logs on invalid input). The `VintageNetProxy.Interface` GenServer
  subscribes to PropertyTable and supplies the real `Fetcher.get/1`;
  tests can pass a stub fetcher instead.
  """

  alias VintageNetProxy.{Addresses, Intent, PAC, Wpad}

  @up_states [:internet, :lan]

  defstruct iface: nil,
            intent: nil,
            dhcp_wpad_url: nil,
            dhcp_domain: nil,
            pac_script: nil,
            connection: nil,
            local_ip: nil

  @type t :: %__MODULE__{
          iface: String.t() | nil,
          intent: Intent.t() | nil,
          dhcp_wpad_url: String.t() | nil,
          dhcp_domain: String.t() | nil,
          pac_script: String.t() | nil,
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

  @doc "Empty proxy for `iface`, before any property has been observed."
  @spec new(String.t()) :: t()
  def new(iface), do: %__MODULE__{iface: iface}

  # --- Pure field setters ---

  @doc "Set the normalized intent. Pass `nil` to clear."
  @spec put_intent(t(), Intent.t() | nil) :: t()
  def put_intent(proxy, intent), do: %{proxy | intent: intent}

  @doc """
  Adopt the `:proxy` field of a VintageNet config payload as this
  interface's intent. Invalid input is logged (via `Intent.adopt/2`)
  and treated as "no intent."
  """
  @spec put_intent_from_config(t(), term()) :: t()
  def put_intent_from_config(proxy, config),
    do: put_intent(proxy, Intent.adopt(config, proxy.iface))

  @doc "Set the connection status (`:internet | :lan | :disconnected | ...`)."
  @spec put_connection(t(), atom() | nil) :: t()
  def put_connection(proxy, conn), do: %{proxy | connection: conn}

  @doc "Extract option 252 (wpad URL) and option 15 (domain) from VintageNet's `dhcp_options` payload."
  @spec put_dhcp_options(t(), term()) :: t()
  def put_dhcp_options(proxy, opts) do
    {wpad, domain} = Wpad.from_dhcp_options(opts)
    %{proxy | dhcp_wpad_url: wpad, dhcp_domain: domain}
  end

  @doc "Extract the first IPv4 string from VintageNet's `addresses` payload."
  @spec put_addresses(t(), term()) :: t()
  def put_addresses(proxy, addresses),
    do: %{proxy | local_ip: Addresses.first_ipv4(addresses)}

  # --- Cache machinery ---

  @doc """
  Apply `change_fn` to the proxy, then invalidate the PAC cache if
  the effective URL changed. Same-URL transitions preserve the cached
  script (free dedup); any other transition clears `pac_script` so
  the next fetch can populate from the new URL.
  """
  @spec transition(t(), (t() -> t())) :: t()
  def transition(proxy, change_fn) do
    old_url = effective_pac_url(proxy)
    new_proxy = change_fn.(proxy)

    if effective_pac_url(new_proxy) == old_url do
      new_proxy
    else
      %{new_proxy | pac_script: nil}
    end
  end

  @doc """
  The URL to fetch right now, or `:none` if no fetch should be
  performed — either because the script is already cached or because
  no PAC URL is currently available (intent isn't `:auto`, connection
  isn't up, or no URL source has been advertised).
  """
  @spec fetch_target(t()) :: {:ok, String.t()} | :none
  def fetch_target(%{pac_script: script}) when is_binary(script), do: :none

  def fetch_target(proxy) do
    case effective_pac_url(proxy) do
      nil -> :none
      url -> {:ok, url}
    end
  end

  @doc "Record a successful PAC fetch."
  @spec cache_script(t(), String.t()) :: t()
  def cache_script(proxy, script), do: %{proxy | pac_script: script}

  @doc """
  Fetch a fresh PAC script through `fetcher` if one is needed and
  cache it on success. Leaves the proxy unchanged when no fetch is
  due (script already cached, no URL available) or the fetch fails.
  `fetcher` is `(String.t() -> {:ok, String.t()} | {:error, term()})`,
  typically `&VintageNetProxy.Fetcher.get/1`.
  """
  @spec refresh_cache(t(), (String.t() -> {:ok, String.t()} | {:error, term()})) :: t()
  def refresh_cache(proxy, fetcher) do
    with {:ok, url} <- fetch_target(proxy),
         {:ok, script} <- fetcher.(url) do
      cache_script(proxy, script)
    else
      _ -> proxy
    end
  end

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
  def eligible?(proxy),
    do: proxy.intent != nil and proxy.connection in @up_states

  @doc """
  The proxy value this interface would publish if it were active.

  Returns one of:

    * `:unset` — no intent
    * `:direct` — direct mode
    * `{:manual, descriptor}` — explicit proxy from manual mode
    * `{:auto, :ready}` — auto mode, PAC script loaded
    * `{:auto, :no_pac}` — auto mode, no PAC script available (no URL
      source yet, or the last fetch failed). Check the logs from
      `VintageNetProxy.Fetcher` for the specific failure reason.
  """
  @spec value(t()) :: term()
  def value(%{intent: nil}), do: :unset
  def value(%{intent: %{mode: :direct}}), do: :direct
  def value(%{intent: %{mode: :manual} = m}), do: {:manual, Intent.to_descriptor(m)}

  def value(%{intent: %{mode: :auto}, pac_script: script}) when is_binary(script),
    do: {:auto, :ready}

  def value(%{intent: %{mode: :auto}}), do: {:auto, :no_pac}

  def value(_), do: :unset

  @doc """
  Resolve the proxy for `url` given this interface's proxy model.

  Returns `{:ok, directive}` when a decisive answer was reached and
  `{:error, reason}` when it wasn't. `directive` is `:direct` or a
  proxy descriptor.

  Error reasons:

    * `:pac_fallthrough` — PAC matched no rule *and* no extractable
      default. The script is malformed or uses syntax this evaluator
      silently skips. `VintageNetProxy.PAC` logs at `:warning` when
      this happens.
    * `:no_pac` — auto mode, but no PAC script is currently loaded
      (no URL source, or the last fetch failed). Check
      `VintageNetProxy.Fetcher` logs for the specific failure reason.
    * `:no_proxy_resolved` — no intent on this interface.

  PAC results — whether they came from a matched rule or from the
  script's default — are returned faithfully as `{:ok, directive}`.
  "The script's default is `DIRECT`" is information about what the
  script says, not an error; deployments that consider default-DIRECT
  misconfigured should lint the PAC source.
  """
  @spec resolve(t(), String.t()) :: resolve_result()
  def resolve(proxy, url)

  def resolve(%{intent: %{mode: :direct}}, _url), do: {:ok, :direct}

  def resolve(%{intent: %{mode: :manual} = m}, _url),
    do: {:ok, Intent.to_descriptor(m)}

  def resolve(%{intent: %{mode: :auto}, pac_script: script, local_ip: local_ip}, url)
      when is_binary(script),
      do: PAC.find_proxy(script, url, local_ip: local_ip)

  def resolve(%{intent: %{mode: :auto}}, _url), do: {:error, :no_pac}

  def resolve(_proxy, _url), do: {:error, :no_proxy_resolved}

  @doc "Introspection snapshot."
  @spec snapshot(t()) :: map()
  def snapshot(proxy) do
    %{
      iface: proxy.iface,
      eligible?: eligible?(proxy),
      value: value(proxy),
      intent: proxy.intent,
      connection: proxy.connection,
      pac_loaded?: not is_nil(proxy.pac_script),
      dhcp_wpad_url: proxy.dhcp_wpad_url,
      dhcp_domain: proxy.dhcp_domain,
      pac_url: configured_pac_url(proxy),
      local_ip: proxy.local_ip
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
