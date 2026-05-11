defmodule VintageNetProxyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    iface = "test#{:erlang.unique_integer([:positive])}"
    config_property = ["interface", iface, "config"]
    dhcp_property = ["interface", iface, "dhcp_options"]
    connection_property = ["interface", iface, "connection"]

    # Seed connection before the tree starts so the Interface picks up
    # `:internet` in its init and is immediately eligible for selection.
    PropertyTable.put(VintageNet, connection_property, :internet)

    start_supervised!({VintageNetProxy.Supervisor, interfaces: [iface]})

    on_exit(fn ->
      for prop <- [config_property, dhcp_property, connection_property] do
        PropertyTable.delete(VintageNet, prop)
      end

      PropertyTable.delete(VintageNet, ["proxy", "config"])
    end)

    {:ok,
     iface: iface,
     config_property: config_property,
     dhcp_property: dhcp_property,
     connection_property: connection_property}
  end

  describe "initial state" do
    test "publishes :unset when nothing is configured" do
      assert VintageNet.get(["proxy", "config"]) == :unset
    end

    test "status reports a clean default", %{iface: iface} do
      status = VintageNetProxy.status()
      assert status.interfaces == [iface]
      assert status.active_iface == nil
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

      _ = VintageNetProxy.status()
      assert VintageNet.get(["proxy", "config"]) == :direct
    end

    test "publishes :unset when proxy field is removed",
         %{config_property: prop} do
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: %{mode: :direct}})
      _ = VintageNetProxy.status()
      assert VintageNet.get(["proxy", "config"]) == :direct

      PropertyTable.put(VintageNet, prop, %{type: :fake})
      _ = VintageNetProxy.status()
      assert VintageNet.get(["proxy", "config"]) == :unset
    end
  end

  describe "intent: :manual from interface config" do
    test "publishes the resolved descriptor", %{config_property: prop} do
      manual = %{mode: :manual, scheme: :http, host: "p.corp", port: 8080}
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: manual})

      _ = VintageNetProxy.status()

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
      _ = VintageNetProxy.status()

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

      _ = VintageNetProxy.status()

      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "p", port: 80}
    end
  end

  describe "intent: :auto with DHCP-discovered WPAD" do
    test "ignores DHCP wpad when no proxy intent is set",
         %{dhcp_property: prop} do
      PropertyTable.put(VintageNet, prop, %{wpad: "http://wpad.test/wpad.dat"})
      _ = VintageNetProxy.status()

      assert VintageNet.get(["proxy", "config"]) == :unset
    end

    test "records DHCP wpad URL in status", %{dhcp_property: prop, iface: iface} do
      PropertyTable.put(VintageNet, prop, %{wpad: "http://wpad.test/wpad.dat"})
      status = VintageNetProxy.status()
      # Without an intent, this interface isn't active; check by_interface.
      assert status.by_interface[iface].dhcp_wpad_url == "http://wpad.test/wpad.dat"
    end

    test "clears DHCP wpad URL when the dhcp_options property is cleared",
         %{dhcp_property: prop, iface: iface} do
      PropertyTable.put(VintageNet, prop, %{wpad: "http://wpad.test/wpad.dat"})
      _ = VintageNetProxy.status()

      assert VintageNetProxy.status().by_interface[iface].dhcp_wpad_url ==
               "http://wpad.test/wpad.dat"

      PropertyTable.delete(VintageNet, prop)
      _ = VintageNetProxy.status()
      assert VintageNetProxy.status().by_interface[iface].dhcp_wpad_url == nil
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

          _ = VintageNetProxy.status()
        end)

      assert log =~ "invalid :proxy config"
      assert VintageNet.get(["proxy", "config"]) == :unset
    end
  end

  describe "resolve/1" do
    test "respects manual intent regardless of URL", %{config_property: prop} do
      manual = %{mode: :manual, scheme: :http, host: "p", port: 80}
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: manual})
      _ = VintageNetProxy.status()

      assert VintageNetProxy.resolve("https://api.example.com/") ==
               %{scheme: :http, host: "p", port: 80}

      assert VintageNetProxy.resolve("http://intranet/") ==
               %{scheme: :http, host: "p", port: 80}
    end

    test "returns :direct for :direct intent", %{config_property: prop} do
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: %{mode: :direct}})
      _ = VintageNetProxy.status()

      assert VintageNetProxy.resolve("https://x/") == :direct
    end

    test ":direct when no intent and no override" do
      assert VintageNetProxy.resolve("https://x/") == :direct
    end
  end

  describe "status/0" do
    test "reflects interface config intent", %{config_property: prop} do
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: %{mode: :direct}})
      _ = VintageNetProxy.status()

      status = VintageNetProxy.status()
      assert status.intent == %{mode: :direct}
      assert status.current == :direct
    end
  end

  describe "intent: :auto end-to-end (fetch + evaluate)" do
    test "explicit :pac_url is fetched, property goes :auto, resolve returns the descriptor",
         %{config_property: prop} do
      port = serve_once(~s|function FindProxyForURL(url, host) { return "PROXY p.corp:8080"; }|)

      PropertyTable.put(VintageNet, prop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad.dat"}
      })

      _ = VintageNetProxy.status()

      assert VintageNet.get(["proxy", "config"]) == :auto
      assert VintageNetProxy.status().pac_loaded? == true

      assert VintageNetProxy.resolve("https://api.example.com/") ==
               %{scheme: :http, host: "p.corp", port: 8080}
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

      PropertyTable.put(VintageNet, dprop, %{wpad: "http://127.0.0.1:#{port}/wpad.dat"})
      _ = VintageNetProxy.status()
      PropertyTable.put(VintageNet, cprop, %{type: :fake, proxy: %{mode: :auto}})
      _ = VintageNetProxy.status()

      assert VintageNet.get(["proxy", "config"]) == :auto

      assert VintageNetProxy.resolve("https://api.corp/") ==
               %{scheme: :http, host: "corp", port: 8080}
    end

    test "explicit :pac_url takes precedence over DHCP wpad",
         %{config_property: cprop, dhcp_property: dprop} do
      explicit_port =
        serve_once(~s|function FindProxyForURL(url, host) { return "PROXY explicit:1"; }|)

      {:ok, decoy_lsock} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      on_exit(fn -> :gen_tcp.close(decoy_lsock) end)
      {:ok, decoy_port} = :inet.port(decoy_lsock)

      PropertyTable.put(VintageNet, dprop, %{wpad: "http://127.0.0.1:#{decoy_port}/wpad.dat"})
      _ = VintageNetProxy.status()

      PropertyTable.put(VintageNet, cprop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{explicit_port}/wpad.dat"}
      })

      _ = VintageNetProxy.status()

      assert VintageNet.get(["proxy", "config"]) == :auto

      assert VintageNetProxy.resolve("https://anything/") ==
               %{scheme: :http, host: "explicit", port: 1}
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

      PropertyTable.put(VintageNet, prop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad.dat"}
      })

      _ = VintageNetProxy.status()

      # PAC is loaded → property goes :auto. Per-URL routing via resolve/1.
      assert VintageNet.get(["proxy", "config"]) == :auto

      assert VintageNetProxy.resolve("https://api.corp.example.com/") == :direct
      assert VintageNetProxy.resolve("http://intranet/") == :direct

      assert VintageNetProxy.resolve("https://www.google.com/") ==
               %{scheme: :http, host: "primary-proxy", port: 8080}

      assert VintageNetProxy.resolve("https://my-bucket.s3.amazonaws.com/") == :direct
    end

    test "resolve/1 evaluates the PAC against the supplied URL",
         %{config_property: prop} do
      pac = """
      function FindProxyForURL(url, host) {
        if (shExpMatch(host, "*.corp.example")) return "PROXY corp:8080";
        return "DIRECT";
      }
      """

      port = serve_once(pac)

      PropertyTable.put(VintageNet, prop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad.dat"}
      })

      _ = VintageNetProxy.status()

      assert VintageNetProxy.resolve("http://google.com/") == :direct

      assert VintageNetProxy.resolve("https://x.corp.example/") ==
               %{scheme: :http, host: "corp", port: 8080}
    end

    test "connection rising to :internet triggers fetch and flips property to :auto",
         %{config_property: cprop, connection_property: connprop} do
      # Start the test with the interface marked offline so the initial
      # refresh skips the fetch.
      PropertyTable.put(VintageNet, connprop, :disconnected)
      _ = VintageNetProxy.status()

      port =
        serve_once(~s|function FindProxyForURL(url, host) { return "PROXY p.corp:8080"; }|)

      PropertyTable.put(VintageNet, cprop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad.dat"}
      })

      _ = VintageNetProxy.status()
      assert VintageNet.get(["proxy", "config"]) == :unset

      PropertyTable.put(VintageNet, connprop, :internet)
      _ = VintageNetProxy.status()

      assert VintageNet.get(["proxy", "config"]) == :auto

      assert VintageNetProxy.resolve("https://api.example.com/") ==
               %{scheme: :http, host: "p.corp", port: 8080}
    end
  end

  describe "multi-interface priority selection" do
    setup do
      stop_supervised!(VintageNetProxy.Supervisor)

      primary = "p#{:erlang.unique_integer([:positive])}"
      secondary = "s#{:erlang.unique_integer([:positive])}"

      PropertyTable.put(VintageNet, ["interface", primary, "connection"], :internet)
      PropertyTable.put(VintageNet, ["interface", secondary, "connection"], :internet)

      start_supervised!(
        {VintageNetProxy.Supervisor, interfaces: [primary, secondary]}
      )

      on_exit(fn ->
        for iface <- [primary, secondary],
            prop <- ["config", "dhcp_options", "connection"] do
          PropertyTable.delete(VintageNet, ["interface", iface, prop])
        end

        PropertyTable.delete(VintageNet, ["proxy", "config"])
      end)

      {:ok, primary: primary, secondary: secondary}
    end

    test "first interface in the list with intent + up connection wins",
         %{primary: primary, secondary: secondary} do
      PropertyTable.put(VintageNet, ["interface", secondary, "config"], %{
        type: :fake,
        proxy: %{mode: :direct}
      })

      _ = VintageNetProxy.status()
      assert VintageNetProxy.status().active_iface == secondary
      assert VintageNet.get(["proxy", "config"]) == :direct

      PropertyTable.put(VintageNet, ["interface", primary, "config"], %{
        type: :fake,
        proxy: %{mode: :manual, host: "p", port: 80}
      })

      _ = VintageNetProxy.status()
      assert VintageNetProxy.status().active_iface == primary
      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "p", port: 80}
    end

    test "falls back when the active interface drops; reclaims on reconnect",
         %{primary: primary, secondary: secondary} do
      PropertyTable.put(VintageNet, ["interface", primary, "config"], %{
        type: :fake,
        proxy: %{mode: :manual, scheme: :http, host: "p1", port: 80}
      })

      PropertyTable.put(VintageNet, ["interface", secondary, "config"], %{
        type: :fake,
        proxy: %{mode: :manual, scheme: :http, host: "s1", port: 80}
      })

      _ = VintageNetProxy.status()
      assert VintageNetProxy.status().active_iface == primary
      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "p1", port: 80}

      PropertyTable.put(VintageNet, ["interface", primary, "connection"], :disconnected)
      _ = VintageNetProxy.status()
      assert VintageNetProxy.status().active_iface == secondary
      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "s1", port: 80}

      PropertyTable.put(VintageNet, ["interface", primary, "connection"], :internet)
      _ = VintageNetProxy.status()
      assert VintageNetProxy.status().active_iface == primary
      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "p1", port: 80}
    end

    test "drops cached PAC when an interface disconnects",
         %{primary: primary} do
      port = serve_once(~s|function FindProxyForURL(url, host) { return "PROXY p:1"; }|)

      PropertyTable.put(VintageNet, ["interface", primary, "config"], %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad.dat"}
      })

      _ = VintageNetProxy.status()
      assert VintageNetProxy.status().by_interface[primary].pac_loaded? == true

      PropertyTable.put(VintageNet, ["interface", primary, "connection"], :disconnected)
      _ = VintageNetProxy.status()
      assert VintageNetProxy.status().by_interface[primary].pac_loaded? == false
    end

    test "interfaces not in the configured list are ignored",
         %{primary: primary} do
      uninvited = "u#{:erlang.unique_integer([:positive])}"

      PropertyTable.put(VintageNet, ["interface", uninvited, "connection"], :internet)

      PropertyTable.put(VintageNet, ["interface", uninvited, "config"], %{
        type: :fake,
        proxy: %{mode: :manual, host: "ghost", port: 80}
      })

      _ = VintageNetProxy.status()
      assert VintageNetProxy.status().active_iface == nil
      assert VintageNet.get(["proxy", "config"]) == :unset

      PropertyTable.put(VintageNet, ["interface", primary, "config"], %{
        type: :fake,
        proxy: %{mode: :direct}
      })

      _ = VintageNetProxy.status()
      assert VintageNetProxy.status().active_iface == primary
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
