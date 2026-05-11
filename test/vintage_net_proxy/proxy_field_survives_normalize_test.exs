defmodule VintageNetProxy.ProxyFieldSurvivesNormalizeTest do
  @moduledoc """
  The library reads proxy intent from `["interface", iface, "config"]`,
  which holds the *normalized* config produced by
  `technology.normalize/1`. Whether `:proxy` (an unknown field from the
  technology's point of view) survives normalization is therefore the
  load-bearing assumption behind this entire library.

  This test exercises the real path against `VintageNetEthernet` —
  `VintageNet.Interface.to_raw_config/2` runs `normalize/1` and returns a
  `RawConfig` whose `source_config` is what would be written to the
  PropertyTable by `VintageNet.configure/3`. If `:proxy` is missing from
  `source_config`, this library would never see proxy intent on real
  devices using vintage_net_ethernet.
  """
  use ExUnit.Case, async: true

  describe "VintageNetEthernet.normalize/1" do
    test ":proxy :direct survives" do
      config = %{
        type: VintageNetEthernet,
        ipv4: %{method: :dhcp},
        proxy: %{mode: :direct}
      }

      {:ok, raw_config} = VintageNet.Interface.to_raw_config("eth0", config)
      assert raw_config.source_config.proxy == %{mode: :direct}
    end

    test ":proxy :manual with all fields survives" do
      manual = %{
        mode: :manual,
        scheme: :http,
        host: "proxy.corp",
        port: 8080,
        username: "alice",
        password: "secret"
      }

      config = %{
        type: VintageNetEthernet,
        ipv4: %{method: :dhcp},
        proxy: manual
      }

      {:ok, raw_config} = VintageNet.Interface.to_raw_config("eth0", config)
      assert raw_config.source_config.proxy == manual
    end

    test ":proxy :auto with pac_url survives" do
      config = %{
        type: VintageNetEthernet,
        ipv4: %{method: :dhcp},
        proxy: %{mode: :auto, pac_url: "http://wpad.corp/wpad.dat"}
      }

      {:ok, raw_config} = VintageNet.Interface.to_raw_config("eth0", config)

      assert raw_config.source_config.proxy ==
               %{mode: :auto, pac_url: "http://wpad.corp/wpad.dat"}
    end

    test ":proxy :auto without pac_url (DHCP-discovered) survives" do
      config = %{
        type: VintageNetEthernet,
        ipv4: %{method: :dhcp},
        proxy: %{mode: :auto}
      }

      {:ok, raw_config} = VintageNet.Interface.to_raw_config("eth0", config)
      assert raw_config.source_config.proxy == %{mode: :auto}
    end
  end
end
