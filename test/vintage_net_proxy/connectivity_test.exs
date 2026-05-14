defmodule VintageNetProxy.ConnectivityTest do
  use ExUnit.Case, async: false

  alias VintageNetProxy.{Connectivity, Publisher}

  @config_property ["proxy", "config"]
  @connectivity_property ["proxy", "connectivity"]
  @pac_revision_property ["proxy", "pac_revision"]

  setup do
    on_exit(fn ->
      PropertyTable.delete(VintageNet, @config_property)
      PropertyTable.delete(VintageNet, @connectivity_property)
      PropertyTable.delete(VintageNet, @pac_revision_property)
    end)

    :ok
  end

  describe "module API surface" do
    test "property/0 returns the published key" do
      assert Connectivity.property() == @connectivity_property
    end

    test "get/0 returns :unknown before the checker has run" do
      PropertyTable.delete(VintageNet, @connectivity_property)
      assert Connectivity.get() == :unknown
    end

    test "check_now/0 returns :unknown when the checker isn't running" do
      assert Connectivity.check_now() == :unknown
    end

    test "status/0 returns a default shape when the checker isn't running" do
      assert Connectivity.status() == %{status: :unknown, probe_urls: [], interval: nil}
    end
  end

  describe "first probe — direct path" do
    test "publishes :ok against a healthy direct target" do
      port = accepting_target()

      VintageNet.subscribe(@connectivity_property)
      start_checker(probe_urls: ["http://127.0.0.1:#{port}/"])

      assert_receive {VintageNet, @connectivity_property, _, :ok, _}, 5_000
      assert VintageNetProxy.connectivity() == :ok
    end

    test "publishes {:error, reason} when the target is unreachable" do
      VintageNet.subscribe(@connectivity_property)
      # 127.0.0.1:1 should be guaranteed unbound.
      start_checker(probe_urls: ["http://127.0.0.1:1/"])

      assert_receive {VintageNet, @connectivity_property, _, {:error, _}, _}, 5_000
    end
  end

  describe "probe_urls fallback" do
    test "falls back to the next URL when an earlier one fails" do
      port = accepting_target()

      start_checker(
        probe_urls: [
          "http://127.0.0.1:1/",
          "http://127.0.0.1:#{port}/"
        ],
        initial_delay: 60_000
      )

      assert Connectivity.check_now() == :ok
    end

    test "stops at the first :ok — later URLs are not probed" do
      parent = self()
      port = accepting_target(parent)

      start_checker(
        probe_urls: [
          "http://127.0.0.1:#{port}/",
          # If this one were tried, the test would hang on the
          # listener — but it shouldn't be reached.
          "http://127.0.0.1:#{port}/"
        ],
        initial_delay: 60_000
      )

      assert Connectivity.check_now() == :ok
      assert_receive {:accepted, 1}, 5_000
      refute_receive {:accepted, 2}, 200
    end

    test "returns the last error when every probe URL fails" do
      start_checker(
        probe_urls: ["http://127.0.0.1:1/", "http://127.0.0.1:2/"],
        initial_delay: 60_000
      )

      assert {:error, _} = Connectivity.check_now()
    end

    test "empty probe_urls list returns :no_probe_urls_configured" do
      start_checker(probe_urls: [], initial_delay: 60_000)

      assert Connectivity.check_now() == {:error, :no_probe_urls_configured}
    end
  end

  describe "check_now/0 (synchronous probe)" do
    test "returns the probe result and updates the property" do
      port = accepting_target()
      # Long initial_delay so the auto-fire doesn't race with our manual call.
      start_checker(probe_urls: ["http://127.0.0.1:#{port}/"], initial_delay: 60_000)

      assert Connectivity.check_now() == :ok
      assert VintageNet.get(@connectivity_property) == :ok
    end
  end

  describe "re-probe on proxy config change" do
    test "a change to [\"proxy\", \"config\"] triggers a fresh probe" do
      parent = self()
      port = accepting_target(parent)

      start_checker(probe_urls: ["http://127.0.0.1:#{port}/"], initial_delay: 60_000)
      assert Connectivity.check_now() == :ok
      assert_receive {:accepted, 1}, 5_000

      # Same listener stays open; switching the published proxy should
      # drive a fresh probe at delay 0.
      PropertyTable.put(VintageNet, @config_property, :direct)

      assert_receive {:accepted, 2}, 5_000
    end
  end

  describe "re-probe on pac_revision tick" do
    test "a tick on [\"proxy\", \"pac_revision\"] triggers a fresh probe" do
      parent = self()
      port = accepting_target(parent)

      start_checker(probe_urls: ["http://127.0.0.1:#{port}/"], initial_delay: 60_000)
      assert Connectivity.check_now() == :ok
      assert_receive {:accepted, 1}, 5_000

      # An in-place PAC reload bumps pac_revision. The config property
      # is unchanged (still :auto / :unset / whatever), so this is the
      # only signal the connectivity checker has to react to.
      Publisher.bump_pac_revision()

      assert_receive {:accepted, 2}, 5_000
    end
  end

  describe "decision derived from the published proxy model" do
    test ":unset → direct probe" do
      port = accepting_target()
      PropertyTable.put(VintageNet, @config_property, :unset)
      start_checker(probe_urls: ["http://127.0.0.1:#{port}/"], initial_delay: 60_000)

      assert Connectivity.check_now() == :ok
    end

    test ":direct → direct probe" do
      port = accepting_target()
      PropertyTable.put(VintageNet, @config_property, :direct)
      start_checker(probe_urls: ["http://127.0.0.1:#{port}/"], initial_delay: 60_000)

      assert Connectivity.check_now() == :ok
    end

    test "{:manual, descriptor} → CONNECT probe via that proxy" do
      port = fake_proxy("HTTP/1.1 200 OK\r\n\r\n")
      descriptor = %{scheme: :http, host: "127.0.0.1", port: port}
      PropertyTable.put(VintageNet, @config_property, {:manual, descriptor})

      start_checker(probe_urls: ["https://target.test/"], initial_delay: 60_000)

      assert Connectivity.check_now() == :ok
    end

    test "{:manual, _} with a SOCKS scheme → :socks_not_supported" do
      descriptor = %{scheme: :socks5, host: "127.0.0.1", port: 1080}
      PropertyTable.put(VintageNet, @config_property, {:manual, descriptor})

      start_checker(probe_urls: ["https://target.test/"], initial_delay: 60_000)

      assert Connectivity.check_now() == {:error, :socks_not_supported}
    end

    test "{:auto, {:error, _}} → falls back to a direct probe" do
      port = accepting_target()
      PropertyTable.put(VintageNet, @config_property, {:auto, {:error, :nxdomain}})
      start_checker(probe_urls: ["http://127.0.0.1:#{port}/"], initial_delay: 60_000)

      # The direct probe to 127.0.0.1:port succeeds; the value just says
      # "we couldn't resolve a proxy" — Probe falls back to direct so the
      # connectivity status honestly reflects what's reachable.
      assert Connectivity.check_now() == :ok
    end

    test "{:auto, :no_url} → falls back to a direct probe" do
      port = accepting_target()
      PropertyTable.put(VintageNet, @config_property, {:auto, :no_url})
      start_checker(probe_urls: ["http://127.0.0.1:#{port}/"], initial_delay: 60_000)

      assert Connectivity.check_now() == :ok
    end

    test "{:auto, :ready} → calls VintageNetProxy.resolve and probes via the PAC's proxy" do
      proxy_port = fake_proxy("HTTP/1.1 200 OK\r\n\r\n")

      # Bring up a full Selector + an Interface snapshot whose PAC
      # routes everything through the fake proxy. The Connectivity
      # decision for {:auto, :ready} flows through VintageNetProxy.resolve,
      # which needs the Selector running to answer.
      iface = "ifc#{:erlang.unique_integer([:positive])}"
      start_supervised!({VintageNetProxy.Selector, interfaces: [iface]})

      pac = ~s|function FindProxyForURL(url, host) { return "PROXY 127.0.0.1:#{proxy_port}"; }|

      snap = %VintageNetProxy.Interface.Routing{
        iface: iface,
        intent: %{mode: :auto},
        connection: :internet,
        pac_script: pac
      }

      send(VintageNetProxy.Selector, {:interface_changed, iface, snap})
      _ = VintageNetProxy.status()

      start_checker(probe_urls: ["https://target.test/"], initial_delay: 60_000)

      assert Connectivity.check_now() == :ok
    end
  end

  # --- Helpers ---

  defp start_checker(opts) do
    opts = Keyword.put_new(opts, :initial_delay, 0)
    start_supervised!({Connectivity, opts})
  end

  # Listener that keeps accepting connections, closing each immediately.
  # If `parent` is given, each accept is reported back as
  # `{:accepted, n}` so tests can verify the number of probes.
  defp accepting_target(parent \\ nil) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(lsock)
    on_exit(fn -> :gen_tcp.close(lsock) end)

    spawn_link(fn -> accept_loop(lsock, parent, 1) end)
    port
  end

  defp accept_loop(lsock, parent, n) do
    case :gen_tcp.accept(lsock, 60_000) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        if parent, do: send(parent, {:accepted, n})
        accept_loop(lsock, parent, n + 1)

      _ ->
        :ok
    end
  end

  defp fake_proxy(response) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(lsock)
    on_exit(fn -> :gen_tcp.close(lsock) end)

    spawn_link(fn -> proxy_loop(lsock, response) end)
    port
  end

  defp proxy_loop(lsock, response) do
    case :gen_tcp.accept(lsock, 60_000) do
      {:ok, sock} ->
        _ = :gen_tcp.recv(sock, 0, 5_000)
        :gen_tcp.send(sock, response)
        :gen_tcp.close(sock)
        proxy_loop(lsock, response)

      _ ->
        :ok
    end
  end
end
