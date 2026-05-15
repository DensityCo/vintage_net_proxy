defmodule VintageNetProxy.Interface.RetryTest do
  @moduledoc """
  Covers the retry-on-failed-PAC-fetch behavior in
  `VintageNetProxy.Interface`.

  Setup is identical to the integration tests in `VintageNetProxyTest`,
  but starts the supervisor with a synthetic fetcher and tiny backoff
  schedule so we can drive transient-failure scenarios deterministically.
  """
  use ExUnit.Case, async: false

  alias VintageNetProxy.Interface

  setup do
    iface = "test#{:erlang.unique_integer([:positive])}"

    properties = %{
      config: ["interface", iface, "config"],
      dhcp: ["interface", iface, "dhcp_options"],
      connection: ["interface", iface, "connection"]
    }

    PropertyTable.put(VintageNet, properties.connection, :internet)

    on_exit(fn ->
      for {_k, prop} <- properties, do: PropertyTable.delete(VintageNet, prop)
      PropertyTable.delete(VintageNet, ["proxy", "config"])
    end)

    {:ok, iface: iface, properties: properties}
  end

  defp start_with_fetcher!(iface, fetcher, backoff_ms) do
    start_supervised!(
      {VintageNetProxy.Supervisor,
       interfaces: [iface], fetcher: fetcher, retry_backoff_ms: backoff_ms}
    )
  end

  defp counting_fetcher(plan) do
    {:ok, agent} = Agent.start_link(fn -> {0, plan} end)

    fetcher = fn _url ->
      Agent.get_and_update(agent, fn {n, [step | rest]} -> {step, {n + 1, rest ++ [step]}} end)
    end

    {fetcher, fn -> Agent.get(agent, fn {n, _} -> n end) end}
  end

  defp wait_until(fun, timeout_ms \\ 1_000, interval_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    loop = fn loop ->
      case fun.() do
        {:ok, value} ->
          value

        :error ->
          if System.monotonic_time(:millisecond) >= deadline do
            flunk("wait_until timed out after #{timeout_ms}ms")
          else
            Process.sleep(interval_ms)
            loop.(loop)
          end
      end
    end

    loop.(loop)
  end

  test "retries until PAC fetch succeeds, then stops",
       %{iface: iface, properties: properties} do
    {fetcher, calls} =
      counting_fetcher([
        {:error, :nxdomain},
        {:error, :nxdomain},
        {:ok, "function FindProxyForURL(url, host) { return \"DIRECT\"; }"}
      ])

    start_with_fetcher!(iface, fetcher, [10, 20, 40])

    PropertyTable.put(VintageNet, properties.config, %{
      type: :fake,
      proxy: %{mode: :auto, pac_url: "http://wpad.test.local/wpad.dat"}
    })

    wait_until(fn ->
      proxy = Interface.get(iface)
      if is_binary(proxy.pac_script), do: {:ok, proxy}, else: :error
    end)

    # Third call succeeded; nothing more should fire after that. Sleep
    # past the largest backoff and confirm the counter is steady.
    Process.sleep(80)
    final_count = calls.()
    assert final_count >= 3
    Process.sleep(80)
    assert calls.() == final_count
  end

  test "a VintageNet event cancels the pending retry and re-fetches immediately",
       %{iface: iface, properties: properties} do
    {fetcher, calls} =
      counting_fetcher([
        {:error, :nxdomain},
        {:ok, "function FindProxyForURL(url, host) { return \"DIRECT\"; }"}
      ])

    # First backoff is intentionally long so we can prove the event
    # short-circuited it rather than the timer firing on its own.
    start_with_fetcher!(iface, fetcher, [5_000, 5_000])

    PropertyTable.put(VintageNet, properties.config, %{
      type: :fake,
      proxy: %{mode: :auto, pac_url: "http://wpad.test.local/wpad.dat"}
    })

    # Wait for the first (failed) attempt to be observed.
    wait_until(fn -> if calls.() >= 1, do: {:ok, :ok}, else: :error end)

    # Push a different URL through the config event — this should
    # cancel the long retry timer and run a fresh fetch right away.
    PropertyTable.put(VintageNet, properties.config, %{
      type: :fake,
      proxy: %{mode: :auto, pac_url: "http://wpad.other.local/wpad.dat"}
    })

    wait_until(fn ->
      proxy = Interface.get(iface)
      if is_binary(proxy.pac_script), do: {:ok, proxy}, else: :error
    end)

    # Two fetcher calls: the failure, then the success triggered by the
    # config event. If the long timer had fired, we'd see >2.
    assert calls.() == 2
  end

  test "no retry scheduled when there is no PAC URL to fetch",
       %{iface: iface, properties: properties} do
    {fetcher, calls} = counting_fetcher([{:error, :nxdomain}])
    start_with_fetcher!(iface, fetcher, [10, 20, 40])

    PropertyTable.put(VintageNet, properties.config, %{
      type: :fake,
      proxy: %{mode: :direct}
    })

    # Flush the mailbox via a sync call, then wait past the schedule.
    _ = Interface.get(iface)
    Process.sleep(120)
    assert calls.() == 0
  end
end
