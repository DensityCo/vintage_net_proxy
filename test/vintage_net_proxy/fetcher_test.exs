defmodule VintageNetProxy.FetcherTest do
  use ExUnit.Case, async: false

  alias VintageNetProxy.Fetcher

  setup do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(lsock)
    on_exit(fn -> :gen_tcp.close(lsock) end)
    {:ok, lsock: lsock, port: port}
  end

  test "downloads a 200 response", %{lsock: lsock, port: port} do
    body = ~s|function FindProxyForURL(url, host) { return "DIRECT"; }|
    spawn_link(fn -> serve(lsock, "200 OK", body) end)

    assert {:ok, ^body} = Fetcher.get("http://127.0.0.1:#{port}/wpad.dat")
  end

  test "non-200 surfaces as :http_status", %{lsock: lsock, port: port} do
    spawn_link(fn -> serve(lsock, "404 Not Found", "missing") end)

    assert {:error, {:http_status, 404}} = Fetcher.get("http://127.0.0.1:#{port}/missing")
  end

  test "connection refused surfaces as a transport error" do
    # 127.0.0.1:1 is essentially guaranteed unbound
    assert {:error, _} = Fetcher.get("http://127.0.0.1:1/")
  end

  test "body larger than @max_size returns :body_too_large", %{lsock: lsock, port: port} do
    big = :binary.copy("x", 300 * 1024)
    spawn_link(fn -> serve(lsock, "200 OK", big) end)

    assert {:error, {:body_too_large, _}} = Fetcher.get("http://127.0.0.1:#{port}/big")
  end

  test "sends a User-Agent header", %{lsock: lsock, port: port} do
    test_pid = self()

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(lsock, 5_000)
      {:ok, request} = :gen_tcp.recv(sock, 0, 5_000)
      send(test_pid, {:request, request})

      response =
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Type: text/plain\r\n\r\n"

      :gen_tcp.send(sock, response)
      :gen_tcp.close(sock)
    end)

    Fetcher.get("http://127.0.0.1:#{port}/")
    assert_receive {:request, request}, 5_000
    assert request =~ ~r/user-agent: vintage_net_proxy\/[^\r\n]+/i
  end

  defp serve(lsock, status_line, body) do
    {:ok, sock} = :gen_tcp.accept(lsock, 5_000)
    {:ok, _request} = :gen_tcp.recv(sock, 0, 5_000)

    response =
      "HTTP/1.1 #{status_line}\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Content-Type: text/plain\r\n\r\n" <>
        body

    :gen_tcp.send(sock, response)
    :gen_tcp.close(sock)
  end
end
