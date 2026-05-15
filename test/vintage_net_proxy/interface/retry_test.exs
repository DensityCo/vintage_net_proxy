defmodule VintageNetProxy.Interface.RetryTest do
  @moduledoc """
  Covers the retry-on-failed-PAC-fetch behavior in
  `VintageNetProxy.Interface`.

  Setup mirrors the integration tests in `VintageNetProxyTest`, plus
  a tiny `:retry_backoff_ms` override (so retries fire in tens of ms
  instead of seconds) and a `Mimic` stub on `VintageNetProxy.Fetcher`
  to drive synthetic transient-failure scenarios.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias VintageNetProxy.{Fetcher, Interface}

  @short_backoff [10, 20, 40]
  @pac_url "http://wpad.test.local/wpad.dat"
  @pac_script "function FindProxyForURL(url, host) { return \"DIRECT\"; }"

  setup :set_mimic_global

  setup do
    iface = "test#{:erlang.unique_integer([:positive])}"

    properties = %{
      config: ["interface", iface, "config"],
      dhcp: ["interface", iface, "dhcp_options"],
      connection: ["interface", iface, "connection"]
    }

    PropertyTable.put(VintageNet, properties.connection, :internet)

    previous_backoff = Application.get_env(:vintage_net_proxy, :retry_backoff_ms)
    Application.put_env(:vintage_net_proxy, :retry_backoff_ms, @short_backoff)

    on_exit(fn ->
      for {_k, prop} <- properties, do: PropertyTable.delete(VintageNet, prop)
      PropertyTable.delete(VintageNet, ["proxy", "config"])

      if previous_backoff,
        do: Application.put_env(:vintage_net_proxy, :retry_backoff_ms, previous_backoff),
        else: Application.delete_env(:vintage_net_proxy, :retry_backoff_ms)
    end)

    {:ok, iface: iface, properties: properties}
  end

  defp start_tree!(iface) do
    start_supervised!({VintageNetProxy.Supervisor, interfaces: [iface]})
  end

  # Drives `Fetcher.get/1` from a queue of scripted responses; the queue
  # cycles, so once exhausted the final response repeats indefinitely.
  # Returns a 0-arity function that reports how many fetches have been
  # observed so far.
  defp stub_fetcher(plan) do
    {:ok, agent} = start_supervised({Agent, fn -> {0, plan} end})

    stub(Fetcher, :get, fn _url ->
      Agent.get_and_update(agent, fn {n, [step | rest]} ->
        {step, {n + 1, rest ++ [step]}}
      end)
    end)

    fn -> Agent.get(agent, fn {n, _} -> n end) end
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
    calls = stub_fetcher([{:error, :nxdomain}, {:error, :nxdomain}, {:ok, @pac_script}])
    start_tree!(iface)

    PropertyTable.put(VintageNet, properties.config, %{
      type: :fake,
      proxy: %{mode: :auto, pac_url: @pac_url}
    })

    wait_until(fn ->
      proxy = Interface.get(iface)
      if is_binary(proxy.pac_script), do: {:ok, proxy}, else: :error
    end)

    # Third call succeeded; the chain should stop. Sleep past the
    # largest backoff and confirm the counter is steady.
    Process.sleep(80)
    final_count = calls.()
    assert final_count >= 3
    Process.sleep(80)
    assert calls.() == final_count
  end

  test "a VintageNet event cancels the pending retry and re-fetches immediately",
       %{iface: iface, properties: properties} do
    Application.put_env(:vintage_net_proxy, :retry_backoff_ms, [5_000, 5_000])
    calls = stub_fetcher([{:error, :nxdomain}, {:ok, @pac_script}])
    start_tree!(iface)

    PropertyTable.put(VintageNet, properties.config, %{
      type: :fake,
      proxy: %{mode: :auto, pac_url: @pac_url}
    })

    wait_until(fn -> if calls.() >= 1, do: {:ok, :ok}, else: :error end)

    # Push a different URL through the config event — this should
    # invalidate the long retry timer and run a fresh fetch right away.
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
    calls = stub_fetcher([{:error, :nxdomain}])
    start_tree!(iface)

    PropertyTable.put(VintageNet, properties.config, %{type: :fake, proxy: %{mode: :direct}})

    _ = Interface.get(iface)
    Process.sleep(120)
    assert calls.() == 0
  end
end
