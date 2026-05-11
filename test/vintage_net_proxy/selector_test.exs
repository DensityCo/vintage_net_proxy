defmodule VintageNetProxy.SelectorTest do
  use ExUnit.Case, async: false

  alias VintageNetProxy.{Publisher, Selector}

  setup do
    uniq = :erlang.unique_integer([:positive])
    primary = "primary#{uniq}"
    secondary = "secondary#{uniq}"

    start_supervised!({Selector, interfaces: [primary, secondary]})

    on_exit(fn -> PropertyTable.delete(VintageNet, ["proxy", "config"]) end)

    {:ok, primary: primary, secondary: secondary}
  end

  defp put_config(iface, value),
    do: PropertyTable.put(VintageNet, ["interface", iface, "config"], value)

  defp put_connection(iface, value),
    do: PropertyTable.put(VintageNet, ["interface", iface, "connection"], value)

  defp put_dhcp(iface, value),
    do: PropertyTable.put(VintageNet, ["interface", iface, "dhcp_options"], value)

  describe "initial publish" do
    test "publishes :unset when no interface state exists" do
      assert Publisher.get() == :unset
    end
  end

  describe "intent: :direct" do
    test "publishes :direct when intent + connection are eligible", %{primary: iface} do
      put_config(iface, %{type: :fake, proxy: %{mode: :direct}})
      put_connection(iface, :internet)
      _ = Selector.status()

      assert Publisher.get() == :direct
    end

    test "publishes :unset when intent is set but connection isn't up", %{primary: iface} do
      put_config(iface, %{type: :fake, proxy: %{mode: :direct}})
      put_connection(iface, :disconnected)
      _ = Selector.status()

      assert Publisher.get() == :unset
    end

    test "publishes :unset when connection is up but no intent", %{primary: iface} do
      put_connection(iface, :internet)
      _ = Selector.status()

      assert Publisher.get() == :unset
    end
  end

  describe "intent: :manual" do
    test "publishes the descriptor", %{primary: iface} do
      manual = %{mode: :manual, scheme: :http, host: "p.corp", port: 8080}
      put_config(iface, %{type: :fake, proxy: manual})
      put_connection(iface, :internet)
      _ = Selector.status()

      assert Publisher.get() == %{scheme: :http, host: "p.corp", port: 8080}
    end
  end

  describe "intent: :auto end-to-end (fetch + publish)" do
    test "explicit :pac_url is fetched on connection-up; publishes :auto",
         %{primary: iface} do
      port = serve_once(~s|function FindProxyForURL(url, host) { return "PROXY p:8080"; }|)

      put_config(iface, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad"}
      })

      put_connection(iface, :internet)
      _ = Selector.status()

      assert Publisher.get() == :auto

      # PAC evaluation is per-URL via resolve/1
      assert Selector.resolve("https://anywhere/") ==
               %{scheme: :http, host: "p", port: 8080}
    end

    test "DHCP-discovered WPAD is fetched when intent has no explicit pac_url",
         %{primary: iface} do
      port = serve_once(~s|function FindProxyForURL(url, host) { return "PROXY dhcp:9999"; }|)

      put_dhcp(iface, %{wpad: "http://127.0.0.1:#{port}/wpad"})
      put_config(iface, %{type: :fake, proxy: %{mode: :auto}})
      put_connection(iface, :internet)
      _ = Selector.status()

      assert Publisher.get() == :auto

      assert Selector.resolve("https://x/") ==
               %{scheme: :http, host: "dhcp", port: 9999}
    end

    test "connection going down clears the PAC cache (becomes ineligible)",
         %{primary: iface} do
      port = serve_once(~s|function FindProxyForURL(url, host) { return "DIRECT"; }|)

      put_config(iface, %{
        type: :fake,
        proxy: %{mode: :auto, pac_url: "http://127.0.0.1:#{port}/wpad"}
      })

      put_connection(iface, :internet)
      _ = Selector.status()
      assert Publisher.get() == :auto

      put_connection(iface, :disconnected)
      _ = Selector.status()
      assert Publisher.get() == :unset
    end
  end

  describe "multi-interface priority" do
    test "first eligible interface in the list wins", %{primary: p, secondary: s} do
      put_config(p, %{type: :fake, proxy: %{mode: :direct}})
      put_connection(p, :internet)

      manual = %{mode: :manual, scheme: :http, host: "q.corp", port: 8080}
      put_config(s, %{type: :fake, proxy: manual})
      put_connection(s, :internet)
      _ = Selector.status()

      assert Publisher.get() == :direct
    end

    test "falls through to secondary when primary is ineligible",
         %{primary: p, secondary: s} do
      put_connection(p, :internet)

      put_config(s, %{type: :fake, proxy: %{mode: :direct}})
      put_connection(s, :internet)
      _ = Selector.status()

      assert Publisher.get() == :direct
    end
  end

  describe "resolve/1" do
    test ":direct when no interface is eligible" do
      assert Selector.resolve("https://x/") == :direct
    end

    test "with :manual intent returns the descriptor regardless of URL",
         %{primary: iface} do
      manual = %{mode: :manual, scheme: :http, host: "p", port: 80}
      put_config(iface, %{type: :fake, proxy: manual})
      put_connection(iface, :internet)
      _ = Selector.status()

      assert Selector.resolve("https://anything/") == %{scheme: :http, host: "p", port: 80}
    end
  end

  describe "status/0" do
    test "reflects active interface and per-interface state",
         %{primary: p, secondary: s} do
      put_config(p, %{type: :fake, proxy: %{mode: :direct}})
      put_connection(p, :internet)
      _ = Selector.status()

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
      # Subsequent status call confirms the Selector is alive
      assert is_map(Selector.status())
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
