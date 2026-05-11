defmodule VintageNetProxy.SelectorTest do
  @moduledoc """
  Tests the Selector as a pure aggregator: it accepts snapshots via
  `{:interface_changed, iface, state}` messages and publishes the chosen
  proxy value. PropertyTable subscriptions live on the Interface
  GenServers; end-to-end coverage is in `VintageNetProxyTest`.
  """
  use ExUnit.Case, async: false

  alias VintageNetProxy.{Interface, Publisher, Selector}

  setup do
    uniq = :erlang.unique_integer([:positive])
    primary = "primary#{uniq}"
    secondary = "secondary#{uniq}"

    start_supervised!({Selector, interfaces: [primary, secondary]})

    on_exit(fn -> PropertyTable.delete(VintageNet, ["proxy", "config"]) end)

    {:ok, primary: primary, secondary: secondary}
  end

  defp send_snapshot(iface, opts) do
    snap = %Interface{
      iface: iface,
      intent: Keyword.get(opts, :intent),
      connection: Keyword.get(opts, :connection),
      pac_script: Keyword.get(opts, :pac_script),
      dhcp_wpad_url: Keyword.get(opts, :dhcp_wpad_url)
    }

    send(Selector, {:interface_changed, iface, snap})
    _ = Selector.status()
    :ok
  end

  describe "initial state" do
    test "publishes :unset when no snapshots have arrived" do
      assert Publisher.get() == :unset
    end
  end

  describe "single-interface publication" do
    test "publishes :direct for an eligible :direct snapshot", %{primary: iface} do
      send_snapshot(iface, intent: %{mode: :direct}, connection: :internet)
      assert Publisher.get() == :direct
    end

    test "publishes :unset for an ineligible (disconnected) snapshot", %{primary: iface} do
      send_snapshot(iface, intent: %{mode: :direct}, connection: :disconnected)
      assert Publisher.get() == :unset
    end

    test "publishes the descriptor for an eligible :manual snapshot", %{primary: iface} do
      manual = %{mode: :manual, scheme: :http, host: "p.corp", port: 8080}
      send_snapshot(iface, intent: manual, connection: :internet)
      assert Publisher.get() == %{scheme: :http, host: "p.corp", port: 8080}
    end

    test "publishes :auto when :auto snapshot includes a pac_script", %{primary: iface} do
      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet, pac_script: "FN")
      assert Publisher.get() == :auto
    end

    test "publishes :unset when :auto snapshot has no pac_script yet", %{primary: iface} do
      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet)
      assert Publisher.get() == :unset
    end
  end

  describe "multi-interface priority" do
    test "first eligible interface in the list wins", %{primary: p, secondary: s} do
      send_snapshot(p, intent: %{mode: :direct}, connection: :internet)

      manual = %{mode: :manual, scheme: :http, host: "q.corp", port: 8080}
      send_snapshot(s, intent: manual, connection: :internet)

      assert Publisher.get() == :direct
    end

    test "falls through to secondary when primary is ineligible",
         %{primary: p, secondary: s} do
      send_snapshot(p, intent: nil, connection: :internet)
      send_snapshot(s, intent: %{mode: :direct}, connection: :internet)
      assert Publisher.get() == :direct
    end

    test "active interface flips when the primary goes down",
         %{primary: p, secondary: s} do
      send_snapshot(p, intent: %{mode: :direct}, connection: :internet)
      send_snapshot(s, intent: %{mode: :direct}, connection: :internet)
      assert Selector.status().active_iface == p

      send_snapshot(p, intent: %{mode: :direct}, connection: :disconnected)
      assert Selector.status().active_iface == s
    end
  end

  describe "snapshots for unconfigured interfaces are ignored" do
    test "no-op for an iface not in the priority list" do
      ghost = "ghost#{:erlang.unique_integer([:positive])}"
      send_snapshot(ghost, intent: %{mode: :direct}, connection: :internet)
      assert Publisher.get() == :unset
    end
  end

  describe "resolve/1" do
    test ":direct when no interface is eligible" do
      assert Selector.resolve("https://x/") == :direct
    end

    test ":manual returns the descriptor regardless of URL", %{primary: iface} do
      manual = %{mode: :manual, scheme: :http, host: "p", port: 80}
      send_snapshot(iface, intent: manual, connection: :internet)
      assert Selector.resolve("https://anything/") == %{scheme: :http, host: "p", port: 80}
    end

    test ":auto evaluates the PAC against the supplied URL", %{primary: iface} do
      script = ~s|function FindProxyForURL(url, host) { return "PROXY p.corp:8080"; }|
      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet, pac_script: script)

      assert Selector.resolve("https://x/") ==
               %{scheme: :http, host: "p.corp", port: 8080}
    end
  end

  describe "status/0" do
    test "reflects active interface and per-interface state",
         %{primary: p, secondary: s} do
      send_snapshot(p, intent: %{mode: :direct}, connection: :internet)

      status = Selector.status()
      assert status.interfaces == [p, s]
      assert status.active_iface == p
      assert status.current == :direct
      assert status.by_interface[p].intent == %{mode: :direct}
      assert status.by_interface[s].intent == nil
    end
  end

  describe "unknown messages" do
    test "are ignored without crashing the Selector" do
      send(Selector, :garbage)
      assert is_map(Selector.status())
    end
  end
end
