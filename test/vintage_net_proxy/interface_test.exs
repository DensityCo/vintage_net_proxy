defmodule VintageNetProxy.InterfaceTest do
  @moduledoc """
  Pure-helper tests for the `Interface` struct. The GenServer behavior is
  exercised end-to-end through `VintageNetProxyTest`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias VintageNetProxy.Interface

  defp iface(opts) do
    %Interface{
      iface: Keyword.get(opts, :iface, "eth0"),
      intent: Keyword.get(opts, :intent),
      connection: Keyword.get(opts, :connection, :disconnected),
      pac_script: Keyword.get(opts, :pac_script),
      pac_fetch_error: Keyword.get(opts, :pac_fetch_error),
      dhcp_wpad_url: Keyword.get(opts, :dhcp_wpad_url),
      dhcp_domain: Keyword.get(opts, :dhcp_domain)
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

    test ":manual → {:manual, descriptor}" do
      intent = %{mode: :manual, scheme: :http, host: "p", port: 8080}

      assert Interface.value(iface(intent: intent)) ==
               {:manual, %{scheme: :http, host: "p", port: 8080}}
    end

    test ":auto with pac_script → {:auto, :ready}" do
      assert Interface.value(iface(intent: %{mode: :auto}, pac_script: "FN")) ==
               {:auto, :ready}
    end

    test ":auto with no script, no error, no URL source → {:auto, :no_url}" do
      assert Interface.value(iface(intent: %{mode: :auto})) == {:auto, :no_url}
    end

    test ":auto with no script and a fetch error → {:auto, {:error, reason}}" do
      state = iface(intent: %{mode: :auto}, pac_fetch_error: :timeout)
      assert Interface.value(state) == {:auto, {:error, :timeout}}
    end

    test ":auto with a script wins over a stale fetch error" do
      state =
        iface(intent: %{mode: :auto}, pac_script: "FN", pac_fetch_error: :previously_failed)

      assert Interface.value(state) == {:auto, :ready}
    end
  end

  describe "resolve/2 — return values" do
    @pac_default_direct ~s|function FindProxyForURL(url, host) { return "DIRECT"; }|
    @pac_default_proxy ~s|function FindProxyForURL(url, host) { return "PROXY p.corp:8080"; }|
    @pac_rule_direct ~s|function FindProxyForURL(url, host) { if (host == "x.example") return "DIRECT"; return "PROXY p.corp:8080"; }|
    @pac_rule_proxy ~s|function FindProxyForURL(url, host) { if (host == "x.example") return "PROXY q:1"; return "DIRECT"; }|

    test "manual :direct mode → {:ok, :direct}" do
      assert Interface.resolve(iface(intent: %{mode: :direct}), "https://x/") == {:ok, :direct}
    end

    test "manual descriptor → {:ok, descriptor}" do
      intent = %{mode: :manual, scheme: :http, host: "p", port: 80}

      assert Interface.resolve(iface(intent: intent), "https://x/") ==
               {:ok, %{scheme: :http, host: "p", port: 80}}
    end

    test "PAC rule returning a proxy → {:ok, descriptor}" do
      state = iface(intent: %{mode: :auto}, pac_script: @pac_rule_proxy)

      assert Interface.resolve(state, "http://x.example/") ==
               {:ok, %{scheme: :http, host: "q", port: 1}}
    end

    test "PAC rule returning DIRECT → {:ok, :direct} (intentional bypass)" do
      state = iface(intent: %{mode: :auto}, pac_script: @pac_rule_direct)
      assert Interface.resolve(state, "http://x.example/") == {:ok, :direct}
    end

    test "PAC default routing through a proxy → {:ok, descriptor}" do
      state = iface(intent: %{mode: :auto}, pac_script: @pac_default_proxy)

      assert Interface.resolve(state, "http://anything/") ==
               {:ok, %{scheme: :http, host: "p.corp", port: 8080}}
    end

    test "PAC default DIRECT → {:error, :pac_default_direct}" do
      state = iface(intent: %{mode: :auto}, pac_script: @pac_default_direct)
      assert Interface.resolve(state, "http://anything/") == {:error, :pac_default_direct}
    end

    test "PAC fall-through (empty script) → {:error, :pac_fallthrough}" do
      state = iface(intent: %{mode: :auto}, pac_script: "")
      assert Interface.resolve(state, "http://anything/") == {:error, :pac_fallthrough}
    end

    test ":auto with no PAC URL → {:error, :no_pac_url}" do
      assert Interface.resolve(iface(intent: %{mode: :auto}), "http://anything/") ==
               {:error, :no_pac_url}
    end

    test ":auto with a PAC fetch error → {:error, {:pac_fetch_failed, reason}}" do
      state = iface(intent: %{mode: :auto}, pac_fetch_error: :timeout)

      assert Interface.resolve(state, "http://anything/") ==
               {:error, {:pac_fetch_failed, :timeout}}
    end

    test "no intent → {:error, :no_proxy_resolved}" do
      assert Interface.resolve(iface(intent: nil), "http://anything/") ==
               {:error, :no_proxy_resolved}
    end
  end

  describe "resolve/2 — diagnostic logging" do
    @pac_default_direct ~s|function FindProxyForURL(url, host) { return "DIRECT"; }|
    @pac_default_proxy ~s|function FindProxyForURL(url, host) { return "PROXY p.corp:8080"; }|
    @pac_rule_direct ~s|function FindProxyForURL(url, host) { if (host == "x.example") return "DIRECT"; return "PROXY p.corp:8080"; }|
    @pac_fallthrough ""

    test "{:default, :direct} logs at :info with iface + url" do
      state = iface(iface: "wlan0", intent: %{mode: :auto}, pac_script: @pac_default_direct)

      log =
        capture_log([level: :info], fn ->
          Interface.resolve(state, "https://api.example.com/")
        end)

      assert log =~ "PAC default on wlan0 evaluated to DIRECT"
      assert log =~ "https://api.example.com/"
    end

    test "{:rule, :direct} does NOT log (intentional bypass via a rule)" do
      state = iface(iface: "wlan0", intent: %{mode: :auto}, pac_script: @pac_rule_direct)

      log =
        capture_log([level: :debug], fn ->
          Interface.resolve(state, "http://x.example/")
        end)

      refute log =~ "PAC"
    end

    test "{:fallthrough, _} logs at :warning" do
      state = iface(iface: "wlan0", intent: %{mode: :auto}, pac_script: @pac_fallthrough)

      log =
        capture_log([level: :warning], fn ->
          Interface.resolve(state, "https://api.example.com/")
        end)

      assert log =~ "PAC on wlan0 matched no rules and had no default"
      assert log =~ "https://api.example.com/"
    end

    test "does not log when PAC resolves to a proxy descriptor" do
      state = iface(intent: %{mode: :auto}, pac_script: @pac_default_proxy)

      log =
        capture_log([level: :info], fn ->
          Interface.resolve(state, "https://api.example.com/")
        end)

      refute log =~ "evaluated to DIRECT"
    end

    test "does not log for :direct mode (no PAC was consulted)" do
      log =
        capture_log([level: :info], fn ->
          Interface.resolve(iface(intent: %{mode: :direct}), "https://api.example.com/")
        end)

      refute log =~ "PAC"
    end

    test "does not log when :auto has no pac_script (degraded path)" do
      log =
        capture_log([level: :info], fn ->
          Interface.resolve(iface(intent: %{mode: :auto}), "https://api.example.com/")
        end)

      refute log =~ "PAC"
    end
  end

  describe "effective_pac_url/1" do
    test "nil when intent isn't :auto" do
      assert Interface.effective_pac_url(iface(intent: %{mode: :direct}, connection: :internet)) ==
               nil
    end

    test "nil when connection isn't up" do
      s = iface(intent: %{mode: :auto, pac_url: "http://x/"}, connection: :disconnected)
      assert Interface.effective_pac_url(s) == nil
    end

    test "returns explicit :pac_url when :auto + connected" do
      s = iface(intent: %{mode: :auto, pac_url: "http://x/"}, connection: :internet)
      assert Interface.effective_pac_url(s) == "http://x/"
    end

    test "falls back to DHCP wpad when :auto has no explicit pac_url" do
      s =
        iface(
          intent: %{mode: :auto},
          connection: :internet,
          dhcp_wpad_url: "http://wpad/"
        )

      assert Interface.effective_pac_url(s) == "http://wpad/"
    end

    test "explicit pac_url wins over DHCP wpad" do
      s =
        iface(
          intent: %{mode: :auto, pac_url: "http://explicit/"},
          connection: :internet,
          dhcp_wpad_url: "http://wpad/"
        )

      assert Interface.effective_pac_url(s) == "http://explicit/"
    end

    test "DNS-WPAD fallback constructs http://wpad.<domain>/wpad.dat from DHCP option 15" do
      s =
        iface(
          intent: %{mode: :auto},
          connection: :internet,
          dhcp_domain: "corp.example.com"
        )

      assert Interface.effective_pac_url(s) == "http://wpad.corp.example.com/wpad.dat"
    end

    test "DHCP option 252 wpad wins over DNS-WPAD fallback" do
      s =
        iface(
          intent: %{mode: :auto},
          connection: :internet,
          dhcp_wpad_url: "http://option252/wpad.dat",
          dhcp_domain: "corp.example.com"
        )

      assert Interface.effective_pac_url(s) == "http://option252/wpad.dat"
    end

    test "explicit pac_url wins over DNS-WPAD fallback" do
      s =
        iface(
          intent: %{mode: :auto, pac_url: "http://explicit/"},
          connection: :internet,
          dhcp_domain: "corp.example.com"
        )

      assert Interface.effective_pac_url(s) == "http://explicit/"
    end

    test "no DNS-WPAD when intent isn't :auto" do
      s =
        iface(
          intent: %{mode: :direct},
          connection: :internet,
          dhcp_domain: "corp.example.com"
        )

      assert Interface.effective_pac_url(s) == nil
    end

    test "no DNS-WPAD when domain is malformed (rejected by Wpad)" do
      s =
        iface(
          intent: %{mode: :auto},
          connection: :internet,
          dhcp_domain: "http://evil.com/path"
        )

      assert Interface.effective_pac_url(s) == nil
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
      assert snap.pac_fetch_error == nil
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

    test "surfaces pac_fetch_error and the matching {:auto, {:error, _}} value" do
      snap =
        iface(intent: %{mode: :auto}, pac_fetch_error: :nxdomain)
        |> Interface.snapshot()

      assert snap.pac_fetch_error == :nxdomain
      assert snap.value == {:auto, {:error, :nxdomain}}
      assert snap.pac_loaded? == false
    end
  end
end
