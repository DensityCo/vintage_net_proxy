defmodule VintageNetProxy.Intent do
  require Logger

  @moduledoc """
  The user's proxy intent: schema, validator, type, and helpers.

  Proxy intent is expressed as a `:proxy` field inside a VintageNet
  interface configuration map. The library reads that field from
  `["interface", ifname, "config"]`, normalizes it through this
  module, and combines the result with DHCP-supplied information
  (Option 252 / WPAD) to produce the resolved proxy published at
  `["proxy", "config"]`.

  ## Modes

  The schema follows GNOME's `org.gnome.system.proxy` taxonomy
  (`:direct | :auto | :manual`), which is the de facto Linux desktop
  convention adopted by Chrome, Firefox, NetworkManager, and others.

  ### Direct — bypass any proxy

      %{mode: :direct}

  ### Auto — PAC-based discovery

  Without `:pac_url`, the proxy is discovered from DHCP Option 252
  (WPAD) for the interface:

      %{mode: :auto}

  Or pin the PAC URL explicitly:

      %{mode: :auto, pac_url: "http://wpad.corp/wpad.dat"}

  ### Manual — explicit proxy

      %{
        mode: :manual,
        scheme: :http,            # :http | :https | :socks4 | :socks5
        host: "proxy.corp",
        port: 8080,
        username: "alice",        # optional
        password: "secret",       # optional
        bypass: ["*.local"]       # optional, reserved for future use
      }

  `:scheme` defaults to `:http` if omitted.

  ## Usage with VintageNet

      VintageNet.configure("wlan0", %{
        type: VintageNetWiFi,
        ipv4: %{method: :dhcp},
        proxy: %{mode: :auto}
      })
  """

  @schemes [:http, :https, :socks4, :socks5]

  @typedoc "Proxy scheme used by manual configurations."
  @type scheme :: :http | :https | :socks4 | :socks5

  @typedoc """
  Direct mode: bypass any proxy.
  """
  @type direct :: %{required(:mode) => :direct}

  @typedoc """
  Auto mode: discover the proxy via a PAC script. Without `:pac_url`,
  the URL is taken from DHCP Option 252 (WPAD).
  """
  @type auto :: %{required(:mode) => :auto, optional(:pac_url) => String.t()}

  @typedoc """
  Manual mode: explicit proxy descriptor.
  """
  @type manual :: %{
          required(:mode) => :manual,
          required(:scheme) => scheme(),
          required(:host) => String.t(),
          required(:port) => pos_integer(),
          optional(:username) => String.t(),
          optional(:password) => String.t(),
          optional(:bypass) => [String.t()]
        }

  @typedoc "A normalized proxy intent."
  @type t :: direct() | auto() | manual()

  @typedoc """
  The runtime proxy descriptor published on `["proxy", "config"]`. A
  `:manual` intent stripped of config-only fields (`:mode`, `:bypass`).
  """
  @type descriptor :: %{
          required(:scheme) => scheme(),
          required(:host) => String.t(),
          required(:port) => pos_integer(),
          optional(:username) => String.t(),
          optional(:password) => String.t()
        }

  @doc """
  Validate and normalize a `:proxy` configuration map.

  Returns `{:ok, intent}` for valid input or `{:error, reason}` for
  invalid input. Normalization fills in defaults (e.g., `:scheme`
  defaults to `:http` for manual configurations) and strips unknown
  keys.
  """
  @spec normalize(map()) :: {:ok, t()} | {:error, String.t()}
  def normalize(config) when is_map(config) do
    case Map.get(config, :mode) do
      :direct -> {:ok, %{mode: :direct}}
      :auto -> normalize_auto(config)
      :manual -> normalize_manual(config)
      nil -> {:error, "missing :mode (expected :direct | :auto | :manual)"}
      other -> {:error, "invalid :mode #{inspect(other)} (expected :direct | :auto | :manual)"}
    end
  end

  def normalize(other), do: {:error, "expected a map, got #{inspect(other)}"}

  @doc """
  Same as `normalize/1` but raises `ArgumentError` on invalid input.
  """
  @spec normalize!(map()) :: t()
  def normalize!(config) do
    case normalize(config) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise ArgumentError, "invalid proxy config: #{reason}"
    end
  end

  @doc "Valid proxy schemes."
  @spec schemes() :: [scheme()]
  def schemes, do: @schemes

  @doc """
  Extract the normalized intent from a VintageNet interface config map.

  Returns:

    * `{:ok, intent}` — valid `:proxy` field present.
    * `{:ok, nil}` — no `:proxy` field, or input isn't a map. Not an
      error: "no proxy intent" is a legitimate state.
    * `{:error, reason}` — `:proxy` is present but invalid. Callers
      that just want an intent value should use `adopt/2`, which
      logs and collapses errors to `nil`.
  """
  @spec from_vintage_net_config(term()) :: {:ok, t() | nil} | {:error, String.t()}
  def from_vintage_net_config(%{proxy: raw}) when is_map(raw), do: normalize(raw)
  def from_vintage_net_config(_), do: {:ok, nil}

  @doc """
  Adopt the `:proxy` field of a VintageNet config as this interface's
  intent. Returns the normalized intent on success or `nil` on either
  "no proxy configured" or invalid input; invalid input is logged at
  `:warning` with the supplied `iface` for context.
  """
  @spec adopt(term(), String.t()) :: t() | nil
  def adopt(config, iface) do
    case from_vintage_net_config(config) do
      {:ok, intent} ->
        intent

      {:error, reason} ->
        Logger.warning("VintageNetProxy: invalid :proxy config on #{iface}: #{reason}")
        nil
    end
  end

  @doc """
  Convert a `:manual` intent into the runtime proxy descriptor
  published on `["proxy", "config"]`.

  Strips config-only fields (`:mode`, `:bypass`) and keeps the
  scheme/host/port plus any credentials.
  """
  @spec to_descriptor(manual()) :: descriptor()
  def to_descriptor(%{mode: :manual} = intent),
    do: Map.take(intent, [:scheme, :host, :port, :username, :password])

  defp normalize_auto(config) do
    case Map.get(config, :pac_url) do
      nil ->
        {:ok, %{mode: :auto}}

      url when is_binary(url) and url != "" ->
        {:ok, %{mode: :auto, pac_url: url}}

      other ->
        {:error, ":pac_url must be a non-empty string, got #{inspect(other)}"}
    end
  end

  defp normalize_manual(config) do
    with {:ok, host} <- fetch_string(config, :host),
         {:ok, port} <- fetch_port(config, :port),
         {:ok, scheme} <- fetch_scheme(config),
         {:ok, optional} <- fetch_optional(config) do
      base = %{mode: :manual, scheme: scheme, host: host, port: port}
      {:ok, Map.merge(base, optional)}
    end
  end

  defp fetch_string(config, key) do
    case Map.get(config, key) do
      s when is_binary(s) and s != "" -> {:ok, s}
      other -> {:error, "#{inspect(key)} must be a non-empty string, got #{inspect(other)}"}
    end
  end

  defp fetch_port(config, key) do
    case Map.get(config, key) do
      p when is_integer(p) and p > 0 and p < 65_536 ->
        {:ok, p}

      other ->
        {:error, "#{inspect(key)} must be a positive integer < 65536, got #{inspect(other)}"}
    end
  end

  defp fetch_scheme(config) do
    case Map.get(config, :scheme, :http) do
      scheme when scheme in @schemes -> {:ok, scheme}
      other -> {:error, ":scheme must be one of #{inspect(@schemes)}, got #{inspect(other)}"}
    end
  end

  defp fetch_optional(config) do
    with {:ok, creds} <- fetch_credentials(config),
         {:ok, bypass} <- fetch_bypass(config) do
      {:ok, Map.merge(creds, bypass)}
    end
  end

  defp fetch_credentials(config) do
    case {Map.get(config, :username), Map.get(config, :password)} do
      {nil, nil} ->
        {:ok, %{}}

      {u, p} when is_binary(u) and is_binary(p) ->
        {:ok, %{username: u, password: p}}

      _ ->
        {:error, ":username and :password must be supplied together as strings"}
    end
  end

  defp fetch_bypass(config) do
    case Map.get(config, :bypass) do
      nil ->
        {:ok, %{}}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, %{bypass: list}}
        else
          {:error, ":bypass must be a list of strings"}
        end

      other ->
        {:error, ":bypass must be a list of strings, got #{inspect(other)}"}
    end
  end
end
