defmodule VintageNetProxy.Fetcher do
  @moduledoc false

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
        {:error, {:body_too_large, byte_size(body)}}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp user_agent_header do
    version = Application.spec(:vintage_net_proxy, :vsn) || ~c"unknown"
    {~c"user-agent", ~c"vintage_net_proxy/" ++ version}
  end
end
