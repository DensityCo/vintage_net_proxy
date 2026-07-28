defmodule VintageNetProxy.ChangeTest do
  use ExUnit.Case, async: false

  require VintageNetProxy

  @proxy_property ["proxy", "config"]
  @pac_revision_property ["proxy", "pac_revision"]

  setup do
    PropertyTable.delete(VintageNet, @proxy_property)
    PropertyTable.delete(VintageNet, @pac_revision_property)

    on_exit(fn ->
      VintageNetProxy.unsubscribe()
      PropertyTable.delete(VintageNet, @proxy_property)
      PropertyTable.delete(VintageNet, @pac_revision_property)
    end)

    :ok
  end

  test "subscribes to resolved proxy model changes" do
    assert :ok = VintageNetProxy.subscribe()

    PropertyTable.put(VintageNet, @proxy_property, :direct)

    assert_receive message = {VintageNet, @proxy_property, nil, :direct, _metadata}
    assert proxy_change?(message)
  end

  test "subscribes to in-place PAC reloads" do
    assert :ok = VintageNetProxy.subscribe()

    PropertyTable.put(VintageNet, @pac_revision_property, 1)

    assert_receive message = {VintageNet, @pac_revision_property, nil, 1, _metadata}
    assert proxy_change?(message)
  end

  test "supports an explicit config-only subscription" do
    assert :ok = VintageNet.subscribe(VintageNetProxy.property())

    PropertyTable.put(VintageNet, @pac_revision_property, 1)
    refute_receive {VintageNet, @pac_revision_property, _, _, _}

    PropertyTable.put(VintageNet, @proxy_property, :direct)
    assert_receive {VintageNet, @proxy_property, nil, :direct, _metadata}
  end

  test "ignores unrelated and unchanged property events" do
    refute proxy_change?({VintageNet, ["proxy", "connectivity"], :unknown, :ok, %{}})
    refute proxy_change?({VintageNet, @proxy_property, :direct, :direct, %{}})
  end

  test "unsubscribes from both change properties" do
    assert :ok = VintageNetProxy.subscribe()
    assert :ok = VintageNetProxy.unsubscribe()

    PropertyTable.put(VintageNet, @proxy_property, :direct)
    PropertyTable.put(VintageNet, @pac_revision_property, 1)

    refute_receive {VintageNet, _, _, _, _}
  end

  defp proxy_change?(message) when VintageNetProxy.is_change(message), do: true
  defp proxy_change?(_message), do: false
end
