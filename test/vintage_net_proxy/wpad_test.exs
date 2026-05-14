defmodule VintageNetProxy.WpadTest do
  use ExUnit.Case, async: true

  alias VintageNetProxy.Wpad

  describe "dns_url/1" do
    test "constructs http://wpad.<domain>/wpad.dat from a multi-label domain" do
      assert Wpad.dns_url("corp.example.com") == "http://wpad.corp.example.com/wpad.dat"
    end

    test "single-label domain works too" do
      assert Wpad.dns_url("corp") == "http://wpad.corp/wpad.dat"
    end

    test "strips a leading dot (DHCP search-list format)" do
      assert Wpad.dns_url(".corp.example.com") == "http://wpad.corp.example.com/wpad.dat"
    end

    test "strips a trailing dot (FQDN-with-root format)" do
      assert Wpad.dns_url("corp.example.com.") == "http://wpad.corp.example.com/wpad.dat"
    end

    test "trims surrounding whitespace" do
      assert Wpad.dns_url("  corp.example.com\n") == "http://wpad.corp.example.com/wpad.dat"
    end

    test "nil input → nil" do
      assert Wpad.dns_url(nil) == nil
    end

    test "empty string → nil" do
      assert Wpad.dns_url("") == nil
    end

    test "whitespace-only → nil" do
      assert Wpad.dns_url("   ") == nil
    end

    test "lone dot → nil (would construct http://wpad./wpad.dat)" do
      assert Wpad.dns_url(".") == nil
    end

    test "non-binary input → nil" do
      assert Wpad.dns_url(123) == nil
      assert Wpad.dns_url(:atom) == nil
    end

    test "rejects domains containing slashes (DHCP-injected URL guard)" do
      assert Wpad.dns_url("evil.com/../attacker.com") == nil
    end

    test "rejects domains containing whitespace" do
      assert Wpad.dns_url("evil example.com") == nil
    end

    test "rejects domains containing scheme separators" do
      assert Wpad.dns_url("http://evil.com") == nil
      assert Wpad.dns_url("evil.com:1234") == nil
    end

    test "rejects domains containing query/fragment characters" do
      assert Wpad.dns_url("evil.com?x=1") == nil
      assert Wpad.dns_url("evil.com#frag") == nil
    end

    test "allows hyphens (real-world hostnames have them)" do
      assert Wpad.dns_url("my-corp.example.com") == "http://wpad.my-corp.example.com/wpad.dat"
    end

    test "does NOT walk up the domain hierarchy (security)" do
      # Documenting the deliberate non-feature: passing a deep subdomain
      # produces exactly one URL, not one per ancestor.
      assert Wpad.dns_url("eng.corp.example.com") ==
               "http://wpad.eng.corp.example.com/wpad.dat"
    end
  end

  describe "from_dhcp_options/1" do
    test "extracts both option 252 (wpad) and option 15 (domain)" do
      assert Wpad.from_dhcp_options(%{wpad: "http://w/", domain: "corp.example.com"}) ==
               {"http://w/", "corp.example.com"}
    end

    test "missing wpad → nil in that slot" do
      assert Wpad.from_dhcp_options(%{domain: "corp.example.com"}) ==
               {nil, "corp.example.com"}
    end

    test "missing domain → nil in that slot" do
      assert Wpad.from_dhcp_options(%{wpad: "http://w/"}) == {"http://w/", nil}
    end

    test "empty strings are treated as missing" do
      assert Wpad.from_dhcp_options(%{wpad: "", domain: ""}) == {nil, nil}
    end

    test "non-binary values are treated as missing" do
      assert Wpad.from_dhcp_options(%{wpad: 123, domain: :corp}) == {nil, nil}
    end

    test "empty map → {nil, nil}" do
      assert Wpad.from_dhcp_options(%{}) == {nil, nil}
    end

    test "non-map input → {nil, nil}" do
      assert Wpad.from_dhcp_options(nil) == {nil, nil}
      assert Wpad.from_dhcp_options([]) == {nil, nil}
      assert Wpad.from_dhcp_options(:unknown) == {nil, nil}
    end
  end
end
