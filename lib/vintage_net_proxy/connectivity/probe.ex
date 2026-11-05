defmodule VintageNetProxy.Connectivity.Probe do
  @moduledoc """
  Pure probe used by `VintageNetProxy.Connectivity`.

  Given a probe URL and a resolved proxy decision, attempts to verify
  that outbound traffic actually flows along the network path the
  decision implies. Returns `:ok` or `{:error, reason}` synchronously.

  Two paths:

    * `:direct` — open a plain TCP connection to the URL's host/port.
      A successful connect means the device can reach that target on
      that port without a proxy. We don't send an HTTP request or do a
      TLS handshake; the goal is to confirm the network path, not
      validate the endpoint.

    * `%{scheme: :http | :https, host: _, port: _}` — connect to the
      proxy, negotiating TLS first for HTTPS proxies, and send
      `CONNECT host:port HTTP/1.1` to it. Basic proxy credentials are
      included when present in the descriptor. A `200` response means
      the proxy successfully opened the upstream TCP connection on our
      behalf; that is "outbound through the proxy" working end-to-end.
      We close the tunnel immediately — no need to send a request body
      to know the upstream link works.

  SOCKS proxies return `{:error, :socks_not_supported}`. Supporting
  them would require a SOCKS client that this library deliberately
  doesn't carry; the explicit error is more useful than a misleading
  fallback.
  """

  @timeout 5_000
  @proxy_options [:binary, active: false, packet: :line]
  @tls_proxy_options [:binary, active: false, packet: :line, verify: :verify_none]

  @type decision :: :direct | proxy_descriptor()
  @type proxy_descriptor :: %{
          required(:scheme) => :http | :https | :socks4 | :socks5,
          required(:host) => String.t(),
          required(:port) => pos_integer(),
          optional(any) => any
        }

  @type result :: :ok | {:error, term()}

  @spec run(String.t(), decision()) :: result()
  def run(url, decision) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, scheme: scheme, port: port}
      when is_binary(host) and host != "" and is_binary(scheme) ->
        port = port || if scheme == "https", do: 443, else: 80
        probe(decision, host, port)

      _ ->
        {:error, {:bad_probe_url, url}}
    end
  end

  def run(other, _decision), do: {:error, {:bad_probe_url, other}}

  defp probe(:direct, host, port) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], @timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp probe(%{scheme: :http, host: host, port: port} = proxy, target_host, target_port)
       when is_binary(host) and is_integer(port),
       do: probe_proxy(:gen_tcp, @proxy_options, proxy, target_host, target_port)

  defp probe(%{scheme: :https, host: host, port: port} = proxy, target_host, target_port)
       when is_binary(host) and is_integer(port),
       do: probe_proxy(:ssl, @tls_proxy_options, proxy, target_host, target_port)

  defp probe(%{scheme: scheme}, _, _) when scheme in [:socks4, :socks5],
    do: {:error, :socks_not_supported}

  defp probe(other, _, _),
    do: {:error, {:unsupported_decision, other}}

  defp probe_proxy(transport, options, proxy, target_host, target_port) do
    case transport.connect(String.to_charlist(proxy.host), proxy.port, options, @timeout) do
      {:ok, socket} ->
        try do
          authorization =
            case proxy do
              %{username: username, password: password}
              when is_binary(username) and is_binary(password) ->
                credentials = Base.encode64("#{username}:#{password}")
                "Proxy-Authorization: Basic #{credentials}\r\n"

              _ ->
                ""
            end

          request =
            "CONNECT #{target_host}:#{target_port} HTTP/1.1\r\n" <>
              "Host: #{target_host}:#{target_port}\r\n" <>
              "User-Agent: vintage_net_proxy_connectivity\r\n" <>
              authorization <> "\r\n"

          with :ok <- transport.send(socket, request),
               {:ok, status_line} <- transport.recv(socket, 0, @timeout) do
            case String.split(status_line, " ", parts: 3) do
              [_protocol, "200", _reason] ->
                :ok

              [_protocol, status, _reason] ->
                case Integer.parse(status) do
                  {code, _rest} -> {:error, {:http_status, code}}
                  :error -> {:error, :bad_proxy_response}
                end

              _ ->
                {:error, :bad_proxy_response}
            end
          end
        after
          transport.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
