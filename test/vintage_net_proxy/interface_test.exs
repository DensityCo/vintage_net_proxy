defmodule VintageNetProxy.InterfaceTest do
  @moduledoc """
  Pure-helper tests for the `Interface` struct. The GenServer behavior is
  exercised end-to-end through `VintageNetProxyTest`.
  """
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
