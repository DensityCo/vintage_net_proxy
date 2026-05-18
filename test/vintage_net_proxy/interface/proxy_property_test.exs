defmodule VintageNetProxy.Interface.ProxyPropertyTest do
  @moduledoc """
  Property-based tests for the pure predicates in
  `VintageNetProxy.Interface.Proxy`.

  `fetch_target/1`, `value/1`, `eligible?/1`, and `transition/2` are
  the foundation of retry scheduling, interface selection, and the
  published proxy value. Example-based tests check each one in
  isolation; the properties here check they stay *mutually
  consistent* across the full cross-product of proxy state shapes —
  every combination of intent mode, connection state, URL source,
  and cache state.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias VintageNetProxy.Interface.Proxy
  alias VintageNetProxy.TestGenerators, as: Gen
  alias VintageNetProxy.Wpad

  @up_states Gen.up_states()

  # --- fetch_target / effective_pac_url consistency ---

  property "fetch_target == :none iff (script cached OR no effective URL)" do
    check all(proxy <- Gen.proxy()) do
      script_cached? = is_binary(proxy.pac_script)
      url_available? = not is_nil(Proxy.effective_pac_url(proxy))

      case Proxy.fetch_target(proxy) do
        :none ->
          assert script_cached? or not url_available?

        {:ok, url} ->
          refute script_cached?
          assert url_available?
          assert url == Proxy.effective_pac_url(proxy)
      end
    end
  end

  property "caching a script makes fetch_target == :none" do
    check all(
            proxy <- Gen.proxy(),
            script <- Gen.pac_script()
          ) do
      assert proxy |> Proxy.cache_script(script) |> Proxy.fetch_target() == :none
    end
  end

  property "effective_pac_url is nil whenever connection is not up" do
    check all(proxy <- Gen.proxy()) do
      if proxy.connection not in @up_states do
        assert Proxy.effective_pac_url(proxy) == nil
      end
    end
  end

  property "effective_pac_url precedence: intent.pac_url > dhcp_wpad_url > dhcp_domain" do
    check all(
            connection <- StreamData.member_of(@up_states),
            pac_url <- Gen.pac_url(),
            dhcp_wpad <- Gen.pac_url(),
            dhcp_domain <- Gen.host()
          ) do
      base = %Proxy{
        iface: "test0",
        connection: connection,
        intent: %{mode: :auto, pac_url: pac_url},
        dhcp_wpad_url: dhcp_wpad,
        dhcp_domain: dhcp_domain
      }

      assert Proxy.effective_pac_url(base) == pac_url

      without_pac_url = %{base | intent: %{mode: :auto}}
      assert Proxy.effective_pac_url(without_pac_url) == dhcp_wpad

      without_either = %{without_pac_url | dhcp_wpad_url: nil}
      assert Proxy.effective_pac_url(without_either) == Wpad.dns_url(dhcp_domain)
    end
  end

  # --- value consistency ---

  property "value/1 returns a value from the documented enumeration" do
    check all(proxy <- Gen.proxy()) do
      assert Proxy.value(proxy) in [:unset, :direct, {:auto, :ready}, {:auto, :no_pac}] or
               match?({:manual, %{scheme: _, host: _, port: _}}, Proxy.value(proxy))
    end
  end

  property "value == {:auto, :ready} requires a cached pac_script" do
    check all(proxy <- Gen.proxy()) do
      if Proxy.value(proxy) == {:auto, :ready} do
        assert is_binary(proxy.pac_script)
        assert match?(%{mode: :auto}, proxy.intent)
      end
    end
  end

  property "value == :unset requires no intent" do
    check all(proxy <- Gen.proxy()) do
      if Proxy.value(proxy) == :unset do
        assert proxy.intent == nil
      end
    end
  end

  property "direct and manual modes never need a PAC fetch" do
    check all(proxy <- Gen.proxy()) do
      case Proxy.value(proxy) do
        :direct -> assert Proxy.fetch_target(proxy) == :none
        {:manual, _} -> assert Proxy.fetch_target(proxy) == :none
        _ -> :ok
      end
    end
  end

  # --- eligible? consistency ---

  property "eligible? iff intent present AND connection is up" do
    check all(proxy <- Gen.proxy()) do
      expected = not is_nil(proxy.intent) and proxy.connection in @up_states
      assert Proxy.eligible?(proxy) == expected
    end
  end

  property "eligible? implies value is not :unset" do
    check all(proxy <- Gen.proxy()) do
      if Proxy.eligible?(proxy) do
        refute Proxy.value(proxy) == :unset
      end
    end
  end

  # --- transition invariants ---

  property "transition with an identity change_fn preserves pac_script" do
    check all(proxy <- Gen.proxy()) do
      assert Proxy.transition(proxy, & &1).pac_script == proxy.pac_script
    end
  end

  property "transition clears pac_script iff effective URL changed" do
    check all(
            proxy <- Gen.proxy(),
            new_intent <- Gen.intent(),
            new_connection <- Gen.connection()
          ) do
      change_fn = fn p -> %{p | intent: new_intent, connection: new_connection} end
      old_url = Proxy.effective_pac_url(proxy)
      transitioned = Proxy.transition(proxy, change_fn)
      new_url = Proxy.effective_pac_url(transitioned)

      if old_url == new_url do
        assert transitioned.pac_script == proxy.pac_script
      else
        assert transitioned.pac_script == nil
      end
    end
  end

  # --- refresh_cache invariants ---

  property "refresh_cache with an error fetcher leaves the proxy unchanged" do
    check all(proxy <- Gen.proxy()) do
      fetcher = fn _url -> {:error, :nope} end
      assert Proxy.refresh_cache(proxy, fetcher) == proxy
    end
  end

  property "refresh_cache with a successful fetcher caches the script iff a fetch was owed" do
    check all(
            proxy <- Gen.proxy(),
            script <- Gen.pac_script()
          ) do
      fetcher = fn _url -> {:ok, script} end
      result = Proxy.refresh_cache(proxy, fetcher)

      case Proxy.fetch_target(proxy) do
        :none -> assert result == proxy
        {:ok, _url} -> assert result.pac_script == script
      end
    end
  end

  property "refresh_cache never calls fetcher when no fetch is owed" do
    check all(proxy <- Gen.proxy()) do
      fetcher = fn _url -> flunk("fetcher should not have been called") end

      if Proxy.fetch_target(proxy) == :none do
        assert Proxy.refresh_cache(proxy, fetcher) == proxy
      end
    end
  end
end
