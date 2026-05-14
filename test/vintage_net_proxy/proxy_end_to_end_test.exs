defmodule VintageNetProxy.ProxyEndToEndTest do
  @moduledoc """
  Integration test against the `dev/` docker-compose stack.

  Prereq:

      docker compose -f dev/docker-compose.yml up -d

  Run:

      mix test --include integration

  Excluded from the default `mix test` so checkouts without docker
  still pass.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias VintageNetProxy.Interface

  @wpad_url "http://127.0.0.1:18080/wpad.dat"
  @proxy_host "127.0.0.1"
  @proxy_port 18888

  setup_all do
    unless wpad_reachable?() do
      flunk("""
      dev/ services aren't reachable on localhost:18080 / :18888.
      Bring them up first:

          docker compose -f dev/docker-compose.yml up -d
      """)
    end

    :ok
  end

  setup do
    iface = "e2e_#{:erlang.unique_integer([:positive])}"

    PropertyTable.put(VintageNet, ["interface", iface, "connection"], :internet)

    start_supervised!({VintageNetProxy.Supervisor, interfaces: [iface]})

    on_exit(fn ->
      for prop <- ["config", "dhcp_options", "connection"] do
        PropertyTable.delete(VintageNet, ["interface", iface, prop])
      end

      PropertyTable.delete(VintageNet, ["proxy", "config"])
    end)

    {:ok, iface: iface}
  end

  describe "PAC fetch from a real HTTP server" do
    test "fetches the WPAD and publishes {:auto, :ready}", %{iface: iface} do
      configure_auto(iface)

      assert VintageNet.get(["proxy", "config"]) == {:auto, :ready}
      assert VintageNetProxy.status().by_interface[iface].pac_loaded? == true
    end

    test "DHCP-discovered wpad URL works the same way", %{iface: iface} do
      PropertyTable.put(VintageNet, ["interface", iface, "dhcp_options"], %{wpad: @wpad_url})

      PropertyTable.put(VintageNet, ["interface", iface, "config"], %{
        type: :fake,
        proxy: %{mode: :auto}
      })

      flush(iface)

      assert VintageNet.get(["proxy", "config"]) == {:auto, :ready}
    end
  end

  describe "PAC evaluation against the served WPAD" do
    setup %{iface: iface} do
      configure_auto(iface)
      :ok
    end

    test "plain hostnames bypass the proxy" do
      assert VintageNetProxy.resolve("http://intranet/") == :direct
      assert VintageNetProxy.resolve("http://buildserver/jobs") == :direct
    end

    test "loopback bypasses" do
      assert VintageNetProxy.resolve("http://localhost:8080/") == :direct
    end

    test ".internal and .local domains bypass" do
      assert VintageNetProxy.resolve("https://wiki.internal/") == :direct
      assert VintageNetProxy.resolve("https://homepage.local/") == :direct
    end

    test "S3 buckets bypass via glob match" do
      assert VintageNetProxy.resolve("https://my-bucket.s3.amazonaws.com/") == :direct
    end

    test "general internet routes to the local tinyproxy" do
      assert VintageNetProxy.resolve("https://www.google.com/") ==
               %{scheme: :http, host: @proxy_host, port: @proxy_port}

      assert VintageNetProxy.resolve("https://github.com/") ==
               %{scheme: :http, host: @proxy_host, port: @proxy_port}
    end
  end

  describe "PAC cache lifecycle" do
    test "disconnect drops the cached script", %{iface: iface} do
      configure_auto(iface)
      assert VintageNetProxy.status().by_interface[iface].pac_loaded? == true

      PropertyTable.put(VintageNet, ["interface", iface, "connection"], :disconnected)
      flush(iface)

      assert VintageNetProxy.status().by_interface[iface].pac_loaded? == false
      assert VintageNet.get(["proxy", "config"]) == :unset
    end

    test "reconnect re-fetches the script", %{iface: iface} do
      configure_auto(iface)

      PropertyTable.put(VintageNet, ["interface", iface, "connection"], :disconnected)
      flush(iface)
      assert VintageNetProxy.status().by_interface[iface].pac_loaded? == false

      PropertyTable.put(VintageNet, ["interface", iface, "connection"], :internet)
      flush(iface)
      assert VintageNetProxy.status().by_interface[iface].pac_loaded? == true
      assert VintageNet.get(["proxy", "config"]) == {:auto, :ready}
    end
  end

  describe "tinyproxy reachability sanity check" do
    test "the resolved proxy descriptor's port is actually listening", %{iface: iface} do
      configure_auto(iface)

      descriptor = VintageNetProxy.resolve("https://example.com/")
      assert %{host: host, port: port} = descriptor

      {:ok, sock} = :gen_tcp.connect(String.to_charlist(host), port, [], 1_000)
      :gen_tcp.close(sock)
    end
  end

  describe "real udhcpc → OSEventDispatcher → our pipeline" do
    # Exercises VintageNet's actual udhcpc entry point with a realistic
    # env hash (the same shape udhcpc passes to its handler script when a
    # lease arrives). Closes the loop that the other tests fake with a
    # direct `PropertyTable.put` to dhcp_options.
    setup do
      previous = Application.get_env(:vintage_net, :udhcpc_handler)
      Application.put_env(:vintage_net, :udhcpc_handler, __MODULE__.NoOpUdhcpcHandler)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:vintage_net, :udhcpc_handler, previous),
          else: Application.delete_env(:vintage_net, :udhcpc_handler)
      end)

      :ok
    end

    test "a `bound` event with `wpad` flows end-to-end to {:auto, :ready}", %{iface: iface} do
      # :auto intent without an explicit pac_url — forces us to depend on
      # the wpad URL arriving from DHCP.
      PropertyTable.put(VintageNet, ["interface", iface, "config"], %{
        type: :fake,
        proxy: %{mode: :auto}
      })

      # Realistic udhcpc env: string keys, IP-as-string values, plus the
      # wpad URL (DHCP option 252) for which this whole library exists.
      env = %{
        "interface" => iface,
        "ip" => "10.0.0.5",
        "mask" => "24",
        "subnet" => "255.255.255.0",
        "router" => "10.0.0.1",
        "dns" => "10.0.0.1",
        "lease" => "86400",
        "siaddr" => "10.0.0.1",
        "serverid" => "10.0.0.1",
        "wpad" => @wpad_url
      }

      VintageNet.OSEventDispatcher.dispatch(["bound"], env)
      flush(iface)

      status = VintageNetProxy.status().by_interface[iface]
      assert status.dhcp_wpad_url == @wpad_url
      assert status.pac_loaded? == true
      assert VintageNet.get(["proxy", "config"]) == {:auto, :ready}

      assert VintageNetProxy.resolve("https://www.google.com/") ==
               %{scheme: :http, host: @proxy_host, port: @proxy_port}
    end

    test "a `deconfig` event clears the cached wpad URL", %{iface: iface} do
      # First load a wpad URL.
      PropertyTable.put(VintageNet, ["interface", iface, "config"], %{
        type: :fake,
        proxy: %{mode: :auto}
      })

      env_bound = %{"interface" => iface, "ip" => "10.0.0.5", "wpad" => @wpad_url}
      VintageNet.OSEventDispatcher.dispatch(["bound"], env_bound)
      flush(iface)
      assert VintageNetProxy.status().by_interface[iface].dhcp_wpad_url == @wpad_url

      # Now lose the lease.
      VintageNet.OSEventDispatcher.dispatch(["deconfig"], %{"interface" => iface})
      flush(iface)

      assert VintageNetProxy.status().by_interface[iface].dhcp_wpad_url == nil
    end
  end

  defmodule NoOpUdhcpcHandler do
    @moduledoc false
    # Skip vintage_net's real interface manipulation (ifconfig, route
    # setup) — we just want to exercise the udhcpc-env → PropertyTable
    # bridge that OSEventDispatcher provides.
    @behaviour VintageNet.OSEventDispatcher.UdhcpcHandler

    @impl true
    def deconfig(_ifname, _info), do: :ok
    @impl true
    def leasefail(_ifname, _info), do: :ok
    @impl true
    def nak(_ifname, _info), do: :ok
    @impl true
    def renew(_ifname, _info), do: :ok
    @impl true
    def bound(_ifname, _info), do: :ok
  end

  describe "actual HTTP round-trip through the resolved proxy" do
    # Sends a real HTTP request through tinyproxy at the descriptor that
    # `VintageNetProxy.resolve/1` returns, and asserts it gets forwarded
    # and the response comes back. tinyproxy uses the docker-compose
    # service DNS (`wpad`) to resolve the target host inside its container
    # network, so the test doesn't depend on host DNS or external internet.
    test "GET through the proxy returns the upstream body", %{iface: iface} do
      configure_auto(iface)

      %{host: host, port: port} = VintageNetProxy.resolve("https://www.google.com/")

      {:ok, sock} =
        :gen_tcp.connect(
          String.to_charlist(host),
          port,
          [:binary, active: false, packet: :raw],
          2_000
        )

      # HTTP proxy form: absolute URL on the request line. tinyproxy will
      # parse the host out of the URL and forward there.
      request = "GET http://wpad/wpad.dat HTTP/1.1\r\nHost: wpad\r\nConnection: close\r\n\r\n"
      :ok = :gen_tcp.send(sock, request)

      response = recv_all(sock)
      :gen_tcp.close(sock)

      assert response =~ "200 OK"
      # The body should be the actual PAC script content we serve from nginx.
      assert response =~ "FindProxyForURL"
    end
  end

  # --- helpers ---

  defp configure_auto(iface) do
    PropertyTable.put(VintageNet, ["interface", iface, "config"], %{
      type: :fake,
      proxy: %{mode: :auto, pac_url: @wpad_url}
    })

    flush(iface)
  end

  defp flush(iface) do
    _ = Interface.get(iface)
    _ = VintageNetProxy.status()
    :ok
  end

  defp wpad_reachable? do
    request = {String.to_charlist(@wpad_url), []}
    http_opts = [timeout: 1_000, connect_timeout: 1_000]

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _, _}} -> true
      _ -> false
    end
  end

  defp recv_all(sock, acc \\ <<>>) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, :closed} -> acc
      {:error, _} -> acc
    end
  end
end
