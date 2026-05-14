defmodule VintageNetProxy.PACTest do
  use ExUnit.Case, async: true

  alias VintageNetProxy.PAC

  describe "find_proxy/2 — directive parsing" do
    test "static DIRECT comes from the script's default" do
      script = ~s|function FindProxyForURL(url, host) { return "DIRECT"; }|
      assert PAC.find_proxy(script, "https://example.com/") == {:default, :direct}
    end

    test "static PROXY → :http descriptor (default-sourced)" do
      script = ~s|function FindProxyForURL(url, host) { return "PROXY proxy.example:8080"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               {:default, %{scheme: :http, host: "proxy.example", port: 8080}}
    end

    test "HTTPS directive" do
      script = ~s|function FindProxyForURL(url, host) { return "HTTPS secure.example:443"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               {:default, %{scheme: :https, host: "secure.example", port: 443}}
    end

    test "SOCKS5 directive" do
      script = ~s|function FindProxyForURL(url, host) { return "SOCKS5 s.example:1080"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               {:default, %{scheme: :socks5, host: "s.example", port: 1080}}
    end

    test "SOCKS without version → :socks4" do
      script = ~s|function FindProxyForURL(url, host) { return "SOCKS s4.example:1080"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               {:default, %{scheme: :socks4, host: "s4.example", port: 1080}}
    end

    test "SOCKS4 explicit" do
      script = ~s|function FindProxyForURL(url, host) { return "SOCKS4 s.example:1080"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               {:default, %{scheme: :socks4, host: "s.example", port: 1080}}
    end

    test "fallback list returns the first recognized entry" do
      script =
        ~s|function FindProxyForURL(url, host) { return "PROXY a.example:1; PROXY b.example:2; DIRECT"; }|

      assert PAC.find_proxy(script, "https://x.example/") ==
               {:default, %{scheme: :http, host: "a.example", port: 1}}
    end

    test "fallback list mixed schemes — first one wins" do
      script = ~s|function FindProxyForURL(url, host) { return "SOCKS5 s:1080; PROXY p:8080"; }|

      assert PAC.find_proxy(script, "https://x/") ==
               {:default, %{scheme: :socks5, host: "s", port: 1080}}
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

    test "matches glob → :rule with the proxy", %{script: s} do
      assert PAC.find_proxy(s, "https://api.corp.example/path") ==
               {:rule, %{scheme: :http, host: "corp-proxy", port: 8080}}
    end

    test "non-match → falls through to default", %{script: s} do
      assert PAC.find_proxy(s, "https://google.com/") == {:default, :direct}
    end
  end

  describe "find_proxy/2 — dnsDomainIs" do
    test "suffix match → :rule" do
      script = """
      function FindProxyForURL(url, host) {
        if (dnsDomainIs(host, ".internal.example")) return "PROXY p:3128";
        return "DIRECT";
      }
      """

      assert PAC.find_proxy(script, "https://x.internal.example/") ==
               {:rule, %{scheme: :http, host: "p", port: 3128}}

      assert PAC.find_proxy(script, "https://x.external.example/") == {:default, :direct}
    end
  end

  describe "find_proxy/2 — isPlainHostName" do
    test "plain hostname (no dot) → rule fires" do
      script = """
      function FindProxyForURL(url, host) {
        if (isPlainHostName(host)) return "DIRECT";
        return "PROXY p:8080";
      }
      """

      assert PAC.find_proxy(script, "http://intranet/") == {:rule, :direct}

      assert PAC.find_proxy(script, "http://external.com/") ==
               {:default, %{scheme: :http, host: "p", port: 8080}}
    end
  end

  describe "find_proxy/2 — chains" do
    test "first matching rule wins; non-match falls to default" do
      script = """
      function FindProxyForURL(url, host) {
        if (isPlainHostName(host)) return "DIRECT";
        if (shExpMatch(host, "*.corp.example")) return "PROXY corp:8080";
        if (dnsDomainIs(host, ".vpn.example")) return "SOCKS5 vpn:1080";
        return "PROXY default:80";
      }
      """

      assert PAC.find_proxy(script, "http://intranet/") == {:rule, :direct}

      assert PAC.find_proxy(script, "https://api.corp.example/") ==
               {:rule, %{scheme: :http, host: "corp", port: 8080}}

      assert PAC.find_proxy(script, "https://x.vpn.example/") ==
               {:rule, %{scheme: :socks5, host: "vpn", port: 1080}}

      assert PAC.find_proxy(script, "https://google.com/") ==
               {:default, %{scheme: :http, host: "default", port: 80}}
    end
  end

  describe "find_proxy/2 — host equality" do
    test "host == literal" do
      script =
        ~s|function FindProxyForURL(url, host) { if (host == "intranet") return "DIRECT"; return "PROXY p:80"; }|

      assert PAC.find_proxy(script, "http://intranet/") == {:rule, :direct}

      assert PAC.find_proxy(script, "http://elsewhere/") ==
               {:default, %{scheme: :http, host: "p", port: 80}}
    end
  end

  describe "find_proxy/2 — representative enterprise WPAD" do
    @wpad """
    function FindProxyForURL(url, host) {
      if (isPlainHostName(host)) return "DIRECT";
      if (host == "localhost") return "DIRECT";
      if (dnsDomainIs(host, ".corp.example.com")) return "DIRECT";
      if (dnsDomainIs(host, ".internal.example.com")) return "DIRECT";
      if (shExpMatch(host, "*.s3.amazonaws.com")) return "DIRECT";
      if (dnsDomainIs(host, ".trusted-partner.com")) return "PROXY trusted-proxy:3128";
      return "PROXY primary-proxy:8080; PROXY backup-proxy:8080; DIRECT";
    }
    """

    test "plain hostnames bypass via :rule" do
      assert PAC.find_proxy(@wpad, "http://intranet/") == {:rule, :direct}
      assert PAC.find_proxy(@wpad, "http://buildserver/jobs") == {:rule, :direct}
    end

    test "loopback bypasses via :rule" do
      assert PAC.find_proxy(@wpad, "http://localhost:8080/") == {:rule, :direct}
    end

    test "internal corp domains bypass via :rule" do
      assert PAC.find_proxy(@wpad, "https://wiki.corp.example.com/") == {:rule, :direct}
      assert PAC.find_proxy(@wpad, "https://api.internal.example.com/v1/") == {:rule, :direct}
    end

    test "S3 buckets bypass via :rule" do
      assert PAC.find_proxy(@wpad, "https://my-bucket.s3.amazonaws.com/") == {:rule, :direct}
    end

    test "trusted-partner traffic gets a dedicated proxy via :rule" do
      assert PAC.find_proxy(@wpad, "https://api.trusted-partner.com/") ==
               {:rule, %{scheme: :http, host: "trusted-proxy", port: 3128}}
    end

    test "general internet traffic falls to the :default fallback list" do
      assert PAC.find_proxy(@wpad, "https://www.google.com/") ==
               {:default, %{scheme: :http, host: "primary-proxy", port: 8080}}

      assert PAC.find_proxy(@wpad, "https://github.com/") ==
               {:default, %{scheme: :http, host: "primary-proxy", port: 8080}}
    end

    test "rule precedence: first matching if wins" do
      assert PAC.find_proxy(@wpad, "https://api.corp.example.com/") == {:rule, :direct}
      assert PAC.find_proxy(@wpad, "https://logs.s3.amazonaws.com/") == {:rule, :direct}
    end
  end

  describe "find_proxy/2 — boolean composition in predicates" do
    test "Mozilla-style compound bypass with || and isInNet" do
      script = """
      function FindProxyForURL(url, host) {
        if (isPlainHostName(host) ||
            dnsDomainIs(host, ".mozilla.org") ||
            isInNet(host, "10.0.0.0", "255.0.0.0"))
          return "DIRECT";
        return "PROXY proxy.mozilla.org:8080";
      }
      """

      assert PAC.find_proxy(script, "http://intranet/") == {:rule, :direct}
      assert PAC.find_proxy(script, "https://wiki.mozilla.org/") == {:rule, :direct}
      assert PAC.find_proxy(script, "http://10.1.2.3/") == {:rule, :direct}

      assert PAC.find_proxy(script, "https://github.com/") ==
               {:default, %{scheme: :http, host: "proxy.mozilla.org", port: 8080}}
    end

    test "&& with negation" do
      script = """
      function FindProxyForURL(url, host) {
        if (dnsDomainIs(host, ".corp") && !shExpMatch(host, "internal.*"))
          return "PROXY corp-proxy:8080";
        return "DIRECT";
      }
      """

      assert PAC.find_proxy(script, "http://api.corp/") ==
               {:rule, %{scheme: :http, host: "corp-proxy", port: 8080}}

      # internal.* hosts negate the corp rule, fall through to default
      assert PAC.find_proxy(script, "http://internal.corp/") == {:default, :direct}

      # non-corp host doesn't even reach the rule
      assert PAC.find_proxy(script, "http://github.com/") == {:default, :direct}
    end
  end

  describe "find_proxy/2 — JS comments" do
    test "inline line comment between predicate and return is stripped" do
      script = """
      function FindProxyForURL(url, host) {
        if (isPlainHostName(host))  // bypass intranet hosts
          return "DIRECT";
        return "PROXY p:8080";
      }
      """

      assert PAC.find_proxy(script, "http://intranet/") == {:rule, :direct}

      assert PAC.find_proxy(script, "http://google.com/") ==
               {:default, %{scheme: :http, host: "p", port: 8080}}
    end

    test "inline block comment between predicate and return is stripped" do
      script = """
      function FindProxyForURL(url, host) {
        if (isPlainHostName(host)) /* bypass */ return "DIRECT";
        return "PROXY p:8080";
      }
      """

      assert PAC.find_proxy(script, "http://intranet/") == {:rule, :direct}
    end

    test "multi-line block comment is stripped" do
      script = """
      function FindProxyForURL(url, host) {
        /* This file is auto-generated.
         * Do not edit by hand. */
        if (isPlainHostName(host)) return "DIRECT";
        return "PROXY p:8080";
      }
      """

      assert PAC.find_proxy(script, "http://intranet/") == {:rule, :direct}

      assert PAC.find_proxy(script, "http://google.com/") ==
               {:default, %{scheme: :http, host: "p", port: 8080}}
    end

    test "comments scattered through a realistic WPAD don't break rule chaining" do
      script = """
      // PAC file for ACME Corp
      // Last updated: 2026-05
      function FindProxyForURL(url, host) {
        // Bypass internal traffic
        if (isPlainHostName(host)) return "DIRECT";
        if (dnsDomainIs(host, ".corp.acme")) return "DIRECT"; // intranet
        // Everything else
        return "PROXY proxy.acme:8080";
      }
      """

      assert PAC.find_proxy(script, "http://intranet/") == {:rule, :direct}
      assert PAC.find_proxy(script, "https://wiki.corp.acme/") == {:rule, :direct}

      assert PAC.find_proxy(script, "https://github.com/") ==
               {:default, %{scheme: :http, host: "proxy.acme", port: 8080}}
    end

    test "line comment does not eat into the next rule" do
      script = """
      function FindProxyForURL(url, host) {
        if (host == "a") return "DIRECT"; // first rule
        if (host == "b") return "PROXY p:80";
        return "PROXY q:90";
      }
      """

      assert PAC.find_proxy(script, "http://a/") == {:rule, :direct}

      assert PAC.find_proxy(script, "http://b/") ==
               {:rule, %{scheme: :http, host: "p", port: 80}}

      assert PAC.find_proxy(script, "http://c/") ==
               {:default, %{scheme: :http, host: "q", port: 90}}
    end

    test "comment-only script falls through (no rules, no default)" do
      assert PAC.find_proxy("// just a header\n/* nothing here */", "http://x/") ==
               {:fallthrough, :direct}
    end
  end

  describe "find_proxy/2 — robustness" do
    test "empty script → :fallthrough (no rules, no default)" do
      assert PAC.find_proxy("", "http://x/") == {:fallthrough, :direct}
    end

    test "malformed directive → :default :direct (parser collapses unparseable to direct)" do
      script = ~s|function FindProxyForURL(url, host) { return "PROXY without_port"; }|
      assert PAC.find_proxy(script, "http://x/") == {:default, :direct}
    end

    test "unsupported predicate → ignored, falls to default" do
      script = """
      function FindProxyForURL(url, host) {
        if (myIpAddress() == "10.0.0.1") return "PROXY weird:1";
        return "DIRECT";
      }
      """

      assert PAC.find_proxy(script, "http://x/") == {:default, :direct}
    end

    test "unparseable URL → empty host, predicates miss, falls to default" do
      script = """
      function FindProxyForURL(url, host) {
        if (shExpMatch(host, "*.corp.example")) return "PROXY p:1";
        return "DIRECT";
      }
      """

      assert PAC.find_proxy(script, "not-a-url") == {:default, :direct}
    end
  end
end
