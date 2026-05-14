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

  describe "resolve/2 — PAC fall-through diagnostics" do
    @pac_direct ~s|function FindProxyForURL(url, host) { return "DIRECT"; }|
    @pac_proxy ~s|function FindProxyForURL(url, host) { return "PROXY p.corp:8080"; }|

    # Unique per test so the seen-URLs ETS table from a prior test (or
    # a concurrent async test) can't shift our expected log level.
    defp unique_url, do: "https://t#{:erlang.unique_integer([:positive])}.example/"

    test "first PAC :direct for a URL logs at :info, with iface + url" do
      state = iface(iface: "wlan0", intent: %{mode: :auto}, pac_script: @pac_direct)
      url = unique_url()

      log =
        capture_log([level: :info], fn ->
          assert Interface.resolve(state, url) == :direct
        end)

      assert log =~ "PAC on wlan0 evaluated to DIRECT"
      assert log =~ url
    end

    test "subsequent PAC :direct for the same URL drops to :debug" do
      state = iface(intent: %{mode: :auto}, pac_script: @pac_direct)
      url = unique_url()

      # Prime the dedup set.
      Interface.resolve(state, url)

      info_log = capture_log([level: :info], fn -> Interface.resolve(state, url) end)
      refute info_log =~ "PAC on"

      debug_log = capture_log([level: :debug], fn -> Interface.resolve(state, url) end)
      assert debug_log =~ "PAC on"
    end

    test "different URLs each log at :info on their first occurrence" do
      state = iface(intent: %{mode: :auto}, pac_script: @pac_direct)
      url_a = unique_url()
      url_b = unique_url()

      log =
        capture_log([level: :info], fn ->
          Interface.resolve(state, url_a)
          Interface.resolve(state, url_b)
        end)

      assert log =~ url_a
      assert log =~ url_b
    end

    test "does not log when PAC mode evaluates to a proxy descriptor" do
      state = iface(intent: %{mode: :auto}, pac_script: @pac_proxy)

      log =
        capture_log([level: :debug], fn ->
          assert Interface.resolve(state, unique_url()) ==
                   %{scheme: :http, host: "p.corp", port: 8080}
        end)

      refute log =~ "evaluated to DIRECT"
    end

    test "does not log for :direct mode (no PAC was consulted)" do
      state = iface(intent: %{mode: :direct})

      log =
        capture_log([level: :debug], fn ->
          assert Interface.resolve(state, unique_url()) == :direct
        end)

      refute log =~ "PAC on"
    end

    test "does not log when :auto has no pac_script (degraded path)" do
      state = iface(intent: %{mode: :auto})

      log =
        capture_log([level: :debug], fn ->
          assert Interface.resolve(state, unique_url()) == :direct
        end)

      refute log =~ "PAC on"
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
