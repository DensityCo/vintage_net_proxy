defmodule VintageNetProxy.ConfigureEndToEndTest do
  @moduledoc """
  Closes the only remaining gap in the test pyramid: every other test
  starts halfway through (a `PropertyTable.put` or a hand-built Interface
  struct). This test starts from the user-facing entry point,
  `VintageNet.configure/3`, and verifies that — for every proxy mode —
  the resulting value at `["interface", iface, "config"]` includes the
  `:proxy` field this library reads.

  We deliberately don't assert against `["proxy", "config"]` here.
  vintage_net's interface state machine repeatedly publishes
  `:disconnected` for the iface's `connection` property while it fails
  to manipulate the (non-existent) host network — that's an isolated
  side effect, not a property of the configure call. The end-to-end
  pipeline downstream of the config-property is covered by
  `vintage_net_proxy_test.exs` and the integration suite; here we just
  prove the user's entry point feeds it correctly.

  Combined with `proxy_field_survives_normalize_test.exs` (which
  verifies `VintageNetEthernet`/`VintageNetWiFi` preserve `:proxy`
  through `normalize/1`), this test closes the
  `configure → published config property` half of the chain.
  """
  use ExUnit.Case, async: false

  defmodule TestTech do
    @moduledoc false
    @behaviour VintageNet.Technology

    alias VintageNet.Interface.RawConfig

    @impl true
    def normalize(config), do: config

    @impl true
    def to_raw_config(ifname, config, _opts) do
      %RawConfig{
        ifname: ifname,
        type: __MODULE__,
        source_config: config,
        required_ifnames: []
      }
    end

    @impl true
    def ioctl(_ifname, _command, _args), do: {:error, :unsupported}

    @impl true
    def check_system(_opts), do: :ok
  end

  setup do
    iface = "cfg_e2e_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      for prop <- ["config", "dhcp_options", "connection", "type", "state"] do
        PropertyTable.delete(VintageNet, ["interface", iface, prop])
      end
    end)

    {:ok, iface: iface}
  end

  describe "VintageNet.configure writes the normalized :proxy field" do
    test ":direct → %{mode: :direct} in the config property", %{iface: iface} do
      :ok = VintageNet.configure(iface, %{type: TestTech, proxy: %{mode: :direct}})

      assert %{proxy: %{mode: :direct}} = VintageNet.get(["interface", iface, "config"])
    end

    test ":manual normalizes scheme + preserves credentials", %{iface: iface} do
      manual = %{
        mode: :manual,
        scheme: :socks5,
        host: "proxy.corp",
        port: 1080,
        username: "alice",
        password: "secret"
      }

      :ok = VintageNet.configure(iface, %{type: TestTech, proxy: manual})

      assert %{proxy: ^manual} = VintageNet.get(["interface", iface, "config"])
    end

    test ":manual without scheme — survives raw (normalization fills :http at consume time)",
         %{iface: iface} do
      raw = %{mode: :manual, host: "p", port: 80}
      :ok = VintageNet.configure(iface, %{type: TestTech, proxy: raw})

      # `VintageNetProxy.Config.normalize/1` (called by our `Interface` when
      # it reads the property) is what fills in the default `scheme: :http`.
      # Here we only check the raw shape lands in the property table.
      assert %{proxy: ^raw} = VintageNet.get(["interface", iface, "config"])
    end

    test ":auto with explicit pac_url", %{iface: iface} do
      auto = %{mode: :auto, pac_url: "http://wpad.corp/wpad.dat"}
      :ok = VintageNet.configure(iface, %{type: TestTech, proxy: auto})

      assert %{proxy: ^auto} = VintageNet.get(["interface", iface, "config"])
    end

    test ":auto for DHCP-discovered wpad", %{iface: iface} do
      :ok = VintageNet.configure(iface, %{type: TestTech, proxy: %{mode: :auto}})

      assert %{proxy: %{mode: :auto}} = VintageNet.get(["interface", iface, "config"])
    end

    test "config without :proxy field leaves :proxy absent", %{iface: iface} do
      :ok = VintageNet.configure(iface, %{type: TestTech})

      config = VintageNet.get(["interface", iface, "config"])
      refute Map.has_key?(config, :proxy)
    end
  end
end
