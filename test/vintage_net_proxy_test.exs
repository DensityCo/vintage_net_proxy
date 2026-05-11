defmodule VintageNetProxyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VintageNetProxy.Interface

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

  # `Interface.get/1` flushes the Interface's mailbox (including any blocking
  # PAC fetch); `VintageNetProxy.status/0` flushes the Selector's mailbox.
  defp flush(iface) do
    _ = Interface.get(iface)
    _ = VintageNetProxy.status()
    :ok
  end

  describe "initial state" do
    test "publishes :unset when nothing is configured" do
      assert VintageNet.get(["proxy", "config"]) == :unset
    end

    test "status reports a clean default", %{iface: iface} do
      status = VintageNetProxy.status()
      assert status.interfaces == [iface]
      assert status.active_iface == nil
      assert status.current == :unset
      assert status.by_interface[iface].intent == nil
      assert status.by_interface[iface].dhcp_wpad_url == nil
      assert status.by_interface[iface].pac_loaded? == false
    end
  end

  describe "intent: :direct from interface config" do
    test "publishes :direct when interface config carries proxy: %{mode: :direct}",
         %{config_property: prop, iface: iface} do
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: %{mode: :direct}})
      flush(iface)
      assert VintageNet.get(["proxy", "config"]) == :direct
    end

    test "publishes :unset when proxy field is removed",
         %{config_property: prop, iface: iface} do
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: %{mode: :direct}})
      flush(iface)
      assert VintageNet.get(["proxy", "config"]) == :direct

      PropertyTable.put(VintageNet, prop, %{type: :fake})
      flush(iface)
      assert VintageNet.get(["proxy", "config"]) == :unset
    end
  end

  describe "intent: :manual from interface config" do
    test "publishes the resolved descriptor", %{config_property: prop, iface: iface} do
      manual = %{mode: :manual, scheme: :http, host: "p.corp", port: 8080}
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: manual})
      flush(iface)

      assert VintageNet.get(["proxy", "config"]) == %{
               scheme: :http,
               host: "p.corp",
               port: 8080
             }
    end

    test "preserves credentials in the published descriptor",
         %{config_property: prop, iface: iface} do
      manual = %{
        mode: :manual,
        scheme: :socks5,
        host: "s.corp",
        port: 1080,
        username: "alice",
        password: "secret"
      }

      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: manual})
      flush(iface)

      assert VintageNet.get(["proxy", "config"]) == %{
               scheme: :socks5,
               host: "s.corp",
               port: 1080,
               username: "alice",
               password: "secret"
             }
    end

    test "defaults scheme to :http when omitted", %{config_property: prop, iface: iface} do
      PropertyTable.put(VintageNet, prop, %{
        type: :fake,
        proxy: %{mode: :manual, host: "p", port: 80}
      })

      flush(iface)
      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "p", port: 80}
    end
  end

  describe "intent: :auto with DHCP-discovered WPAD URL" do
    test "records DHCP wpad URL in status", %{dhcp_property: prop, iface: iface} do
      PropertyTable.put(VintageNet, prop, %{wpad: "http://wpad.test/wpad.dat"})
      flush(iface)
      assert VintageNetProxy.status().by_interface[iface].dhcp_wpad_url ==
               "http://wpad.test/wpad.dat"
    end

    test "clears DHCP wpad URL when the dhcp_options property is deleted",
         %{dhcp_property: prop, iface: iface} do
      PropertyTable.put(VintageNet, prop, %{wpad: "http://wpad.test/wpad.dat"})
      flush(iface)

      assert VintageNetProxy.status().by_interface[iface].dhcp_wpad_url ==
               "http://wpad.test/wpad.dat"

      PropertyTable.delete(VintageNet, prop)
      flush(iface)
      assert VintageNetProxy.status().by_interface[iface].dhcp_wpad_url == nil
    end
  end

  describe "invalid proxy config in interface config" do
    test "logs a warning and leaves intent nil",
         %{config_property: prop, iface: iface} do
      log =
        capture_log(fn ->
          PropertyTable.put(VintageNet, prop, %{
            type: :fake,
            proxy: %{mode: :manual, host: "p"}
          })

          flush(iface)
        end)

      assert log =~ "invalid :proxy config"
      assert VintageNet.get(["proxy", "config"]) == :unset
    end
  end

  describe "resolve/1" do
    test ":direct when no interface is eligible" do
      assert VintageNetProxy.resolve("https://example.com/") == :direct
    end

    test "respects manual intent regardless of URL",
         %{config_property: prop, iface: iface} do
      manual = %{mode: :manual, scheme: :http, host: "p", port: 80}
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: manual})
      flush(iface)

      assert VintageNetProxy.resolve("https://api.example.com/") ==
               %{scheme: :http, host: "p", port: 80}

      assert VintageNetProxy.resolve("http://intranet/") ==
               %{scheme: :http, host: "p", port: 80}
    end

    test "returns :direct for :direct intent",
         %{config_property: prop, iface: iface} do
      PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: %{mode: :direct}})
      flush(iface)

      assert VintageNetProxy.resolve("https://x/") == :direct
    end
  end

  describe "intent: :auto end-to-end (fetch + evaluate)" do
    test "explicit :pac_url is fetched, property goes :auto, resolve returns the descriptor",
         %{config_property: prop, iface: iface} do
      port = serve_once(~s|function FindProxyForURL(url, host) { return "PROXY p.corp:8080"; }|)

      PropertyTable.put(VintageNet, prop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad.dat"}
      })

      flush(iface)

      assert VintageNet.get(["proxy", "config"]) == :auto
      assert VintageNetProxy.status().by_interface[iface].pac_loaded? == true

      assert VintageNetProxy.resolve("https://api.example.com/") ==
               %{scheme: :http, host: "p.corp", port: 8080}
    end

    test "DHCP-discovered WPAD URL is fetched when intent has no explicit pac_url",
         %{config_property: cprop, dhcp_property: dprop, iface: iface} do
      pac = """
      function FindProxyForURL(url, host) {
        if (shExpMatch(host, "*.corp")) return "PROXY corp:8080";
        return "DIRECT";
      }
      """

      port = serve_once(pac)

      PropertyTable.put(VintageNet, dprop, %{wpad: "http://127.0.0.1:#{port}/wpad.dat"})
      PropertyTable.put(VintageNet, cprop, %{type: :fake, proxy: %{mode: :auto}})

      flush(iface)

      assert VintageNet.get(["proxy", "config"]) == :auto

      assert VintageNetProxy.resolve("https://api.corp/") ==
               %{scheme: :http, host: "corp", port: 8080}
    end

    test "explicit :pac_url takes precedence over DHCP wpad",
         %{config_property: cprop, dhcp_property: dprop, iface: iface} do
      explicit_port =
        serve_once(~s|function FindProxyForURL(url, host) { return "PROXY explicit:1"; }|)

      {:ok, decoy_lsock} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      on_exit(fn -> :gen_tcp.close(decoy_lsock) end)
      {:ok, decoy_port} = :inet.port(decoy_lsock)

      PropertyTable.put(VintageNet, dprop, %{wpad: "http://127.0.0.1:#{decoy_port}/wpad.dat"})

      PropertyTable.put(VintageNet, cprop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{explicit_port}/wpad.dat"}
      })

      flush(iface)

      assert VintageNet.get(["proxy", "config"]) == :auto

      assert VintageNetProxy.resolve("https://anything/") ==
               %{scheme: :http, host: "explicit", port: 1}
    end

    test "end-to-end with a representative enterprise WPAD",
         %{config_property: prop, iface: iface} do
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

      flush(iface)

      assert VintageNet.get(["proxy", "config"]) == :auto

      assert VintageNetProxy.resolve("https://api.corp.example.com/") == :direct
      assert VintageNetProxy.resolve("http://intranet/") == :direct

      assert VintageNetProxy.resolve("https://www.google.com/") ==
               %{scheme: :http, host: "primary-proxy", port: 8080}

      assert VintageNetProxy.resolve("https://my-bucket.s3.amazonaws.com/") == :direct
    end

    test "connection going down clears the cached PAC",
         %{config_property: cprop, connection_property: connprop, iface: iface} do
      port = serve_once(~s|function FindProxyForURL(url, host) { return "DIRECT"; }|)

      PropertyTable.put(VintageNet, cprop, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad.dat"}
      })

      flush(iface)
      assert VintageNetProxy.status().by_interface[iface].pac_loaded? == true

      PropertyTable.put(VintageNet, connprop, :disconnected)
      flush(iface)
      assert VintageNetProxy.status().by_interface[iface].pac_loaded? == false
    end
  end

  describe "multi-interface priority selection" do
    setup do
      stop_supervised!(VintageNetProxy.Supervisor)

      primary = "p#{:erlang.unique_integer([:positive])}"
      secondary = "s#{:erlang.unique_integer([:positive])}"

      PropertyTable.put(VintageNet, ["interface", primary, "connection"], :internet)
      PropertyTable.put(VintageNet, ["interface", secondary, "connection"], :internet)

      start_supervised!({VintageNetProxy.Supervisor, interfaces: [primary, secondary]})

      on_exit(fn ->
        for iface <- [primary, secondary],
            prop <- ["config", "dhcp_options", "connection"] do
          PropertyTable.delete(VintageNet, ["interface", iface, prop])
        end

        PropertyTable.delete(VintageNet, ["proxy", "config"])
      end)

      {:ok, primary: primary, secondary: secondary}
    end

    defp flush_two(primary, secondary) do
      _ = Interface.get(primary)
      _ = Interface.get(secondary)
      _ = VintageNetProxy.status()
      :ok
    end

    test "first interface in the list with intent + up connection wins",
         %{primary: primary, secondary: secondary} do
      PropertyTable.put(VintageNet, ["interface", secondary, "config"], %{
        type: :fake,
        proxy: %{mode: :direct}
      })

      flush_two(primary, secondary)
      assert VintageNetProxy.status().active_iface == secondary
      assert VintageNet.get(["proxy", "config"]) == :direct

      PropertyTable.put(VintageNet, ["interface", primary, "config"], %{
        type: :fake,
        proxy: %{mode: :manual, host: "p", port: 80}
      })

      flush_two(primary, secondary)
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

      flush_two(primary, secondary)
      assert VintageNetProxy.status().active_iface == primary
      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "p1", port: 80}

      PropertyTable.put(VintageNet, ["interface", primary, "connection"], :disconnected)
      flush_two(primary, secondary)
      assert VintageNetProxy.status().active_iface == secondary
      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "s1", port: 80}

      PropertyTable.put(VintageNet, ["interface", primary, "connection"], :internet)
      flush_two(primary, secondary)
      assert VintageNetProxy.status().active_iface == primary
      assert VintageNet.get(["proxy", "config"]) == %{scheme: :http, host: "p1", port: 80}
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

      _ = Interface.get(primary)
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
