defmodule VintageNetProxy.PAC.IPPropertyTest do
  @moduledoc """
  Property-based tests for `VintageNetProxy.PAC.IP`.

  Subnet containment is bit-twiddling math where off-by-one errors
  silently misroute whole subnets. Example tests cover hand-picked
  boundaries; the properties here exercise the cross-product of
  random hosts, networks, and prefix lengths so a regression in the
  mask arithmetic shows up as a counterexample rather than a quietly
  wrong PAC decision in production.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias VintageNetProxy.PAC.IP

  # --- Generators ---

  defp octet, do: StreamData.integer(0..255)

  defp ipv4_string do
    gen all a <- octet(),
            b <- octet(),
            c <- octet(),
            d <- octet() do
      "#{a}.#{b}.#{c}.#{d}"
    end
  end

  # Prefix length in [0..32]; convert to a dotted-quad netmask string.
  defp netmask do
    gen all prefix <- StreamData.integer(0..32) do
      mask_int =
        if prefix == 0,
          do: 0,
          else: Bitwise.bsl(0xFFFFFFFF, 32 - prefix) |> Bitwise.band(0xFFFFFFFF)

      <<a, b, c, d>> = <<mask_int::32>>
      "#{a}.#{b}.#{c}.#{d}"
    end
  end

  # Anything: well-formed IPv4 literals, malformed strings, non-strings.
  defp garbage do
    StreamData.one_of([
      ipv4_string(),
      StreamData.string(:printable, max_length: 32),
      StreamData.constant(""),
      StreamData.constant(nil),
      StreamData.integer(),
      StreamData.atom(:alphanumeric)
    ])
  end

  # --- parse/1 ---

  property "parse/1 returns {:ok, n} with n in [0, 2^32) for any valid IPv4 string" do
    check all ip <- ipv4_string() do
      assert {:ok, n} = IP.parse(ip)
      assert is_integer(n)
      assert n >= 0 and n <= 0xFFFFFFFF
    end
  end

  property "parse/1 never raises for any input" do
    check all term <- garbage() do
      result = IP.parse(term)
      assert result == :error or match?({:ok, _}, result)
    end
  end

  # --- in_net?/3 invariants ---

  property "in_net?(host, host, 255.255.255.255) is true for any valid host (/32 identity)" do
    check all host <- ipv4_string() do
      assert IP.in_net?(host, host, "255.255.255.255")
    end
  end

  property "in_net?(host, 0.0.0.0, 0.0.0.0) is true for any valid host (/0 universal)" do
    check all host <- ipv4_string() do
      assert IP.in_net?(host, "0.0.0.0", "0.0.0.0")
    end
  end

  property "in_net? is symmetric in (host, network)" do
    check all a <- ipv4_string(),
              b <- ipv4_string(),
              mask <- netmask() do
      assert IP.in_net?(a, b, mask) == IP.in_net?(b, a, mask)
    end
  end

  property "hosts that share a masked prefix agree on membership in any network at that mask" do
    check all a <- ipv4_string(),
              b <- ipv4_string(),
              network <- ipv4_string(),
              mask <- netmask() do
      {:ok, ai} = IP.parse(a)
      {:ok, bi} = IP.parse(b)
      {:ok, mi} = IP.parse(mask)

      if Bitwise.band(ai, mi) == Bitwise.band(bi, mi) do
        assert IP.in_net?(a, network, mask) == IP.in_net?(b, network, mask)
      end
    end
  end

  property "in_net? never raises for any input combination" do
    check all host <- garbage(),
              network <- garbage(),
              mask <- garbage() do
      result = IP.in_net?(host, network, mask)
      assert result == true or result == false
    end
  end

  property "malformed host / network / mask all yield false" do
    check all garbage_str <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
              host <- ipv4_string(),
              network <- ipv4_string(),
              mask <- netmask() do
      # Guard against accidental valid IP-shaped strings from the
      # alphanumeric generator (extremely unlikely but cheap to skip).
      if match?(:error, IP.parse(garbage_str)) do
        refute IP.in_net?(garbage_str, network, mask)
        refute IP.in_net?(host, garbage_str, mask)
        refute IP.in_net?(host, network, garbage_str)
      end
    end
  end

  property "in_net? agrees with the bit-level definition" do
    check all host <- ipv4_string(),
              network <- ipv4_string(),
              mask <- netmask() do
      {:ok, h} = IP.parse(host)
      {:ok, n} = IP.parse(network)
      {:ok, m} = IP.parse(mask)

      expected = Bitwise.band(h, m) == Bitwise.band(n, m)
      assert IP.in_net?(host, network, mask) == expected
    end
  end
end
