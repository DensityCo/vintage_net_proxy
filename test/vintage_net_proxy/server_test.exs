defmodule VintageNetProxy.ServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VintageNetProxy.Server

  setup do
    iface = "test#{:erlang.unique_integer([:positive])}"
    config_property = ["interface", iface, "config"]
    dhcp_property = ["interface", iface, "dhcp_options"]
    connection_property = ["interface", iface, "connection"]

    # Seed connection state before the server starts so init/1 sees the
    # interface as up. Real VintageNet emits this property; tests must
    # reproduce that to make the interface eligible for selection.
    PropertyTable.put(VintageNet, connection_property, :internet)

    pid = start_supervised!({Server, [interfaces: [iface]]})

    on_exit(fn ->
      PropertyTable.delete(VintageNet, config_property)
      PropertyTable.delete(VintageNet, dhcp_property)
      PropertyTable.delete(VintageNet, connection_property)
      PropertyTable.delete(VintageNet, ["proxy", "config"])
    end)

    {:ok,
     iface: iface,
     pid: pid,
     config_property: config_property,
     dhcp_property: dhcp_property,
     connection_property: connection_property}
  end

  describe "initial state" do
    test "publishes :unset when nothing is configured" do
      assert VintageNet.get(["proxy", "config"]) == :unset
    end

    test "status reports a clean default", %{iface: iface} do
      status = Server.status()
      assert status.interfaces == [iface]
      assert status.active_iface == nil
      assert status.target_url == nil
      assert status.intent == nil
      assert status.dhcp_wpad_url == nil
      assert status.pac_loaded? == false
      assert status.current == :unset
    end
  end

  describe "intent: :direct from interface config" do
    test "publishes :direct when interface config carries proxy: %{mode: :direct}",
         %{config_property: prop} do
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: %{mode: :direct}})

      # Subscription delivery is async; pull status to flush.
      _ = Server.status()
      assert VintageNet.get(["proxy", "config"]) == :direct
    end

    test "publishes :unset when proxy field is removed",
         %{config_property: prop} do
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: %{mode: :direct}})
      _ = Server.status()
      assert VintageNet.get(["proxy", "config"]) == :direct

      PropertyTable.put(VintageNet, prop, %{type: :fake})
      _ = Server.status()
      assert VintageNet.get(["proxy", "config"]) == :unset
    end
  end

  describe "intent: :manual from interface config" do
    test "publishes the resolved descriptor", %{config_property: prop} do
      manual = %{mode: :manual, scheme: :http, host: "p.corp", port: 8080}
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: manual})

      _ = Server.status()

      assert VintageNet.get(["proxy", "config"]) == %{
               scheme: :http,
               host: "p.corp",
               port: 8080
             }
    end

    test "preserves credentials in the published descriptor", %{config_property: prop} do
      manual = %{
        mode: :manual,
        scheme: :socks5,
        host: "s.corp",
        port: 1080,
        username: "alice",
        password: "secret"
      }

      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: manual})
      _ = Server.status()

      assert VintageNet.get(["proxy", "config"]) == %{
               scheme: :socks5,
               host: "s.corp",
               port: 1080,
               username: "alice",
               password: "secret"
             }
    end

    test "defaults scheme to :http when omitted", %{config_property: prop} do
      PropertyTable.put(VintageNet, prop, %{
        type: :fake,
        proxy: %{mode: :manual, host: "p", port: 80}
      })

      _ = Server.status()

      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "p", port: 80}
    end
  end

  describe "intent: :auto with DHCP-discovered WPAD" do
    test "ignores DHCP wpad when no proxy intent is set",
         %{dhcp_property: prop} do
      PropertyTable.put(VintageNet, prop, %{wpad: "http://wpad.test/wpad.dat"})
      _ = Server.status()

      # No intent means no proxy is resolved, even if DHCP advertised WPAD.
      assert VintageNet.get(["proxy", "config"]) == :unset
    end

    test "records DHCP wpad URL in status", %{dhcp_property: prop, iface: iface} do
      PropertyTable.put(VintageNet, prop, %{wpad: "http://wpad.test/wpad.dat"})
      status = Server.status()
      # No intent on this interface, so it isn't the active one; inspect
      # the per-interface map directly.
      assert status.by_interface[iface].dhcp_wpad_url == "http://wpad.test/wpad.dat"
    end

    test "clears DHCP wpad URL when the dhcp_options property is cleared",
         %{dhcp_property: prop, iface: iface} do
      PropertyTable.put(VintageNet, prop, %{wpad: "http://wpad.test/wpad.dat"})
      _ = Server.status()
      assert Server.status().by_interface[iface].dhcp_wpad_url == "http://wpad.test/wpad.dat"

      PropertyTable.delete(VintageNet, prop)
      _ = Server.status()
      assert Server.status().by_interface[iface].dhcp_wpad_url == nil
    end
  end

  describe "invalid proxy config in interface config" do
    test "logs a warning and leaves intent nil", %{config_property: prop} do
      log =
        capture_log(fn ->
          PropertyTable.put(VintageNet, prop, %{
            type: :fake,
            proxy: %{mode: :manual, host: "p"}
          })

          _ = Server.status()
        end)

      assert log =~ "invalid :proxy config"
      assert VintageNet.get(["proxy", "config"]) == :unset
    end
  end

  describe "target_url" do
    test "set_target_url + get_target_url round-trip" do
      assert :ok = Server.set_target_url("https://api.example.com/")
      assert Server.get_target_url() == "https://api.example.com/"
    end

    test "get_target_url is nil before any set" do
      assert Server.get_target_url() == nil
    end
  end

  describe "resolve/1" do
    test "respects manual intent regardless of URL", %{config_property: prop} do
      manual = %{mode: :manual, scheme: :http, host: "p", port: 80}
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: manual})
      _ = Server.status()

      assert Server.resolve("https://api.example.com/") ==
               %{scheme: :http, host: "p", port: 80}

      assert Server.resolve("http://intranet/") ==
               %{scheme: :http, host: "p", port: 80}
    end

    test "returns :direct for :direct intent", %{config_property: prop} do
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: %{mode: :direct}})
      _ = Server.status()

      assert Server.resolve("https://x/") == :direct
    end

    test ":direct when no intent and no override" do
      assert Server.resolve("https://x/") == :direct
    end
  end

  describe "status/0" do
    test "reflects interface config intent + target_url", %{config_property: prop} do
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: %{mode: :direct}})
      _ = Server.status()
      Server.set_target_url("https://x/")

      status = Server.status()
      assert status.intent == %{mode: :direct}
      assert status.target_url == "https://x/"
      assert status.current == :direct
    end
  end

  describe "intent: :auto end-to-end (fetch + evaluate)" do
    test "explicit :pac_url is fetched and the descriptor is published",
         %{config_property: prop} do
      port = serve_once(~s|function FindProxyForURL(url, host) { return "PROXY p.corp:8080"; }|)

      Server.set_target_url("https://api.example.com/")

      PropertyTable.put(VintageNet, prop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad.dat"}
      })

      _ = Server.status()

      assert VintageNet.get(["proxy", "config"]) ==
               %{scheme: :http, host: "p.corp", port: 8080}

      assert Server.status().pac_loaded? == true
    end

    test "DHCP-discovered WPAD URL is fetched when intent has no explicit pac_url",
         %{config_property: cprop, dhcp_property: dprop} do
      pac = """
      function FindProxyForURL(url, host) {
        if (shExpMatch(host, "*.corp")) return "PROXY corp:8080";
        return "DIRECT";
      }
      """

      port = serve_once(pac)

      Server.set_target_url("https://api.corp/")

      PropertyTable.put(VintageNet, dprop, %{wpad: "http://127.0.0.1:#{port}/wpad.dat"})
      _ = Server.status()
      PropertyTable.put(VintageNet, cprop, %{type: :fake, proxy: %{mode: :auto}})
      _ = Server.status()

      assert VintageNet.get(["proxy", "config"]) ==
               %{scheme: :http, host: "corp", port: 8080}
    end

    test "explicit :pac_url takes precedence over DHCP wpad",
         %{config_property: cprop, dhcp_property: dprop} do
      explicit_port =
        serve_once(~s|function FindProxyForURL(url, host) { return "PROXY explicit:1"; }|)

      # A second listener that should never be hit; if the server queried it,
      # accept would time out and the test would still pass — but the assertion
      # on the published descriptor would fail because it would come back with
      # the wrong host.
      {:ok, decoy_lsock} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      on_exit(fn -> :gen_tcp.close(decoy_lsock) end)
      {:ok, decoy_port} = :inet.port(decoy_lsock)

      Server.set_target_url("https://x/")

      PropertyTable.put(VintageNet, dprop, %{wpad: "http://127.0.0.1:#{decoy_port}/wpad.dat"})
      _ = Server.status()

      PropertyTable.put(VintageNet, cprop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{explicit_port}/wpad.dat"}
      })

      _ = Server.status()

      assert VintageNet.get(["proxy", "config"]) ==
               %{scheme: :http, host: "explicit", port: 1}
    end

    test "set_target_url re-publishes against the loaded PAC without re-fetching",
         %{config_property: prop} do
      pac = """
      function FindProxyForURL(url, host) {
        if (shExpMatch(host, "*.corp.example")) return "PROXY corp:8080";
        return "DIRECT";
      }
      """

      port = serve_once(pac)

      Server.set_target_url("https://api.corp.example/")

      PropertyTable.put(VintageNet, prop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad.dat"}
      })

      _ = Server.status()

      assert VintageNet.get(["proxy", "config"]) ==
               %{scheme: :http, host: "corp", port: 8080}

      Server.set_target_url("https://google.com/")
      assert VintageNet.get(["proxy", "config"]) == :direct
    end

    test "end-to-end with a representative enterprise WPAD",
         %{config_property: prop} do
      wpad = """
      function FindProxyForURL(url, host) {
        if (isPlainHostName(host)) return "DIRECT";
        if (host == "localhost") return "DIRECT";
        if (dnsDomainIs(host, ".corp.example.com")) return "DIRECT";
        if (shExpMatch(host, "*.s3.amazonaws.com")) return "DIRECT";
        return "PROXY primary-proxy:8080; DIRECT";
      }
      """

      port = serve_once(wpad)

      Server.set_target_url("https://api.corp.example.com/")

      PropertyTable.put(VintageNet, prop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad.dat"}
      })

      _ = Server.status()

      # api.corp.example.com matches the dnsDomainIs bypass → :direct
      assert VintageNet.get(["proxy", "config"]) == :direct

      # Per-URL resolution against the cached script (no re-fetch needed)
      assert Server.resolve("http://intranet/") == :direct

      assert Server.resolve("https://www.google.com/") ==
               %{scheme: :http, host: "primary-proxy", port: 8080}

      assert Server.resolve("https://my-bucket.s3.amazonaws.com/") == :direct
    end

    test "connection rising to :internet re-fetches PAC and re-publishes",
         %{config_property: cprop, connection_property: connprop} do
      # Start with the interface marked offline so the initial fetch is
      # skipped — even though intent says :auto with an explicit URL.
      PropertyTable.put(VintageNet, connprop, :disconnected)
      _ = Server.status()

      port =
        serve_once(~s|function FindProxyForURL(url, host) { return "PROXY p.corp:8080"; }|)

      Server.set_target_url("https://api.example.com/")

      PropertyTable.put(VintageNet, cprop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad.dat"}
      })

      _ = Server.status()

      # Offline: not selectable, nothing published.
      assert VintageNet.get(["proxy", "config"]) == :unset

      # Link comes up: connection handler must fetch the PAC and publish.
      PropertyTable.put(VintageNet, connprop, :internet)
      _ = Server.status()

      assert VintageNet.get(["proxy", "config"]) ==
               %{scheme: :http, host: "p.corp", port: 8080}
    end

    test "resolve/1 evaluates the PAC against the supplied URL, not the target",
         %{config_property: prop} do
      pac = """
      function FindProxyForURL(url, host) {
        if (shExpMatch(host, "*.corp.example")) return "PROXY corp:8080";
        return "DIRECT";
      }
      """

      port = serve_once(pac)

      Server.set_target_url("https://api.corp.example/")

      PropertyTable.put(VintageNet, prop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad.dat"}
      })

      _ = Server.status()

      assert Server.resolve("http://google.com/") == :direct

      assert Server.resolve("https://x.corp.example/") ==
               %{scheme: :http, host: "corp", port: 8080}
    end
  end

  describe "multi-interface priority selection" do
    setup do
      stop_supervised!(VintageNetProxy.Server)

      primary = "p#{:erlang.unique_integer([:positive])}"
      secondary = "s#{:erlang.unique_integer([:positive])}"

      PropertyTable.put(VintageNet, ["interface", primary, "connection"], :internet)
      PropertyTable.put(VintageNet, ["interface", secondary, "connection"], :internet)

      pid = start_supervised!({Server, [interfaces: [primary, secondary]]})

      on_exit(fn ->
        for iface <- [primary, secondary],
            prop <- ["config", "dhcp_options", "connection"] do
          PropertyTable.delete(VintageNet, ["interface", iface, prop])
        end

        PropertyTable.delete(VintageNet, ["proxy", "config"])
      end)

      {:ok, primary: primary, secondary: secondary, pid: pid}
    end

    test "first interface in the list with intent + up connection wins",
         %{primary: primary, secondary: secondary} do
      PropertyTable.put(VintageNet, ["interface", secondary, "config"], %{
        type: :fake,
        proxy: %{mode: :direct}
      })

      _ = Server.status()
      assert Server.status().active_iface == secondary
      assert VintageNet.get(["proxy", "config"]) == :direct

      # Once primary also has intent, it takes precedence (higher in list).
      PropertyTable.put(VintageNet, ["interface", primary, "config"], %{
        type: :fake,
        proxy: %{mode: :manual, host: "p", port: 80}
      })

      _ = Server.status()
      assert Server.status().active_iface == primary
      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "p", port: 80}
    end

    test "falls back to the next interface when active goes offline, reclaims on reconnect",
         %{primary: primary, secondary: secondary} do
      PropertyTable.put(VintageNet, ["interface", primary, "config"], %{
        type: :fake,
        proxy: %{mode: :manual, scheme: :http, host: "p1", port: 80}
      })

      PropertyTable.put(VintageNet, ["interface", secondary, "config"], %{
        type: :fake,
        proxy: %{mode: :manual, scheme: :http, host: "s1", port: 80}
      })

      _ = Server.status()
      assert Server.status().active_iface == primary
      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "p1", port: 80}

      PropertyTable.put(VintageNet, ["interface", primary, "connection"], :disconnected)
      _ = Server.status()
      assert Server.status().active_iface == secondary
      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "s1", port: 80}

      PropertyTable.put(VintageNet, ["interface", primary, "connection"], :internet)
      _ = Server.status()
      assert Server.status().active_iface == primary
      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "p1", port: 80}
    end

    test "drops cached PAC when an interface disconnects",
         %{primary: primary} do
      port = serve_once(~s|function FindProxyForURL(url, host) { return "PROXY p:1"; }|)
      Server.set_target_url("https://x/")

      PropertyTable.put(VintageNet, ["interface", primary, "config"], %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad.dat"}
      })

      _ = Server.status()
      assert Server.status().by_interface[primary].pac_loaded? == true

      PropertyTable.put(VintageNet, ["interface", primary, "connection"], :disconnected)
      _ = Server.status()
      assert Server.status().by_interface[primary].pac_loaded? == false
    end

    test "interfaces not in the configured list are ignored",
         %{primary: primary} do
      uninvited = "u#{:erlang.unique_integer([:positive])}"

      PropertyTable.put(VintageNet, ["interface", uninvited, "connection"], :internet)

      PropertyTable.put(VintageNet, ["interface", uninvited, "config"], %{
        type: :fake,
        proxy: %{mode: :manual, host: "ghost", port: 80}
      })

      _ = Server.status()

      assert Server.status().active_iface == nil
      assert VintageNet.get(["proxy", "config"]) == :unset

      # And the legitimate interface still wins when it gets intent.
      PropertyTable.put(VintageNet, ["interface", primary, "config"], %{
        type: :fake,
        proxy: %{mode: :direct}
      })

      _ = Server.status()
      assert Server.status().active_iface == primary
      assert VintageNet.get(["proxy", "config"]) == :direct

      PropertyTable.delete(VintageNet, ["interface", uninvited, "connection"])
      PropertyTable.delete(VintageNet, ["interface", uninvited, "config"])
    end
  end

  defp serve_once(body) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(lsock) end)
    {:ok, port} = :inet.port(lsock)

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(lsock, 5_000)
      {:ok, _request} = :gen_tcp.recv(sock, 0, 5_000)

      response =
        "HTTP/1.1 200 OK\r\n" <>
          "Content-Length: #{byte_size(body)}\r\n" <>
          "Content-Type: text/plain\r\n\r\n" <>
          body

      :gen_tcp.send(sock, response)
      :gen_tcp.close(sock)
    end)

    port
  end
end
