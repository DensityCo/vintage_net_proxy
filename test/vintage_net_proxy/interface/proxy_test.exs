defmodule VintageNetProxy.Interface.ProxyTest do
  @moduledoc """
  Pure-function tests for the per-interface proxy struct. The
  GenServer behavior is exercised end-to-end through
  `VintageNetProxyTest`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias VintageNetProxy.Interface.Proxy

  # Helper used by tests that want to swallow PAC's :pac_fallthrough warning.
  defp silently(fun), do: capture_log(fun)

  defp iface(opts) do
    %Proxy{
      iface: Keyword.get(opts, :iface, "eth0"),
      intent: Keyword.get(opts, :intent),
      connection: Keyword.get(opts, :connection, :disconnected),
      pac_script: Keyword.get(opts, :pac_script),
      dhcp_wpad_url: Keyword.get(opts, :dhcp_wpad_url),
      dhcp_domain: Keyword.get(opts, :dhcp_domain),
      local_ip: Keyword.get(opts, :local_ip)
    }
  end

  describe "eligible?/1" do
    test "intent nil → false" do
      refute Proxy.eligible?(iface(intent: nil, connection: :internet))
    end

    test "connection :disconnected → false" do
      refute Proxy.eligible?(iface(intent: %{mode: :direct}, connection: :disconnected))
    end

    test "intent + connection :internet → true" do
      assert Proxy.eligible?(iface(intent: %{mode: :direct}, connection: :internet))
    end

    test "intent + connection :lan → true" do
      assert Proxy.eligible?(iface(intent: %{mode: :direct}, connection: :lan))
    end
  end

  describe "value/1" do
    test "intent nil → :unset" do
      assert Proxy.value(iface(intent: nil)) == :unset
    end

    test ":direct → :direct" do
      assert Proxy.value(iface(intent: %{mode: :direct})) == :direct
    end

    test ":manual → {:manual, descriptor}" do
      intent = %{mode: :manual, scheme: :http, host: "p", port: 8080}

      assert Proxy.value(iface(intent: intent)) ==
               {:manual, %{scheme: :http, host: "p", port: 8080}}
    end

    test ":auto with pac_script → {:auto, :ready}" do
      assert Proxy.value(iface(intent: %{mode: :auto}, pac_script: "FN")) ==
               {:auto, :ready}
    end

    test ":auto with no script → {:auto, :no_pac}" do
      assert Proxy.value(iface(intent: %{mode: :auto})) == {:auto, :no_pac}
    end
  end

  describe "resolve/2 — return values" do
    @pac_default_direct ~s|function FindProxyForURL(url, host) { return "DIRECT"; }|
    @pac_default_proxy ~s|function FindProxyForURL(url, host) { return "PROXY p.corp:8080"; }|
    @pac_rule_direct ~s|function FindProxyForURL(url, host) { if (host == "x.example") return "DIRECT"; return "PROXY p.corp:8080"; }|
    @pac_rule_proxy ~s|function FindProxyForURL(url, host) { if (host == "x.example") return "PROXY q:1"; return "DIRECT"; }|

    test "manual :direct mode → {:ok, :direct}" do
      assert Proxy.resolve(iface(intent: %{mode: :direct}), "https://x/") == {:ok, :direct}
    end

    test "manual descriptor → {:ok, descriptor}" do
      intent = %{mode: :manual, scheme: :http, host: "p", port: 80}

      assert Proxy.resolve(iface(intent: intent), "https://x/") ==
               {:ok, %{scheme: :http, host: "p", port: 80}}
    end

    test "PAC rule returning a proxy → {:ok, descriptor}" do
      state = iface(intent: %{mode: :auto}, pac_script: @pac_rule_proxy)

      assert Proxy.resolve(state, "http://x.example/") ==
               {:ok, %{scheme: :http, host: "q", port: 1}}
    end

    test "PAC rule returning DIRECT → {:ok, :direct} (intentional bypass)" do
      state = iface(intent: %{mode: :auto}, pac_script: @pac_rule_direct)
      assert Proxy.resolve(state, "http://x.example/") == {:ok, :direct}
    end

    test "PAC default routing through a proxy → {:ok, descriptor}" do
      state = iface(intent: %{mode: :auto}, pac_script: @pac_default_proxy)

      assert Proxy.resolve(state, "http://anything/") ==
               {:ok, %{scheme: :http, host: "p.corp", port: 8080}}
    end

    test "PAC default DIRECT → {:ok, :direct} (script said so)" do
      state = iface(intent: %{mode: :auto}, pac_script: @pac_default_direct)
      assert Proxy.resolve(state, "http://anything/") == {:ok, :direct}
    end

    test "PAC fall-through (empty script) → {:error, :pac_fallthrough}" do
      state = iface(intent: %{mode: :auto}, pac_script: "")

      silently(fn ->
        assert Proxy.resolve(state, "http://anything/") == {:error, :pac_fallthrough}
      end)
    end

    test ":auto with no PAC script → {:error, :no_pac}" do
      assert Proxy.resolve(iface(intent: %{mode: :auto}), "http://anything/") ==
               {:error, :no_pac}
    end

    test "no intent → {:error, :no_proxy_resolved}" do
      assert Proxy.resolve(iface(intent: nil), "http://anything/") ==
               {:error, :no_proxy_resolved}
    end
  end

  describe "effective_pac_url/1" do
    test "nil when intent isn't :auto" do
      assert Proxy.effective_pac_url(iface(intent: %{mode: :direct}, connection: :internet)) ==
               nil
    end

    test "nil when connection isn't up" do
      s = iface(intent: %{mode: :auto, pac_url: "http://x/"}, connection: :disconnected)
      assert Proxy.effective_pac_url(s) == nil
    end

    test "returns explicit :pac_url when :auto + connected" do
      s = iface(intent: %{mode: :auto, pac_url: "http://x/"}, connection: :internet)
      assert Proxy.effective_pac_url(s) == "http://x/"
    end

    test "falls back to DHCP wpad when :auto has no explicit pac_url" do
      s =
        iface(
          intent: %{mode: :auto},
          connection: :internet,
          dhcp_wpad_url: "http://wpad/"
        )

      assert Proxy.effective_pac_url(s) == "http://wpad/"
    end

    test "explicit pac_url wins over DHCP wpad" do
      s =
        iface(
          intent: %{mode: :auto, pac_url: "http://explicit/"},
          connection: :internet,
          dhcp_wpad_url: "http://wpad/"
        )

      assert Proxy.effective_pac_url(s) == "http://explicit/"
    end

    test "DNS-WPAD fallback constructs http://wpad.<domain>/wpad.dat from DHCP option 15" do
      s =
        iface(
          intent: %{mode: :auto},
          connection: :internet,
          dhcp_domain: "corp.example.com"
        )

      assert Proxy.effective_pac_url(s) == "http://wpad.corp.example.com/wpad.dat"
    end

    test "DHCP option 252 wpad wins over DNS-WPAD fallback" do
      s =
        iface(
          intent: %{mode: :auto},
          connection: :internet,
          dhcp_wpad_url: "http://option252/wpad.dat",
          dhcp_domain: "corp.example.com"
        )

      assert Proxy.effective_pac_url(s) == "http://option252/wpad.dat"
    end

    test "explicit pac_url wins over DNS-WPAD fallback" do
      s =
        iface(
          intent: %{mode: :auto, pac_url: "http://explicit/"},
          connection: :internet,
          dhcp_domain: "corp.example.com"
        )

      assert Proxy.effective_pac_url(s) == "http://explicit/"
    end

    test "no DNS-WPAD when intent isn't :auto" do
      s =
        iface(
          intent: %{mode: :direct},
          connection: :internet,
          dhcp_domain: "corp.example.com"
        )

      assert Proxy.effective_pac_url(s) == nil
    end

    test "no DNS-WPAD when domain is malformed (rejected by Wpad)" do
      s =
        iface(
          intent: %{mode: :auto},
          connection: :internet,
          dhcp_domain: "http://evil.com/path"
        )

      assert Proxy.effective_pac_url(s) == nil
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
        |> Proxy.snapshot()

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
        |> Proxy.snapshot()

      assert snap.pac_url == "http://wpad.test/"
    end

    test "pac_url is nil when intent isn't :auto" do
      snap =
        iface(intent: %{mode: :direct}, dhcp_wpad_url: "http://wpad.test/")
        |> Proxy.snapshot()

      assert snap.pac_url == nil
    end

    test ":auto intent without a script reports pac_loaded? false and {:auto, :no_pac}" do
      snap = iface(intent: %{mode: :auto}) |> Proxy.snapshot()

      assert snap.value == {:auto, :no_pac}
      assert snap.pac_loaded? == false
    end

    test "surfaces local_ip when set" do
      snap = iface(local_ip: "10.1.2.3") |> Proxy.snapshot()
      assert snap.local_ip == "10.1.2.3"
    end

    test "local_ip is nil when no IP is available" do
      snap = iface(intent: %{mode: :auto}) |> Proxy.snapshot()
      assert snap.local_ip == nil
    end
  end

  describe "resolve/2 — myIpAddress threading" do
    @subnet_routing """
    function FindProxyForURL(url, host) {
      if (isInNet(myIpAddress(), "10.1.0.0", "255.255.0.0")) return "PROXY site-a:8080";
      return "PROXY default:8080";
    }
    """

    test "local_ip on the matching subnet picks the site-specific proxy" do
      state =
        iface(intent: %{mode: :auto}, pac_script: @subnet_routing, local_ip: "10.1.5.10")

      assert Proxy.resolve(state, "https://target.example/") ==
               {:ok, %{scheme: :http, host: "site-a", port: 8080}}
    end

    test "local_ip off-subnet falls to default" do
      state =
        iface(intent: %{mode: :auto}, pac_script: @subnet_routing, local_ip: "192.168.1.5")

      assert Proxy.resolve(state, "https://target.example/") ==
               {:ok, %{scheme: :http, host: "default", port: 8080}}
    end

    test "no local_ip falls to default (myIpAddress rules don't fire)" do
      state = iface(intent: %{mode: :auto}, pac_script: @subnet_routing)

      assert Proxy.resolve(state, "https://target.example/") ==
               {:ok, %{scheme: :http, host: "default", port: 8080}}
    end
  end
end
