defmodule VintageNetProxy.RosterPropertyTest do
  @moduledoc """
  Property-based tests for `VintageNetProxy.Roster`.

  Roster picks the active interface — the highest-priority eligible
  proxy — and surfaces its value. The single invariant that matters:
  `active` is the first interface in the priority list whose proxy
  is eligible, or nil if none are. Properties below pin that down
  across random priority lists and random per-interface proxy states.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias VintageNetProxy.Interface.Proxy
  alias VintageNetProxy.{Roster, TestGenerators}

  # --- Generators ---

  defp iface_names_gen do
    StreamData.list_of(
      StreamData.string(:alphanumeric, min_length: 2, max_length: 8),
      min_length: 1,
      max_length: 4
    )
    |> StreamData.map(&Enum.uniq/1)
    |> StreamData.filter(&(&1 != []))
  end

  defp roster_gen do
    gen all(
          interfaces <- iface_names_gen(),
          proxies_by_iface <-
            StreamData.fixed_map(
              Map.new(interfaces, fn iface -> {iface, TestGenerators.proxy(iface)} end)
            )
        ) do
      Roster.new(interfaces, proxies_by_iface)
    end
  end

  # Same shape as `roster_gen` but lets some interfaces in the
  # priority list have no stored proxy yet (simulating fresh boot
  # before each Interface has pushed).
  defp partial_roster_gen do
    gen all(
          interfaces <- iface_names_gen(),
          stored <- StreamData.list_of(StreamData.boolean(), length: length(interfaces)),
          proxies <-
            StreamData.fixed_list(
              Enum.map(interfaces, fn iface -> TestGenerators.proxy(iface) end)
            )
        ) do
      states =
        interfaces
        |> Enum.zip(Enum.zip(stored, proxies))
        |> Enum.flat_map(fn
          {iface, {true, proxy}} -> [{iface, proxy}]
          {_iface, {false, _proxy}} -> []
        end)
        |> Map.new()

      Roster.new(interfaces, states)
    end
  end

  defp first_eligible(roster) do
    Enum.find_value(roster.interfaces, fn iface ->
      case Map.get(roster.states, iface) do
        %Proxy{} = p -> if Proxy.eligible?(p), do: {iface, p}
        _ -> nil
      end
    end)
  end

  # --- Properties ---

  property "value/1 is :unset iff no interface has an eligible proxy" do
    check all(roster <- partial_roster_gen()) do
      eligible_any? =
        Enum.any?(roster.interfaces, fn iface ->
          case Map.get(roster.states, iface) do
            %Proxy{} = p -> Proxy.eligible?(p)
            _ -> false
          end
        end)

      if eligible_any? do
        refute Roster.value(roster) == :unset
      else
        assert Roster.value(roster) == :unset
      end
    end
  end

  property "value/1 mirrors Proxy.value/1 of the first-eligible interface" do
    check all(roster <- partial_roster_gen()) do
      case first_eligible(roster) do
        nil -> assert Roster.value(roster) == :unset
        {_iface, proxy} -> assert Roster.value(roster) == Proxy.value(proxy)
      end
    end
  end

  property "status/2 active_iface points at the first-eligible interface" do
    check all(
            roster <- partial_roster_gen(),
            published <- StreamData.constant(:unset)
          ) do
      status = Roster.status(roster, published)

      case first_eligible(roster) do
        nil -> assert status.active_iface == nil
        {iface, _proxy} -> assert status.active_iface == iface
      end
    end
  end

  property "every interface preceding the active one is non-eligible (or missing)" do
    check all(roster <- partial_roster_gen()) do
      case first_eligible(roster) do
        nil ->
          :ok

        {active_iface, _} ->
          predecessors = Enum.take_while(roster.interfaces, &(&1 != active_iface))

          for iface <- predecessors do
            case Map.get(roster.states, iface) do
              nil -> :ok
              %Proxy{} = p -> refute Proxy.eligible?(p)
            end
          end
      end
    end
  end

  # --- put_iface invariants ---

  property "put_iface for an iface NOT in the priority list is a no-op" do
    check all(
            roster <- roster_gen(),
            stranger <- StreamData.string(:alphanumeric, min_length: 9, max_length: 16),
            proxy <- TestGenerators.proxy(stranger)
          ) do
      # Filter out the rare collision where the stranger name actually
      # exists in the roster.
      if stranger not in roster.interfaces do
        assert Roster.put_iface(roster, stranger, proxy) == roster
      end
    end
  end

  property "put_iface for an iface IN the priority list stores the proxy" do
    check all(
            roster <- roster_gen(),
            new_proxy_seed <- TestGenerators.proxy()
          ) do
      iface = hd(roster.interfaces)
      new_proxy = %{new_proxy_seed | iface: iface}
      updated = Roster.put_iface(roster, iface, new_proxy)
      assert Roster.get_iface(updated, iface) == new_proxy
    end
  end

  property "put_iface is idempotent for repeated identical writes" do
    check all(
            roster <- roster_gen(),
            new_proxy_seed <- TestGenerators.proxy()
          ) do
      iface = hd(roster.interfaces)
      new_proxy = %{new_proxy_seed | iface: iface}
      once = Roster.put_iface(roster, iface, new_proxy)
      twice = Roster.put_iface(once, iface, new_proxy)
      assert once == twice
    end
  end
end
