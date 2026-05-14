defmodule VintageNetProxy.Fetcher do
  @moduledoc """
  Synchronous HTTP GET for PAC scripts.

  Wraps `:httpc` with a 5-second timeout and a 256 KiB body cap.
  Returns `{:ok, body}` or `{:error, reason}`, and logs a warning on
  every failure path (oversize body, non-200 status, transport error).
  Callers (`Interface`) invoke this inside their own GenServer mailbox;
  blocking there is per-interface and doesn't affect the Selector or
  sibling interfaces.
  """

  require Logger

  @max_size 256 * 1024
  @timeout 5_000

  @spec get(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get(url) when is_binary(url) do
    request = {String.to_charlist(url), [user_agent_header()]}
    http_opts = [timeout: @timeout, connect_timeout: @timeout]
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
  end

  defp log_failure(url, reason) do
    Logger.warning("VintageNetProxy.Fetcher: GET #{inspect(url)} failed: #{inspect(reason)}")
  end

  defp user_agent_header do
    version = Application.spec(:vintage_net_proxy, :vsn) || ~c"unknown"
    {~c"user-agent", ~c"vintage_net_proxy/" ++ version}
  end
end
