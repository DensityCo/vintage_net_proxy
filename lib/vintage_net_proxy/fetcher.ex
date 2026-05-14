defmodule VintageNetProxy.Fetcher do
  @moduledoc """
  Synchronous HTTP GET for PAC scripts.

  Wraps `:httpc` with a 5-second timeout and a 256 KiB body cap.
  Returns `{:ok, body}` or `{:error, reason}`, and logs a warning on
  every failure path (oversize body, non-200 status, transport error).
  Callers (`Interface`) invoke this inside their own GenServer mailbox;
  blocking there is per-interface and doesn't affect the Selector or
  sibling interfaces.

  ### TLS

  Explicit `ssl` options are always passed to `:httpc`. This is load-
  bearing on OTP 26+: `:httpc.http_options_default/0` otherwise calls
  `:public_key.cacerts_get/0` when *any* request is made (HTTP or
  HTTPS), and on systems without an OS CA store — e.g. Nerves images —
  that raises `FunctionClauseError` from `pubkey_os_cacerts`.

  For `https://` URLs we attempt `:public_key.cacerts_get/0`; if the
  OS has no usable CA store, `get/1` returns `{:error, :no_cacerts}`
  rather than silently weakening verification. Ship a CA bundle (e.g.
  via `castore`) and set
  `config :vintage_net_proxy, :fetcher, cacerts: CAStore.file_path()`
  to enable HTTPS PAC fetching on such systems.

  For `http://` URLs the ssl options are unused at the wire level —
  we still pass them to short-circuit the default builder.
  """

  require Logger

  @max_size 256 * 1024
  @timeout 5_000

  @spec get(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get(url) when is_binary(url) do
    with {:ok, ssl_opts} <- ssl_opts(url) do
      request = {String.to_charlist(url), [user_agent_header()]}
      http_opts = [timeout: @timeout, connect_timeout: @timeout, ssl: ssl_opts]
      opts = [body_format: :binary]

      case :httpc.request(:get, request, http_opts, opts) do
        {:ok, {{_, 200, _}, _, body}} when byte_size(body) <= @max_size ->
          {:ok, body}

        {:ok, {{_, 200, _}, _, body}} ->
          reason = {:body_too_large, byte_size(body)}
          log_failure(url, reason)
          {:error, reason}

        {:ok, {{_, status, _}, _, _}} ->
          reason = {:http_status, status}
          log_failure(url, reason)
          {:error, reason}

        {:error, reason} ->
          log_failure(url, reason)
          {:error, reason}
      end
    else
      {:error, reason} ->
        log_failure(url, reason)
        {:error, reason}
    end
  end

  defp ssl_opts(url) do
    scheme =
      case URI.parse(url) do
        %URI{scheme: s} when is_binary(s) -> String.downcase(s)
        _ -> nil
      end

    case scheme do
      "https" -> https_opts()
      _ -> {:ok, [verify: :verify_none]}
    end
  end

  defp https_opts do
    case configured_cacerts() || safe_os_cacerts() do
      {:cacertfile, path} ->
        {:ok, [verify: :verify_peer, cacertfile: path] ++ tls_hardening()}

      {:cacerts, certs} ->
        {:ok, [verify: :verify_peer, cacerts: certs] ++ tls_hardening()}

      nil ->
        {:error, :no_cacerts}
    end
  end

  defp configured_cacerts do
    cfg = Application.get_env(:vintage_net_proxy, :fetcher, [])

    cond do
      path = Keyword.get(cfg, :cacertfile) -> {:cacertfile, path}
      certs = Keyword.get(cfg, :cacerts) -> {:cacerts, certs}
      true -> nil
    end
  end

  defp safe_os_cacerts do
    {:cacerts, :public_key.cacerts_get()}
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp tls_hardening do
    [
      depth: 4,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp log_failure(url, reason) do
    Logger.warning("VintageNetProxy.Fetcher: GET #{inspect(url)} failed: #{inspect(reason)}")
  end

  defp user_agent_header do
    version = Application.spec(:vintage_net_proxy, :vsn) || ~c"unknown"
    {~c"user-agent", ~c"vintage_net_proxy/" ++ version}
  end
end
