defmodule VintageNetProxy.Interface.RetryTest do
  @moduledoc """
  Covers the retry-on-failed-PAC-fetch behavior in
  `VintageNetProxy.Interface`.

  Starts `Interface` directly with `self()` as the parent so
  `:interface_changed` lands in the test mailbox — no Selector, no
  polling helper. `Fetcher.get/1` is stubbed via `Mimic` to drive
  synthetic transient-failure sequences.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias VintageNetProxy.{Fetcher, Interface}

  @short_backoff [10, 20, 40]
  @pac_url "http://wpad.test.local/wpad.dat"
  @other_url "http://wpad.other.local/wpad.dat"
  @pac_script "function FindProxyForURL(url, host) { return \"DIRECT\"; }"
  @auto_config %{type: :fake, proxy: %{mode: :auto, pac_url: @pac_url}}

  setup :set_mimic_global

  setup do
    iface = "test#{:erlang.unique_integer([:positive])}"
    config_prop = ["interface", iface, "config"]
    connection_prop = ["interface", iface, "connection"]

    PropertyTable.put(VintageNet, connection_prop, :internet)

    previous_backoff = Application.get_env(:vintage_net_proxy, :retry_backoff_ms)
    Application.put_env(:vintage_net_proxy, :retry_backoff_ms, @short_backoff)

    start_supervised!({Registry, keys: :unique, name: VintageNetProxy.InterfaceRegistry})
    start_supervised!({Interface, iface: iface, parent: self()})

    # Drain the initial push so each test asserts on event-driven changes.
    assert_receive {:interface_changed, ^iface, _}, 500

    on_exit(fn ->
      for prop <- [config_prop, connection_prop],
          do: PropertyTable.delete(VintageNet, prop)

      if previous_backoff,
        do: Application.put_env(:vintage_net_proxy, :retry_backoff_ms, previous_backoff),
        else: Application.delete_env(:vintage_net_proxy, :retry_backoff_ms)
    end)

    {:ok, iface: iface, config_prop: config_prop}
  end

  # Returns a stubbing function that pops responses from `plan` and
  # mirrors each invocation back to the test via `{:fetch, n}` so we
  # can both count and order observations from the mailbox.
  defp scripted_fetcher(plan) do
    parent = self()
    {:ok, agent} = start_supervised({Agent, fn -> 0 end})

    stub(Fetcher, :get, fn _url ->
      n = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
      send(parent, {:fetch, n})
      Enum.at(plan, min(n, length(plan) - 1))
    end)
  end

  test "retries until PAC fetch succeeds, then stops",
       %{iface: iface, config_prop: prop} do
    scripted_fetcher([{:error, :nxdomain}, {:error, :nxdomain}, {:ok, @pac_script}])

    PropertyTable.put(VintageNet, prop, @auto_config)

    assert_receive {:fetch, 0}, 500
    assert_receive {:fetch, 1}, 500
    assert_receive {:fetch, 2}, 500

    assert_receive {:interface_changed, ^iface, %{pac_script: @pac_script}}, 500

    # Chain should stop on success — comfortably past the largest
    # backoff bucket in the test schedule (40ms).
    refute_receive {:fetch, _}, 100
  end

  test "a VintageNet event invalidates a pending retry and re-fetches with the new URL",
       %{iface: iface, config_prop: prop} do
    # Long initial backoff: the retry timer won't fire on its own
    # within the test window. The only way the second fetch happens is
    # via the config-change event clearing the token and re-fetching.
    Application.put_env(:vintage_net_proxy, :retry_backoff_ms, [5_000, 5_000])
    scripted_fetcher([{:error, :nxdomain}, {:ok, @pac_script}])

    PropertyTable.put(VintageNet, prop, @auto_config)
    assert_receive {:fetch, 0}, 500

    PropertyTable.put(VintageNet, prop, %{
      type: :fake,
      proxy: %{mode: :auto, pac_url: @other_url}
    })

    assert_receive {:fetch, 1}, 500
    assert_receive {:interface_changed, ^iface, %{pac_script: @pac_script}}, 500
    refute_receive {:fetch, _}, 100
  end

  test "no retry scheduled when there is no PAC URL to fetch",
       %{iface: iface, config_prop: prop} do
    # Reject any Fetcher.get call — :direct mode means
    # Proxy.fetch_target/1 returns :none, so no fetch should fire.
    reject(&Fetcher.get/1)

    PropertyTable.put(VintageNet, prop, %{type: :fake, proxy: %{mode: :direct}})

    assert_receive {:interface_changed, ^iface, %{intent: %{mode: :direct}}}, 500
    refute_receive {:interface_changed, ^iface, _}, 100
  end
end
