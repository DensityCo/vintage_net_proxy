defmodule VintageNetProxy.PAC.IPTest do
  use ExUnit.Case, async: true

  alias VintageNetProxy.PAC.IP

  describe "parse/1" do
    test "valid dotted quads" do
      assert {:ok, 0} = IP.parse("0.0.0.0")
      assert {:ok, 0xFFFFFFFF} = IP.parse("255.255.255.255")
      assert {:ok, 0x0A000001} = IP.parse("10.0.0.1")
      assert {:ok, 0xC0A80001} = IP.parse("192.168.0.1")
    end

    test "rejects wrong number of octets" do
      assert :error = IP.parse("10.0.0")
      assert :error = IP.parse("10.0.0.0.0")
      assert :error = IP.parse("")
    end

    test "rejects out-of-range octets" do
      assert :error = IP.parse("256.0.0.0")
      assert :error = IP.parse("-1.0.0.0")
    end

    test "rejects non-numeric octets" do
      assert :error = IP.parse("a.b.c.d")
      assert :error = IP.parse("10.0.0.x")
      assert :error = IP.parse("10..0.1")
    end

    test "rejects non-binary input" do
      assert :error = IP.parse(nil)
      assert :error = IP.parse(123)
    end
  end

  describe "in_net?/3" do
    test "host inside a /8 network" do
      assert IP.in_net?("10.0.0.1", "10.0.0.0", "255.0.0.0")
      assert IP.in_net?("10.255.255.255", "10.0.0.0", "255.0.0.0")
    end

    test "host outside the network" do
      refute IP.in_net?("11.0.0.1", "10.0.0.0", "255.0.0.0")
      refute IP.in_net?("192.168.1.1", "10.0.0.0", "255.0.0.0")
    end

    test "/24 boundary" do
      assert IP.in_net?("192.168.1.0", "192.168.1.0", "255.255.255.0")
      assert IP.in_net?("192.168.1.255", "192.168.1.0", "255.255.255.0")
      refute IP.in_net?("192.168.2.0", "192.168.1.0", "255.255.255.0")
    end

    test "/0 matches everything" do
      assert IP.in_net?("1.2.3.4", "0.0.0.0", "0.0.0.0")
      assert IP.in_net?("255.255.255.255", "0.0.0.0", "0.0.0.0")
    end

    test "/32 matches only the exact host" do
      assert IP.in_net?("10.0.0.1", "10.0.0.1", "255.255.255.255")
      refute IP.in_net?("10.0.0.2", "10.0.0.1", "255.255.255.255")
    end

    test "non-literal host returns false (no DNS)" do
      refute IP.in_net?("intranet", "10.0.0.0", "255.0.0.0")
      refute IP.in_net?("foo.example.com", "10.0.0.0", "255.0.0.0")
    end

    test "malformed network or mask returns false" do
      refute IP.in_net?("10.0.0.1", "bogus", "255.0.0.0")
      refute IP.in_net?("10.0.0.1", "10.0.0.0", "bogus")
    end
  end
end
