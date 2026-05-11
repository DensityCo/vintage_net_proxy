defmodule VintageNetProxy.Persistence.FlatFileTest do
  use ExUnit.Case, async: false

  alias VintageNetProxy.Persistence.FlatFile

  setup do
    dir = Path.join(System.tmp_dir!(), "vintage_net_proxy_test_#{:erlang.unique_integer([:positive])}")
    Application.put_env(:vintage_net_proxy, :persistence_dir, dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.delete_env(:vintage_net_proxy, :persistence_dir)
    end)

    {:ok, dir: dir}
  end

  test "load returns empty map when no file exists" do
    assert {:ok, %{}} = FlatFile.load()
  end

  test "save then load round-trips a state" do
    state = %{
      target_url: "https://api.example.com/",
      wpad_url: "http://wpad.corp/wpad.dat",
      override: {:proxy, "p.corp", 8080}
    }

    assert :ok = FlatFile.save(state)
    assert {:ok, ^state} = FlatFile.load()
  end

  test "save is atomic (temp file + rename, no partial state on crash)", %{dir: dir} do
    :ok = FlatFile.save(%{target_url: "https://x/"})
    assert File.exists?(Path.join(dir, "state"))
    refute File.exists?(Path.join(dir, "state.tmp"))
  end

  test "load returns :corrupt for garbage" do
    :ok = FlatFile.save(%{target_url: "https://x/"})
    File.write!(Path.join(Application.get_env(:vintage_net_proxy, :persistence_dir), "state"), "not-erlang-terms")

    assert {:error, :corrupt} = FlatFile.load()
  end

  test "clear removes the file" do
    :ok = FlatFile.save(%{target_url: "https://x/"})
    assert :ok = FlatFile.clear()
    assert {:ok, %{}} = FlatFile.load()
  end

  test "clear is idempotent when no file exists" do
    assert :ok = FlatFile.clear()
  end
end
