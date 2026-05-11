defmodule VintageNetProxy.InterfaceTest do
  use ExUnit.Case, async: true

  alias VintageNetProxy.Interface

  defp iface(opts) do
    %Interface{
      iface: Keyword.get(opts, :iface, "eth0"),
      intent: Keyword.get(opts, :intent),
      connection: Keyword.get(opts, :connection, :disconnected),
      pac_script: Keyword.get(opts, :pac_script),
      dhcp_wpad_url: Keyword.get(opts, :dhcp_wpad_url)
    }
  end

  describe "eligible?/1" do
    test "intent nil → false" do
      refute Interface.eligible?(iface(intent: nil, connection: :internet))
    end

    test "connection :disconnected → false" do
      refute Interface.eligible?(iface(intent: %{mode: :direct}, connection: :disconnected))
    end

    test "intent + connection :internet → true" do
      assert Interface.eligible?(iface(intent: %{mode: :direct}, connection: :internet))
    end

    test "intent + connection :lan → true" do
      assert Interface.eligible?(iface(intent: %{mode: :direct}, connection: :lan))
    end
  end

  describe "value/1" do
    test "intent nil → :unset" do
      assert Interface.value(iface(intent: nil)) == :unset
    end

    test ":direct → :direct" do
      assert Interface.value(iface(intent: %{mode: :direct})) == :direct
    end

    test ":manual → descriptor" do
      intent = %{mode: :manual, scheme: :http, host: "p", port: 8080}
      assert Interface.value(iface(intent: intent)) == %{scheme: :http, host: "p", port: 8080}
    end

    test ":auto with pac_script → :auto" do
      assert Interface.value(iface(intent: %{mode: :auto}, pac_script: "FN")) == :auto
    end

    test ":auto without pac_script → :unset" do
      assert Interface.value(iface(intent: %{mode: :auto})) == :unset
    end
  end

  describe "resolve/2" do
    test "intent nil → :direct" do
      assert Interface.resolve(iface(intent: nil), "https://x/") == :direct
    end

    test ":direct → :direct" do
      assert Interface.resolve(iface(intent: %{mode: :direct}), "https://x/") == :direct
    end

    test ":manual → descriptor" do
      intent = %{mode: :manual, scheme: :http, host: "p", port: 8080}

      assert Interface.resolve(iface(intent: intent), "https://x/") ==
               %{scheme: :http, host: "p", port: 8080}
    end

    test ":auto with pac_script delegates to PAC evaluator" do
      script = ~s|function FindProxyForURL(url, host) { return "PROXY p.corp:8080"; }|

      assert Interface.resolve(iface(intent: %{mode: :auto}, pac_script: script), "https://x/") ==
               %{scheme: :http, host: "p.corp", port: 8080}
    end

    test ":auto without pac_script → :direct (degraded)" do
      assert Interface.resolve(iface(intent: %{mode: :auto}), "https://x/") == :direct
    end
  end

  describe "on_config/2" do
    test "stores a valid :direct intent" do
      s = Interface.on_config(iface([]), %{type: :fake, proxy: %{mode: :direct}})
      assert s.intent == %{mode: :direct}
    end

    test "normalizes a :manual intent (fills in default scheme)" do
      s = Interface.on_config(iface([]), %{proxy: %{mode: :manual, host: "p", port: 80}})
      assert s.intent == %{mode: :manual, scheme: :http, host: "p", port: 80}
    end

    test "invalid :proxy config logs and nullifies intent" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          s = Interface.on_config(iface([]), %{proxy: %{mode: :manual, host: "p"}})
          send(self(), {:result, s})
        end)

      assert log =~ "invalid :proxy config"
      assert_received {:result, %{intent: nil}}
    end

    test "missing :proxy field clears any prior intent" do
      s = Interface.on_config(iface(intent: %{mode: :direct}), %{type: :fake})
      assert s.intent == nil
    end

    test "switching from :auto (with cached script) to :direct clears pac_script" do
      # :direct has no effective_pac_url, so refresh_pac drops the cached script.
      s =
        iface(intent: %{mode: :auto}, pac_script: "FN", connection: :internet)
        |> Interface.on_config(%{proxy: %{mode: :direct}})

      assert s.pac_script == nil
    end
  end

  describe "on_dhcp_options/2" do
    test "stores the wpad URL" do
      s = Interface.on_dhcp_options(iface([]), %{wpad: "http://wpad.test/"})
      assert s.dhcp_wpad_url == "http://wpad.test/"
    end

    test "missing :wpad key clears the cached URL" do
      s = Interface.on_dhcp_options(iface(dhcp_wpad_url: "http://wpad.test/"), %{other: "x"})
      assert s.dhcp_wpad_url == nil
    end

    test "empty wpad URL is treated as cleared" do
      s = Interface.on_dhcp_options(iface([]), %{wpad: ""})
      assert s.dhcp_wpad_url == nil
    end
  end

  describe "on_connection/2" do
    test "going down clears any cached pac_script" do
      s =
        iface(intent: %{mode: :auto}, pac_script: "FN", connection: :internet)
        |> Interface.on_connection(:disconnected)

      assert s.pac_script == nil
      assert s.connection == :disconnected
    end

    test "transitioning between :internet and :lan stays eligible" do
      s =
        iface(intent: %{mode: :direct}, connection: :internet)
        |> Interface.on_connection(:lan)

      assert s.connection == :lan
      assert Interface.eligible?(s)
    end

    test "going up with a non-fetching intent (:direct) leaves pac_script nil" do
      s =
        iface(intent: %{mode: :direct}, connection: :disconnected)
        |> Interface.on_connection(:internet)

      assert s.connection == :internet
      assert s.pac_script == nil
    end
  end

  describe "load/1" do
    test "reads connection, intent, and dhcp wpad from the PropertyTable" do
      iface = "load_test_#{:erlang.unique_integer([:positive])}"

      PropertyTable.put(VintageNet, ["interface", iface, "connection"], :internet)

      PropertyTable.put(
        VintageNet,
        ["interface", iface, "config"],
        %{type: :fake, proxy: %{mode: :direct}}
      )

      PropertyTable.put(VintageNet, ["interface", iface, "dhcp_options"], %{wpad: "http://wpad/"})

      state = Interface.load(iface)

      assert state.iface == iface
      assert state.connection == :internet
      assert state.intent == %{mode: :direct}
      assert state.dhcp_wpad_url == "http://wpad/"
    end

    test "missing properties yield nil fields" do
      iface = "load_empty_#{:erlang.unique_integer([:positive])}"
      state = Interface.load(iface)

      assert state.iface == iface
      assert state.connection == nil
      assert state.intent == nil
      assert state.dhcp_wpad_url == nil
      assert state.pac_script == nil
    end
  end

  describe "snapshot/1" do
    test "exposes the documented fields" do
      snap =
        iface(
          iface: "eth0",
          intent: %{mode: :direct},
          connection: :internet,
          dhcp_wpad_url: "http://wpad/",
          pac_script: "FN"
        )
        |> Interface.snapshot()

      assert snap.iface == "eth0"
      assert snap.eligible? == true
      assert snap.value == :direct
      assert snap.intent == %{mode: :direct}
      assert snap.connection == :internet
      assert snap.dhcp_wpad_url == "http://wpad/"
      assert snap.pac_loaded? == true
    end

    test "pac_url falls back to dhcp_wpad_url for :auto intent without explicit pac_url" do
      snap =
        iface(intent: %{mode: :auto}, dhcp_wpad_url: "http://wpad.test/")
        |> Interface.snapshot()

      assert snap.pac_url == "http://wpad.test/"
    end

    test "pac_url is nil when intent isn't :auto" do
      snap =
        iface(intent: %{mode: :direct}, dhcp_wpad_url: "http://wpad.test/")
        |> Interface.snapshot()

      assert snap.pac_url == nil
    end
  end
end
