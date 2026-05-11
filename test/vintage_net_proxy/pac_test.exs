defmodule VintageNetProxy.PACTest do
  use ExUnit.Case, async: true

  alias VintageNetProxy.PAC

  describe "find_proxy/2 — directive parsing" do
    test "static DIRECT" do
      script = ~s|function FindProxyForURL(url, host) { return "DIRECT"; }|
      assert PAC.find_proxy(script, "https://example.com/") == :direct
    end

    test "static PROXY → :http descriptor" do
      script = ~s|function FindProxyForURL(url, host) { return "PROXY proxy.example:8080"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               %{scheme: :http, host: "proxy.example", port: 8080}
    end

    test "HTTPS directive" do
      script = ~s|function FindProxyForURL(url, host) { return "HTTPS secure.example:443"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               %{scheme: :https, host: "secure.example", port: 443}
    end

    test "SOCKS5 directive" do
      script = ~s|function FindProxyForURL(url, host) { return "SOCKS5 s.example:1080"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               %{scheme: :socks5, host: "s.example", port: 1080}
    end

    test "SOCKS without version → :socks4" do
      script = ~s|function FindProxyForURL(url, host) { return "SOCKS s4.example:1080"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               %{scheme: :socks4, host: "s4.example", port: 1080}
    end

    test "SOCKS4 explicit" do
      script = ~s|function FindProxyForURL(url, host) { return "SOCKS4 s.example:1080"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               %{scheme: :socks4, host: "s.example", port: 1080}
    end

    test "fallback list returns the first recognized entry" do
      script =
        ~s|function FindProxyForURL(url, host) { return "PROXY a.example:1; PROXY b.example:2; DIRECT"; }|

      assert PAC.find_proxy(script, "https://x.example/") ==
               %{scheme: :http, host: "a.example", port: 1}
    end

    test "fallback list mixed schemes — first one wins" do
      script = ~s|function FindProxyForURL(url, host) { return "SOCKS5 s:1080; PROXY p:8080"; }|

      assert PAC.find_proxy(script, "https://x/") ==
               %{scheme: :socks5, host: "s", port: 1080}
    end
  end

  describe "find_proxy/2 — shExpMatch" do
    setup do
      script = """
      function FindProxyForURL(url, host) {
        if (shExpMatch(host, "*.corp.example")) return "PROXY corp-proxy:8080";
        return "DIRECT";
      }
      """

      {:ok, script: script}
    end

    test "matches glob → returns the proxy", %{script: s} do
      assert PAC.find_proxy(s, "https://api.corp.example/path") ==
               %{scheme: :http, host: "corp-proxy", port: 8080}
    end

    test "non-match → falls through to default", %{script: s} do
      assert PAC.find_proxy(s, "https://google.com/") == :direct
    end
  end

  describe "find_proxy/2 — dnsDomainIs" do
    test "suffix match → proxy" do
      script = """
      function FindProxyForURL(url, host) {
        if (dnsDomainIs(host, ".internal.example")) return "PROXY p:3128";
        return "DIRECT";
      }
      """

      assert PAC.find_proxy(script, "https://x.internal.example/") ==
               %{scheme: :http, host: "p", port: 3128}

      assert PAC.find_proxy(script, "https://x.external.example/") == :direct
    end
  end

  describe "find_proxy/2 — isPlainHostName" do
    test "plain hostname (no dot) → direct" do
      script = """
      function FindProxyForURL(url, host) {
        if (isPlainHostName(host)) return "DIRECT";
        return "PROXY p:8080";
      }
      """

      assert PAC.find_proxy(script, "http://intranet/") == :direct

      assert PAC.find_proxy(script, "http://external.com/") ==
               %{scheme: :http, host: "p", port: 8080}
    end
  end

  describe "find_proxy/2 — chains" do
    test "first matching rule wins" do
      script = """
      function FindProxyForURL(url, host) {
        if (isPlainHostName(host)) return "DIRECT";
        if (shExpMatch(host, "*.corp.example")) return "PROXY corp:8080";
        if (dnsDomainIs(host, ".vpn.example")) return "SOCKS5 vpn:1080";
        return "PROXY default:80";
      }
      """

      assert PAC.find_proxy(script, "http://intranet/") == :direct

      assert PAC.find_proxy(script, "https://api.corp.example/") ==
               %{scheme: :http, host: "corp", port: 8080}

      assert PAC.find_proxy(script, "https://x.vpn.example/") ==
               %{scheme: :socks5, host: "vpn", port: 1080}

      assert PAC.find_proxy(script, "https://google.com/") ==
               %{scheme: :http, host: "default", port: 80}
    end
  end

  describe "find_proxy/2 — host equality" do
    test "host == literal" do
      script =
        ~s|function FindProxyForURL(url, host) { if (host == "intranet") return "DIRECT"; return "PROXY p:80"; }|

      assert PAC.find_proxy(script, "http://intranet/") == :direct

      assert PAC.find_proxy(script, "http://elsewhere/") ==
               %{scheme: :http, host: "p", port: 80}
    end
  end

  describe "find_proxy/2 — robustness" do
    test "empty script → direct" do
      assert PAC.find_proxy("", "http://x/") == :direct
    end

    test "malformed directive → direct" do
      script = ~s|function FindProxyForURL(url, host) { return "PROXY without_port"; }|
      assert PAC.find_proxy(script, "http://x/") == :direct
    end

    test "unsupported predicate → ignored, falls to default" do
      script = """
      function FindProxyForURL(url, host) {
        if (myIpAddress() == "10.0.0.1") return "PROXY weird:1";
        return "DIRECT";
      }
      """

      assert PAC.find_proxy(script, "http://x/") == :direct
    end

    test "unparseable URL → empty host, predicates miss" do
      script = """
      function FindProxyForURL(url, host) {
        if (shExpMatch(host, "*.corp.example")) return "PROXY p:1";
        return "DIRECT";
      }
      """

      assert PAC.find_proxy(script, "not-a-url") == :direct
    end
  end
end
