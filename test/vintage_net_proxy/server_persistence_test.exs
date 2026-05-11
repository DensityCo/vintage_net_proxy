defmodule VintageNetProxy.ServerPersistenceTest do
  use ExUnit.Case, async: false

  alias VintageNetProxy.{Persistence, Server}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "vintage_net_proxy_server_persist_#{:erlang.unique_integer([:positive])}"
      )

    Application.put_env(:vintage_net_proxy, :persistence, VintageNetProxy.Persistence.FlatFile)
    Application.put_env(:vintage_net_proxy, :persistence_dir, dir)

    start_supervised!({PropertyTable, name: VintageNet})

    on_exit(fn ->
      Application.delete_env(:vintage_net_proxy, :persistence)
      Application.delete_env(:vintage_net_proxy, :persistence_dir)
      File.rm_rf!(dir)
    end)

    :ok
  end

  test "init restores target_url and override" do
    :ok =
      Persistence.save(%{
        target_url: "https://api.example.com/",
        override: :direct
      })

    iface = "persist_init_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Server, [interface: iface]})

    assert Server.get_target_url() == "https://api.example.com/"
    assert VintageNet.get(["proxy", "config"]) == :direct
  end

  test "set_override persists to disk" do
    iface = "persist_save_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Server, [interface: iface]})

    Server.set_override(%{scheme: :http, host: "p", port: 8080})

    assert {:ok, %{override: %{scheme: :http, host: "p", port: 8080}}} = Persistence.load()
  end

  test "clear_override removes the override key from persistence" do
    iface = "persist_clear_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Server, [interface: iface]})

    Server.set_override(:direct)
    Server.clear_override()

    {:ok, state} = Persistence.load()
    refute Map.has_key?(state, :override)
  end

  test "set_target_url persists" do
    iface = "persist_target_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Server, [interface: iface]})

    Server.set_target_url("https://api.example.com/")

    assert {:ok, %{target_url: "https://api.example.com/"}} = Persistence.load()
  end

  test "init merges opt-supplied target_url over persisted target_url" do
    :ok = Persistence.save(%{target_url: "https://from-disk/"})

    iface = "persist_opt_override_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Server, [interface: iface, target_url: "https://from-opts/"]})

    assert Server.get_target_url() == "https://from-opts/"
  end
end
