defmodule VintageNetProxy.RosterTest do
  use ExUnit.Case, async: true

  alias VintageNetProxy.{Interface, Roster}

  defp iface(opts) do
    %Interface{
      iface: Keyword.fetch!(opts, :iface),
      intent: Keyword.get(opts, :intent),
      connection: Keyword.get(opts, :connection, :disconnected),
      pac_script: Keyword.get(opts, :pac_script),
      dhcp_wpad_url: Keyword.get(opts, :dhcp_wpad_url)
    }
  end

  defp state(iface_states) do
    interfaces = Enum.map(iface_states, & &1.iface)
    Roster.new(interfaces, Map.new(iface_states, &{&1.iface, &1}))
  end

  describe "value/1" do
    test "no interfaces → :unset" do
      assert Roster.value(Roster.new([], %{})) == :unset
    end

    test "intent: nil → :unset (not eligible)" do
      s = state([iface(iface: "eth0", intent: nil, connection: :internet)])
      assert Roster.value(s) == :unset
    end

    test "connection: :disconnected → :unset (not eligible)" do
      s = state([iface(iface: "eth0", intent: %{mode: :direct}, connection: :disconnected)])
      assert Roster.value(s) == :unset
    end

    test "eligible :direct → :direct" do
      s = state([iface(iface: "eth0", intent: %{mode: :direct}, connection: :internet)])
      assert Roster.value(s) == :direct
    end

    test "eligible :manual → descriptor" do
      intent = %{mode: :manual, scheme: :http, host: "p.example", port: 8080}
      s = state([iface(iface: "eth0", intent: intent, connection: :lan)])
      assert Roster.value(s) == %{scheme: :http, host: "p.example", port: 8080}
    end

    test "eligible :auto with pac_script → :auto" do
      s =
        state([
          iface(
            iface: "eth0",
            intent: %{mode: :auto},
            connection: :internet,
            pac_script: "function FindProxyForURL(){ return \"DIRECT\"; }"
          )
        ])

      assert Roster.value(s) == :auto
    end

    test "eligible :auto without pac_script → :unset" do
      s = state([iface(iface: "eth0", intent: %{mode: :auto}, connection: :internet)])
      assert Roster.value(s) == :unset
    end
  end

  describe "value/1 — priority" do
    test "first eligible interface wins" do
      s =
        state([
          iface(iface: "eth0", intent: %{mode: :direct}, connection: :internet),
          iface(
            iface: "wlan0",
            intent: %{mode: :manual, scheme: :http, host: "x", port: 1},
            connection: :internet
          )
        ])

      assert Roster.value(s) == :direct
    end

    test "ineligible primary falls through to secondary" do
      s =
        state([
          iface(iface: "eth0", intent: nil, connection: :internet),
          iface(iface: "wlan0", intent: %{mode: :direct}, connection: :internet)
        ])

      assert Roster.value(s) == :direct
    end

    test "priority follows the configured list, not map key order" do
      s =
        state([
          iface(iface: "wlan0", intent: %{mode: :direct}, connection: :internet),
          iface(
            iface: "eth0",
            intent: %{mode: :manual, scheme: :http, host: "x", port: 1},
            connection: :internet
          )
        ])

      assert Roster.value(s) == :direct
    end
  end

  describe "resolve/2" do
    test "no active interface → :direct" do
      assert Roster.resolve(Roster.new([], %{}), "https://example.com/") == :direct
    end

    test "active :direct → :direct" do
      s = state([iface(iface: "eth0", intent: %{mode: :direct}, connection: :internet)])
      assert Roster.resolve(s, "https://example.com/") == :direct
    end

    test "active :manual → descriptor" do
      intent = %{mode: :manual, scheme: :http, host: "p", port: 8080}
      s = state([iface(iface: "eth0", intent: intent, connection: :internet)])
      assert Roster.resolve(s, "https://example.com/") == %{scheme: :http, host: "p", port: 8080}
    end

    test "active :auto evaluates PAC" do
      script = ~s|function FindProxyForURL(url, host) { return "PROXY p.corp:8080"; }|

      s =
        state([
          iface(
            iface: "eth0",
            intent: %{mode: :auto},
            connection: :internet,
            pac_script: script
          )
        ])

      assert Roster.resolve(s, "https://x.example/") ==
               %{scheme: :http, host: "p.corp", port: 8080}
    end
  end

  describe "status/2" do
    test "active_iface is nil when no interface is eligible" do
      s = state([iface(iface: "eth0", intent: nil, connection: :internet)])
      assert Roster.status(s, :unset).active_iface == nil
    end

    test "active_iface is the first eligible interface" do
      s =
        state([
          iface(iface: "eth0", intent: nil, connection: :internet),
          iface(iface: "wlan0", intent: %{mode: :direct}, connection: :internet)
        ])

      assert Roster.status(s, :direct).active_iface == "wlan0"
    end

    test "by_interface contains an entry for every configured interface" do
      s =
        state([
          iface(iface: "eth0", intent: nil, connection: :disconnected),
          iface(iface: "wlan0", intent: %{mode: :direct}, connection: :internet)
        ])

      status = Roster.status(s, :direct)
      assert Map.keys(status.by_interface) |> Enum.sort() == ["eth0", "wlan0"]
      assert status.by_interface["eth0"].intent == nil
      assert status.by_interface["wlan0"].intent == %{mode: :direct}
    end

    test "current passes through unchanged" do
      s = state([iface(iface: "eth0", intent: %{mode: :direct}, connection: :internet)])
      assert Roster.status(s, :anything).current == :anything
    end
  end

  describe "put_iface/3" do
    test "stores a fresh snapshot for an interface in the priority list" do
      s = Roster.new(["eth0"], %{})
      snap = iface(iface: "eth0", intent: %{mode: :direct}, connection: :internet)
      s = Roster.put_iface(s, "eth0", snap)
      assert Map.get(s.states, "eth0") == snap
      assert Roster.value(s) == :direct
    end

    test "replaces an existing snapshot" do
      old = iface(iface: "eth0", intent: %{mode: :direct}, connection: :internet)
      s = state([old])
      new = iface(iface: "eth0", intent: nil, connection: :internet)
      s = Roster.put_iface(s, "eth0", new)
      assert Map.get(s.states, "eth0") == new
      assert Roster.value(s) == :unset
    end

    test "no-op for an interface not in the priority list" do
      s = state([iface(iface: "eth0", intent: %{mode: :direct}, connection: :internet)])
      ghost = iface(iface: "wlan0", intent: %{mode: :direct}, connection: :internet)
      s = Roster.put_iface(s, "wlan0", ghost)
      refute Map.has_key?(s.states, "wlan0")
    end
  end

  describe "update_iface/3" do
    test "applies fun to the named interface's state" do
      eth0 = iface(iface: "eth0", intent: nil, connection: :internet)
      s = state([eth0])

      s = Roster.update_iface(s, "eth0", fn st -> %{st | intent: %{mode: :direct}} end)

      assert Roster.value(s) == :direct
    end

    test "no-op for an interface not in the priority list" do
      eth0 = iface(iface: "eth0", intent: %{mode: :direct}, connection: :internet)
      s = state([eth0])

      s = Roster.update_iface(s, "wlan0", fn st -> %{st | intent: nil} end)

      assert Roster.value(s) == :direct
      assert Map.keys(s.states) == ["eth0"]
    end
  end
end
