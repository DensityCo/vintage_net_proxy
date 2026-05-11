defmodule VintageNetProxy.ServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias VintageNetProxy.Server

  setup do
    iface = "test#{:erlang.unique_integer([:positive])}"
    config_property = ["interface", iface, "config"]
    dhcp_property = ["interface", iface, "dhcp_options"]

    pid = start_supervised!({Server, [interface: iface]})

    on_exit(fn ->
      PropertyTable.delete(VintageNet, config_property)
      PropertyTable.delete(VintageNet, dhcp_property)
      PropertyTable.delete(VintageNet, ["proxy", "config"])
    end)

    {:ok, iface: iface, pid: pid, config_property: config_property, dhcp_property: dhcp_property}
  end

  describe "initial state" do
    test "publishes :unset when nothing is configured" do
      assert VintageNet.get(["proxy", "config"]) == :unset
    end

    test "status reports a clean default", %{iface: iface} do
      status = Server.status()
      assert status.iface == iface
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

    test "records DHCP wpad URL in status", %{dhcp_property: prop} do
      PropertyTable.put(VintageNet, prop, %{wpad: "http://wpad.test/wpad.dat"})
      status = Server.status()
      assert status.dhcp_wpad_url == "http://wpad.test/wpad.dat"
    end

    test "clears DHCP wpad URL when the dhcp_options property is cleared",
         %{dhcp_property: prop} do
      PropertyTable.put(VintageNet, prop, %{wpad: "http://wpad.test/wpad.dat"})
      _ = Server.status()
      assert Server.status().dhcp_wpad_url == "http://wpad.test/wpad.dat"

      PropertyTable.delete(VintageNet, prop)
      _ = Server.status()
      assert Server.status().dhcp_wpad_url == nil
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
end
