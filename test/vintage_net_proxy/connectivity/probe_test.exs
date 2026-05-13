defmodule VintageNetProxy.Connectivity.ProbeTest do
  use ExUnit.Case, async: true

  alias VintageNetProxy.Connectivity.Probe

  describe ":direct decision" do
    test "succeeds when the target TCP port accepts" do
      port = listen_and_accept()
      assert Probe.run("http://127.0.0.1:#{port}/", :direct) == :ok
    end

    test "succeeds against an HTTPS-scheme URL on a reachable port" do
      port = listen_and_accept()
      assert Probe.run("https://127.0.0.1:#{port}/", :direct) == :ok
    end

    test "fails when the target port is closed" do
      # 127.0.0.1:1 is essentially guaranteed unbound
      assert {:error, _} = Probe.run("http://127.0.0.1:1/", :direct)
    end

    test "rejects malformed URLs" do
      assert {:error, {:bad_probe_url, "not a url"}} = Probe.run("not a url", :direct)
      assert {:error, {:bad_probe_url, _}} = Probe.run("http:///", :direct)
    end
  end

  describe "HTTP/HTTPS proxy decision" do
    test ":ok when the proxy returns 200 to CONNECT" do
      port = fake_proxy("HTTP/1.1 200 Connection established\r\n\r\n")
      descriptor = %{scheme: :http, host: "127.0.0.1", port: port}

      assert Probe.run("https://target.test/", descriptor) == :ok
    end

    test "surfaces non-200 CONNECT replies as :http_status" do
      port = fake_proxy("HTTP/1.1 502 Bad Gateway\r\n\r\n")
      descriptor = %{scheme: :http, host: "127.0.0.1", port: port}

      assert Probe.run("https://target.test/", descriptor) ==
               {:error, {:http_status, 502}}
    end

    test "treats :https proxy scheme the same as :http for the CONNECT path" do
      port = fake_proxy("HTTP/1.1 200 OK\r\n\r\n")
      descriptor = %{scheme: :https, host: "127.0.0.1", port: port}

      assert Probe.run("https://target.test/", descriptor) == :ok
    end

    test "transport errors surface as {:error, _} when the proxy is unreachable" do
      descriptor = %{scheme: :http, host: "127.0.0.1", port: 1}
      assert {:error, _} = Probe.run("https://target.test/", descriptor)
    end

    test "sends a well-formed CONNECT line including host and port" do
      test_pid = self()
      port = capture_request_proxy(test_pid, "HTTP/1.1 200 OK\r\n\r\n")
      descriptor = %{scheme: :http, host: "127.0.0.1", port: port}

      assert Probe.run("https://target.test:8443/", descriptor) == :ok
      assert_receive {:request, request}, 5_000
      assert request =~ "CONNECT target.test:8443 HTTP/1.1"
      assert request =~ "Host: target.test:8443"
    end

    test "uses default port 443 for https URLs and 80 for http URLs" do
      test_pid = self()
      port = capture_request_proxy(test_pid, "HTTP/1.1 200 OK\r\n\r\n")
      descriptor = %{scheme: :http, host: "127.0.0.1", port: port}

      assert Probe.run("https://target.test/", descriptor) == :ok
      assert_receive {:request, request}, 5_000
      assert request =~ "CONNECT target.test:443 HTTP/1.1"

      port = capture_request_proxy(test_pid, "HTTP/1.1 200 OK\r\n\r\n")
      descriptor = %{scheme: :http, host: "127.0.0.1", port: port}

      assert Probe.run("http://target.test/", descriptor) == :ok
      assert_receive {:request, request}, 5_000
      assert request =~ "CONNECT target.test:80 HTTP/1.1"
    end
  end

  describe "unsupported decisions" do
    test "SOCKS proxies report :socks_not_supported" do
      for scheme <- [:socks4, :socks5] do
        descriptor = %{scheme: scheme, host: "p.corp", port: 1080}

        assert Probe.run("https://target.test/", descriptor) ==
                 {:error, :socks_not_supported}
      end
    end

    test "unknown decision shapes report :unsupported_decision" do
      assert {:error, {:unsupported_decision, _}} =
               Probe.run("https://target.test/", %{scheme: :weird, host: "p", port: 1})
    end
  end

  # --- Helpers ---

  defp listen_and_accept do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(lsock)
    on_exit(fn -> :gen_tcp.close(lsock) end)

    spawn_link(fn ->
      case :gen_tcp.accept(lsock, 5_000) do
        {:ok, sock} -> :gen_tcp.close(sock)
        _ -> :ok
      end
    end)

    port
  end

  defp fake_proxy(response) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(lsock)
    on_exit(fn -> :gen_tcp.close(lsock) end)

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(lsock, 5_000)
      {:ok, _req} = :gen_tcp.recv(sock, 0, 5_000)
      :gen_tcp.send(sock, response)
      :gen_tcp.close(sock)
    end)

    port
  end

  defp capture_request_proxy(test_pid, response) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(lsock)
    on_exit(fn -> :gen_tcp.close(lsock) end)

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(lsock, 5_000)
      {:ok, req} = :gen_tcp.recv(sock, 0, 5_000)
      send(test_pid, {:request, req})
      :gen_tcp.send(sock, response)
      :gen_tcp.close(sock)
    end)

    port
  end
end
