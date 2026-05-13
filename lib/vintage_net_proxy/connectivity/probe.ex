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

    * `%{scheme: :http | :https, host: _, port: _}` — open a TCP
      connection to the proxy and send `CONNECT host:port HTTP/1.1`
      to it. A `200` response means the proxy successfully opened the
      upstream TCP connection on our behalf; that is "outbound through
      the proxy" working end-to-end. We close the tunnel immediately —
      no need to send a request body to know the upstream link works.

  SOCKS proxies return `{:error, :socks_not_supported}`. Supporting
  them would require a SOCKS client that this library deliberately
  doesn't carry; the explicit error is more useful than a misleading
  fallback.
  """

  @timeout 5_000

  @type decision :: :direct | proxy_descriptor()
  @type proxy_descriptor :: %{
          required(:scheme) => :http | :https | :socks4 | :socks5,
          required(:host) => String.t(),
          required(:port) => pos_integer(),
          optional(any) => any
        }

  @type result :: :ok | {:error, term()}

  @spec run(String.t(), decision()) :: result()
  def run(url, decision) do
    with {:ok, host, port} <- parse(url) do
      dispatch(decision, host, port)
    end
  end

  defp dispatch(:direct, host, port),
    do: direct_probe(host, port)

  defp dispatch(%{scheme: scheme, host: phost, port: pport}, host, port)
       when scheme in [:http, :https] and is_binary(phost) and is_integer(pport),
       do: connect_probe(host, port, phost, pport)

  defp dispatch(%{scheme: scheme}, _, _) when scheme in [:socks4, :socks5],
    do: {:error, :socks_not_supported}

  defp dispatch(other, _, _),
    do: {:error, {:unsupported_decision, other}}

  defp direct_probe(host, port) do
    case :gen_tcp.connect(charlist(host), port, [:binary, active: false], @timeout) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect_probe(target_host, target_port, proxy_host, proxy_port) do
    opts = [:binary, active: false, packet: :line]

    case :gen_tcp.connect(charlist(proxy_host), proxy_port, opts, @timeout) do
      {:ok, sock} ->
        try do
          req = build_connect(target_host, target_port)

          with :ok <- :gen_tcp.send(sock, req),
               {:ok, status_line} <- :gen_tcp.recv(sock, 0, @timeout) do
            parse_status(status_line)
          end
        after
          :gen_tcp.close(sock)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_connect(host, port) do
    "CONNECT #{host}:#{port} HTTP/1.1\r\n" <>
      "Host: #{host}:#{port}\r\n" <>
      "User-Agent: vintage_net_proxy_connectivity\r\n\r\n"
  end

  defp parse_status(line) do
    case String.split(line, " ", parts: 3) do
      [_proto, "200", _] ->
        :ok

      [_proto, code, _] ->
        case Integer.parse(code) do
          {n, _} -> {:error, {:http_status, n}}
          :error -> {:error, :bad_proxy_response}
        end

      _ ->
        {:error, :bad_proxy_response}
    end
  end

  defp parse(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, scheme: scheme, port: port}
      when is_binary(host) and host != "" and is_binary(scheme) ->
        {:ok, host, port || default_port(scheme)}

      _ ->
        {:error, {:bad_probe_url, url}}
    end
  end

  defp parse(other), do: {:error, {:bad_probe_url, other}}

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_), do: 80

  defp charlist(s) when is_binary(s), do: String.to_charlist(s)
end
