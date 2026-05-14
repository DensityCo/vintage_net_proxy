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

    on_exit(fn ->
      PropertyTable.delete(VintageNet, ["proxy", "config"])
      PropertyTable.delete(VintageNet, ["proxy", "pac_revision"])
    end)

    {:ok, primary: primary, secondary: secondary}
  end

  defp send_snapshot(iface, opts) do
    snap = %Interface{
      iface: iface,
      intent: Keyword.get(opts, :intent),
      connection: Keyword.get(opts, :connection),
      pac_script: Keyword.get(opts, :pac_script),
      pac_fetch_error: Keyword.get(opts, :pac_fetch_error),
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

    test "publishes {:manual, descriptor} for an eligible :manual snapshot", %{primary: iface} do
      manual = %{mode: :manual, scheme: :http, host: "p.corp", port: 8080}
      send_snapshot(iface, intent: manual, connection: :internet)

      assert Publisher.get() ==
               {:manual, %{scheme: :http, host: "p.corp", port: 8080}}
    end

    test "publishes {:auto, :ready} when :auto snapshot includes a pac_script",
         %{primary: iface} do
      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet, pac_script: "FN")
      assert Publisher.get() == {:auto, :ready}
    end

    test "publishes {:auto, :no_url} when :auto snapshot has no script, no error, no URL source",
         %{primary: iface} do
      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet)
      assert Publisher.get() == {:auto, :no_url}
    end

    test "publishes {:auto, {:error, reason}} when :auto snapshot has a fetch error",
         %{primary: iface} do
      send_snapshot(iface,
        intent: %{mode: :auto},
        connection: :internet,
        pac_fetch_error: :nxdomain
      )

      assert Publisher.get() == {:auto, {:error, :nxdomain}}
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
    test "{:error, :no_proxy_resolved} when no interface is eligible" do
      assert Selector.resolve("https://x/") == {:error, :no_proxy_resolved}
    end

    test ":manual → {:ok, descriptor}", %{primary: iface} do
      manual = %{mode: :manual, scheme: :http, host: "p", port: 80}
      send_snapshot(iface, intent: manual, connection: :internet)

      assert Selector.resolve("https://anything/") ==
               {:ok, %{scheme: :http, host: "p", port: 80}}
    end

    test "PAC rule returning a proxy → {:ok, descriptor}", %{primary: iface} do
      script =
        ~s|function FindProxyForURL(url, host) { if (host == "x") return "PROXY q:1"; return "DIRECT"; }|

      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet, pac_script: script)

      assert Selector.resolve("http://x/") ==
               {:ok, %{scheme: :http, host: "q", port: 1}}
    end

    test "PAC default DIRECT → {:error, :pac_default_direct}", %{primary: iface} do
      script = ~s|function FindProxyForURL(url, host) { return "DIRECT"; }|
      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet, pac_script: script)

      assert Selector.resolve("https://x/") == {:error, :pac_default_direct}
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

  describe "pac_revision tick" do
    test "fires when an active iface's pac_script changes in place",
         %{primary: iface} do
      VintageNet.subscribe(Publisher.pac_revision_property())

      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet, pac_script: "OLD")
      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet, pac_script: "NEW")

      assert_receive {VintageNet, ["proxy", "pac_revision"], _, _, _}, 1_000
    end

    test "does not fire on initial nil → script transition (config event covers it)",
         %{primary: iface} do
      VintageNet.subscribe(Publisher.pac_revision_property())

      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet, pac_script: "ONLY")

      refute_receive {VintageNet, ["proxy", "pac_revision"], _, _, _}, 200
    end

    test "does not fire when pac_script is cleared (script → nil)",
         %{primary: iface} do
      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet, pac_script: "X")

      VintageNet.subscribe(Publisher.pac_revision_property())

      # Script cleared (e.g. disconnect path): config goes :auto → :unset,
      # which the config-property event already covers — no extra tick.
      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet, pac_script: nil)

      refute_receive {VintageNet, ["proxy", "pac_revision"], _, _, _}, 200
    end

    test "does not fire when the same script is republished",
         %{primary: iface} do
      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet, pac_script: "X")

      VintageNet.subscribe(Publisher.pac_revision_property())

      send_snapshot(iface, intent: %{mode: :auto}, connection: :internet, pac_script: "X")

      refute_receive {VintageNet, ["proxy", "pac_revision"], _, _, _}, 200
    end
  end
end
