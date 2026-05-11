defmodule VintageNetProxy.PersistenceIntegrationTest do
  @moduledoc """
  Verifies that proxy intent placed in an interface configuration survives
  VintageNet's normalize/persist/load cycle. This is the contract the proxy
  library relies on: vintage_net is the source of truth for persistence,
  including the `:proxy` field.

  These tests bypass the full Interface gen_statem (which requires Linux
  networking primitives) and exercise the persistence layer directly with
  realistic config maps that mirror what `VintageNet.configure/3` would
  hand to it.
  """
  use ExUnit.Case, async: false

  @tmp_dir "/tmp/vintage_net_proxy_persistence_test"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    previous_persistence = Application.get_env(:vintage_net, :persistence)
    previous_dir = Application.get_env(:vintage_net, :persistence_dir)
    previous_secret = Application.get_env(:vintage_net, :persistence_secret)

    Application.put_env(:vintage_net, :persistence, VintageNet.Persistence.FlatFile)
    Application.put_env(:vintage_net, :persistence_dir, @tmp_dir)
    Application.put_env(:vintage_net, :persistence_secret, "0123456789ABCDEF")

    on_exit(fn ->
      put_or_delete(:vintage_net, :persistence, previous_persistence)
      put_or_delete(:vintage_net, :persistence_dir, previous_dir)
      put_or_delete(:vintage_net, :persistence_secret, previous_secret)
      File.rm_rf!(@tmp_dir)
    end)

    :ok
  end

  defp put_or_delete(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete(app, key, value), do: Application.put_env(app, key, value)

  test "the :proxy field round-trips through encrypted persistence" do
    config = %{
      type: VintageNetTest.FakeTechnology,
      ipv4: %{method: :dhcp},
      proxy: %{mode: :manual, scheme: :http, host: "proxy.corp", port: 8080}
    }

    assert :ok = VintageNet.Persistence.call(:save, ["eth0", config])
    assert {:ok, loaded} = VintageNet.Persistence.call(:load, ["eth0"])
    assert loaded == config
    assert loaded.proxy == %{mode: :manual, scheme: :http, host: "proxy.corp", port: 8080}
  end

  test "the file on disk is opaque (encrypted), not plaintext" do
    config = %{
      type: VintageNetTest.FakeTechnology,
      proxy: %{mode: :manual, scheme: :http, host: "proxy.corp", port: 8080, password: "s3cret"}
    }

    assert :ok = VintageNet.Persistence.call(:save, ["eth0", config])

    {:ok, raw} = File.read(Path.join(@tmp_dir, "eth0"))
    refute String.contains?(raw, "proxy.corp")
    refute String.contains?(raw, "s3cret")
  end

  test ":direct mode round-trips" do
    config = %{type: VintageNetTest.FakeTechnology, proxy: %{mode: :direct}}
    assert :ok = VintageNet.Persistence.call(:save, ["wlan0", config])
    assert {:ok, ^config} = VintageNet.Persistence.call(:load, ["wlan0"])
  end

  test ":auto mode with explicit pac_url round-trips" do
    config = %{
      type: VintageNetTest.FakeTechnology,
      proxy: %{mode: :auto, pac_url: "http://wpad.corp/wpad.dat"}
    }

    assert :ok = VintageNet.Persistence.call(:save, ["wlan0", config])
    assert {:ok, ^config} = VintageNet.Persistence.call(:load, ["wlan0"])
  end
end
