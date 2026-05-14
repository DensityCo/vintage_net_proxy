defmodule VintageNetProxy.AddressesTest do
  use ExUnit.Case, async: true

  alias VintageNetProxy.Addresses

  describe "first_ipv4/1" do
    test "extracts the first IPv4 entry as a dotted-quad string" do
      addrs = [%{family: :inet, address: {10, 1, 2, 3}}]
      assert Addresses.first_ipv4(addrs) == "10.1.2.3"
    end

    test "skips IPv6 entries and returns the first IPv4 found" do
      addrs = [
        %{family: :inet6, address: {0, 0, 0, 0, 0, 0, 0, 1}},
        %{family: :inet, address: {192, 168, 1, 5}}
      ]

      assert Addresses.first_ipv4(addrs) == "192.168.1.5"
    end

    test "returns the first IPv4 when multiple are present" do
      addrs = [
        %{family: :inet, address: {10, 0, 0, 1}},
        %{family: :inet, address: {10, 0, 0, 2}}
      ]

      assert Addresses.first_ipv4(addrs) == "10.0.0.1"
    end

    test "nil when no IPv4 entries are present" do
      addrs = [%{family: :inet6, address: {0, 0, 0, 0, 0, 0, 0, 1}}]
      assert Addresses.first_ipv4(addrs) == nil
    end

    test "nil for an empty list" do
      assert Addresses.first_ipv4([]) == nil
    end

    test "nil for non-list input" do
      assert Addresses.first_ipv4(nil) == nil
      assert Addresses.first_ipv4(%{}) == nil
      assert Addresses.first_ipv4(:unknown) == nil
    end

    test "skips entries that don't match the expected shape" do
      addrs = [
        %{family: :inet, address: "not-a-tuple"},
        %{family: :inet, address: {172, 16, 0, 1}}
      ]

      assert Addresses.first_ipv4(addrs) == "172.16.0.1"
    end
  end
end
