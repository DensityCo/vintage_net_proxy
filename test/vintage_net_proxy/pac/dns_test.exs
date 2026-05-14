defmodule VintageNetProxy.PAC.DNSTest do
  use ExUnit.Case, async: false

  alias VintageNetProxy.PAC.DNS

  describe "resolve/1 — without the cache GenServer running" do
    # These tests deliberately do *not* call start_supervised!({DNS, []}).
    # We're verifying the graceful no-table fallback so unit tests of
    # Predicate / PAC that don't start the supervision tree still work.

    test "IPv4 literal short-circuits and does not touch the cache" do
      assert DNS.resolve("10.1.2.3") == {:ok, "10.1.2.3"}
      assert DNS.resolve("192.168.0.1") == {:ok, "192.168.0.1"}
    end

    test "hostname without a running cache returns :error" do
      assert DNS.resolve("definitely-not-real.invalid") == :error
    end
  end

  describe "resolve/1 — with the cache GenServer running" do
    setup do
      start_supervised!(DNS)
      :ok
    end

    test "IPv4 literal still short-circuits" do
      assert DNS.resolve("10.0.0.1") == {:ok, "10.0.0.1"}
    end

    test "an unresolvable hostname returns :error and the result is cached" do
      # `.invalid` is reserved by RFC 2606 — guaranteed not to resolve.
      assert DNS.resolve("nonexistent.invalid") == :error

      # Verify the negative result is in the ETS table so the second call
      # is a cache hit rather than another DNS query.
      assert [{"nonexistent.invalid", :error, _expires_at}] =
               :ets.lookup(DNS, "nonexistent.invalid")
    end
  end
end
