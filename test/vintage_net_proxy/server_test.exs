defmodule VintageNetProxy.ServerTest do
  use ExUnit.Case, async: false

  alias VintageNetProxy.Server

  setup do
    Application.put_env(:vintage_net_proxy, :persistence, VintageNetProxy.Persistence.Null)
    start_supervised!({PropertyTable, name: VintageNet})

    iface = "test#{:erlang.unique_integer([:positive])}"
    pid = start_supervised!({Server, [interface: iface]})

    on_exit(fn -> Application.delete_env(:vintage_net_proxy, :persistence) end)

    {:ok, iface: iface, pid: pid}
  end

  describe "initial state" do
    test "publishes :unset" do
      assert VintageNet.get(["proxy", "config"]) == :unset
    end

    test "status reports a clean default", %{iface: iface} do
      status = Server.status()
      assert status.iface == iface
      assert status.target_url == nil
      assert status.wpad_url == nil
      assert status.override == nil
      assert status.pac_loaded? == false
      assert status.current == :unset
    end
  end

  describe "manual override" do
    test "set_override(:direct) publishes :direct" do
      assert :ok = Server.set_override(:direct)
      assert VintageNet.get(["proxy", "config"]) == :direct
    end

    test "set_override(descriptor) publishes the descriptor" do
      desc = %{scheme: :http, host: "p.corp", port: 8080}
      assert :ok = Server.set_override(desc)
      assert VintageNet.get(["proxy", "config"]) == desc
    end

    test "set_override with auth in descriptor preserves all fields" do
      desc = %{scheme: :socks5, host: "s.corp", port: 1080, username: "alice", password: "x"}
      assert :ok = Server.set_override(desc)
      assert VintageNet.get(["proxy", "config"]) == desc
    end

    test "clear_override reverts to :unset" do
      Server.set_override(:direct)
      assert :ok = Server.clear_override()
      assert VintageNet.get(["proxy", "config"]) == :unset
    end

    test "override survives target_url change" do
      Server.set_override(:direct)
      Server.set_target_url("https://x/")
      assert VintageNet.get(["proxy", "config"]) == :direct
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

  describe "wpad_url" do
    test "set_wpad_url writes to the property table", %{iface: iface} do
      assert :ok = Server.set_wpad_url("http://wpad.test/wpad.dat")
      # The Server's own subscription will fire and try to fetch; that fetch
      # will fail (no real server), but the property is set regardless.
      assert VintageNet.get(["interface", iface, "wpad_url"]) == "http://wpad.test/wpad.dat"
    end

    test "clear_wpad_url removes from the property table", %{iface: iface} do
      Server.set_wpad_url("http://wpad.test/wpad.dat")
      assert :ok = Server.clear_wpad_url()
      assert VintageNet.get(["interface", iface, "wpad_url"]) == nil
    end
  end

  describe "resolve/1" do
    test "respects manual override regardless of URL" do
      Server.set_override(:direct)
      assert Server.resolve("https://api.example.com/") == :direct
      assert Server.resolve("http://intranet/") == :direct

      desc = %{scheme: :http, host: "p", port: 80}
      Server.set_override(desc)
      assert Server.resolve("https://anywhere/") == desc
    end

    test ":direct when no script and no override" do
      assert Server.resolve("https://x/") == :direct
    end
  end

  describe "status/0" do
    test "reflects override + target_url", %{iface: iface} do
      Server.set_override(:direct)
      Server.set_target_url("https://x/")

      status = Server.status()
      assert status.iface == iface
      assert status.target_url == "https://x/"
      assert status.override == :direct
      assert status.pac_loaded? == false
      assert status.current == :direct
    end
  end
end
