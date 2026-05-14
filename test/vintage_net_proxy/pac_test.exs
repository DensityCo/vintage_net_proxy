defmodule VintageNetProxy.PACTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias VintageNetProxy.PAC

  describe "find_proxy/2 — directive parsing" do
    test "static DIRECT" do
      script = ~s|function FindProxyForURL(url, host) { return "DIRECT"; }|
      assert PAC.find_proxy(script, "https://example.com/") == {:ok, :direct}
    end

    test "static PROXY → :http descriptor" do
      script = ~s|function FindProxyForURL(url, host) { return "PROXY proxy.example:8080"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               {:ok, %{scheme: :http, host: "proxy.example", port: 8080}}
    end

    test "HTTPS directive" do
      script = ~s|function FindProxyForURL(url, host) { return "HTTPS secure.example:443"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               {:ok, %{scheme: :https, host: "secure.example", port: 443}}
    end

    test "SOCKS5 directive" do
      script = ~s|function FindProxyForURL(url, host) { return "SOCKS5 s.example:1080"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               {:ok, %{scheme: :socks5, host: "s.example", port: 1080}}
    end

    test "SOCKS without version → :socks4" do
      script = ~s|function FindProxyForURL(url, host) { return "SOCKS s4.example:1080"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               {:ok, %{scheme: :socks4, host: "s4.example", port: 1080}}
    end

    test "SOCKS4 explicit" do
      script = ~s|function FindProxyForURL(url, host) { return "SOCKS4 s.example:1080"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               {:ok, %{scheme: :socks4, host: "s.example", port: 1080}}
    end

    test "fallback list returns the first recognized entry" do
      script =
        ~s|function FindProxyForURL(url, host) { return "PROXY a.example:1; PROXY b.example:2; DIRECT"; }|

      assert PAC.find_proxy(script, "https://x.example/") ==
               {:ok, %{scheme: :http, host: "a.example", port: 1}}
    end

    test "fallback list mixed schemes — first one wins" do
      script = ~s|function FindProxyForURL(url, host) { return "SOCKS5 s:1080; PROXY p:8080"; }|

      assert PAC.find_proxy(script, "https://x/") ==
               {:ok, %{scheme: :socks5, host: "s", port: 1080}}
    end

    test "HTTP host:port — alias for PROXY → :http descriptor" do
      script = ~s|function FindProxyForURL(url, host) { return "HTTP proxy.example:8080"; }|

      assert PAC.find_proxy(script, "https://example.com/") ==
               {:ok, %{scheme: :http, host: "proxy.example", port: 8080}}
    end
  end

  describe "find_proxy/2 — URL-based shExpMatch" do
    test "matches an HTTPS-only rule based on URL prefix" do
      script = """
      function FindProxyForURL(url, host) {
        if (shExpMatch(url, "https://*")) return "PROXY secure-proxy:443";
        return "PROXY plain-proxy:80";
      }
      """

      assert PAC.find_proxy(script, "https://api.example.com/") ==
               {:ok, %{scheme: :http, host: "secure-proxy", port: 443}}

      assert PAC.find_proxy(script, "http://api.example.com/") ==
               {:ok, %{scheme: :http, host: "plain-proxy", port: 80}}
    end

    test "url and host variants can compose" do
      script = """
      function FindProxyForURL(url, host) {
        if (shExpMatch(url, "*/internal/*") && dnsDomainIs(host, ".corp.example"))
          return "DIRECT";
        return "PROXY p:8080";
      }
      """

      assert PAC.find_proxy(script, "https://app.corp.example/internal/admin") ==
               {:ok, :direct}

      assert PAC.find_proxy(script, "https://app.corp.example/public") ==
               {:ok, %{scheme: :http, host: "p", port: 8080}}
    end
  end

  describe "find_proxy/2 — localHostOrDomainIs" do
    setup do
      script = """
      function FindProxyForURL(url, host) {
        if (localHostOrDomainIs(host, "intranet.corp.example")) return "DIRECT";
        return "PROXY p:8080";
      }
      """

      {:ok, script: script}
    end

    test "fully-qualified host matches", %{script: s} do
      assert PAC.find_proxy(s, "https://intranet.corp.example/") == {:ok, :direct}
    end

    test "unqualified short name matches the first segment", %{script: s} do
      assert PAC.find_proxy(s, "http://intranet/") == {:ok, :direct}
    end

    test "different fully-qualified host falls through", %{script: s} do
      assert PAC.find_proxy(s, "https://home.corp.example/") ==
               {:ok, %{scheme: :http, host: "p", port: 8080}}
    end

    test "different unqualified host falls through", %{script: s} do
      assert PAC.find_proxy(s, "http://wiki/") ==
               {:ok, %{scheme: :http, host: "p", port: 8080}}
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

    test "matches glob → the proxy", %{script: s} do
      assert PAC.find_proxy(s, "https://api.corp.example/path") ==
               {:ok, %{scheme: :http, host: "corp-proxy", port: 8080}}
    end

    test "non-match → falls through to default", %{script: s} do
      assert PAC.find_proxy(s, "https://google.com/") == {:ok, :direct}
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
               {:ok, %{scheme: :http, host: "p", port: 3128}}

      assert PAC.find_proxy(script, "https://x.external.example/") == {:ok, :direct}
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

      assert PAC.find_proxy(script, "http://intranet/") == {:ok, :direct}

      assert PAC.find_proxy(script, "http://external.com/") ==
               {:ok, %{scheme: :http, host: "p", port: 8080}}
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

      assert PAC.find_proxy(script, "http://intranet/") == {:ok, :direct}

      assert PAC.find_proxy(script, "https://api.corp.example/") ==
               {:ok, %{scheme: :http, host: "corp", port: 8080}}

      assert PAC.find_proxy(script, "https://x.vpn.example/") ==
               {:ok, %{scheme: :socks5, host: "vpn", port: 1080}}

      assert PAC.find_proxy(script, "https://google.com/") ==
               {:ok, %{scheme: :http, host: "default", port: 80}}
    end
  end

  describe "find_proxy/2 — host equality" do
    test "host == literal" do
      script =
        ~s|function FindProxyForURL(url, host) { if (host == "intranet") return "DIRECT"; return "PROXY p:80"; }|

      assert PAC.find_proxy(script, "http://intranet/") == {:ok, :direct}

      assert PAC.find_proxy(script, "http://elsewhere/") ==
               {:ok, %{scheme: :http, host: "p", port: 80}}
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

    test "plain hostnames bypass" do
      assert PAC.find_proxy(@wpad, "http://intranet/") == {:ok, :direct}
      assert PAC.find_proxy(@wpad, "http://buildserver/jobs") == {:ok, :direct}
    end

    test "loopback bypasses" do
      assert PAC.find_proxy(@wpad, "http://localhost:8080/") == {:ok, :direct}
    end

    test "internal corp domains bypass" do
      assert PAC.find_proxy(@wpad, "https://wiki.corp.example.com/") == {:ok, :direct}
      assert PAC.find_proxy(@wpad, "https://api.internal.example.com/v1/") == {:ok, :direct}
    end

    test "S3 buckets bypass" do
      assert PAC.find_proxy(@wpad, "https://my-bucket.s3.amazonaws.com/") == {:ok, :direct}
    end

    test "trusted-partner traffic gets a dedicated proxy" do
      assert PAC.find_proxy(@wpad, "https://api.trusted-partner.com/") ==
               {:ok, %{scheme: :http, host: "trusted-proxy", port: 3128}}
    end

    test "general internet traffic falls to the default fallback list" do
      assert PAC.find_proxy(@wpad, "https://www.google.com/") ==
               {:ok, %{scheme: :http, host: "primary-proxy", port: 8080}}

      assert PAC.find_proxy(@wpad, "https://github.com/") ==
               {:ok, %{scheme: :http, host: "primary-proxy", port: 8080}}
    end

    test "rule precedence: first matching if wins" do
      assert PAC.find_proxy(@wpad, "https://api.corp.example.com/") == {:ok, :direct}
      assert PAC.find_proxy(@wpad, "https://logs.s3.amazonaws.com/") == {:ok, :direct}
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

      assert PAC.find_proxy(script, "http://intranet/") == {:ok, :direct}
      assert PAC.find_proxy(script, "https://wiki.mozilla.org/") == {:ok, :direct}
      assert PAC.find_proxy(script, "http://10.1.2.3/") == {:ok, :direct}

      assert PAC.find_proxy(script, "https://github.com/") ==
               {:ok, %{scheme: :http, host: "proxy.mozilla.org", port: 8080}}
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
               {:ok, %{scheme: :http, host: "corp-proxy", port: 8080}}

      # internal.* hosts negate the corp rule, fall through to default
      assert PAC.find_proxy(script, "http://internal.corp/") == {:ok, :direct}

      # non-corp host doesn't even reach the rule
      assert PAC.find_proxy(script, "http://github.com/") == {:ok, :direct}
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

      assert PAC.find_proxy(script, "http://intranet/") == {:ok, :direct}

      assert PAC.find_proxy(script, "http://google.com/") ==
               {:ok, %{scheme: :http, host: "p", port: 8080}}
    end

    test "inline block comment between predicate and return is stripped" do
      script = """
      function FindProxyForURL(url, host) {
        if (isPlainHostName(host)) /* bypass */ return "DIRECT";
        return "PROXY p:8080";
      }
      """

      assert PAC.find_proxy(script, "http://intranet/") == {:ok, :direct}
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

      assert PAC.find_proxy(script, "http://intranet/") == {:ok, :direct}

      assert PAC.find_proxy(script, "http://google.com/") ==
               {:ok, %{scheme: :http, host: "p", port: 8080}}
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

      assert PAC.find_proxy(script, "http://intranet/") == {:ok, :direct}
      assert PAC.find_proxy(script, "https://wiki.corp.acme/") == {:ok, :direct}

      assert PAC.find_proxy(script, "https://github.com/") ==
               {:ok, %{scheme: :http, host: "proxy.acme", port: 8080}}
    end

    test "line comment does not eat into the next rule" do
      script = """
      function FindProxyForURL(url, host) {
        if (host == "a") return "DIRECT"; // first rule
        if (host == "b") return "PROXY p:80";
        return "PROXY q:90";
      }
      """

      assert PAC.find_proxy(script, "http://a/") == {:ok, :direct}

      assert PAC.find_proxy(script, "http://b/") ==
               {:ok, %{scheme: :http, host: "p", port: 80}}

      assert PAC.find_proxy(script, "http://c/") ==
               {:ok, %{scheme: :http, host: "q", port: 90}}
    end

    test "comment-only script falls through" do
      log =
        capture_log([level: :warning], fn ->
          assert PAC.find_proxy("// just a header\n/* nothing here */", "http://x/") ==
                   {:error, :pac_fallthrough}
        end)

      assert log =~ "no rules and no default matched"
      assert log =~ "http://x/"
    end
  end

  describe "find_proxy/2 — robustness" do
    test "empty script → {:error, :pac_fallthrough} and logs at :warning" do
      log =
        capture_log([level: :warning], fn ->
          assert PAC.find_proxy("", "http://x/") == {:error, :pac_fallthrough}
        end)

      assert log =~ "no rules and no default matched"
      assert log =~ "http://x/"
    end

    test "malformed default directive parses to :direct → still {:ok, :direct}" do
      # `PROXY without_port` is unparseable; parse_directive collapses to :direct.
      # PAC still treats this as a default that fired; it doesn't reach :pac_fallthrough.
      script = ~s|function FindProxyForURL(url, host) { return "PROXY without_port"; }|
      assert PAC.find_proxy(script, "http://x/") == {:ok, :direct}
    end

    test "unsupported predicate → ignored; falls to default" do
      script = """
      function FindProxyForURL(url, host) {
        if (myIpAddress() == "10.0.0.1") return "PROXY weird:1";
        return "DIRECT";
      }
      """

      assert PAC.find_proxy(script, "http://x/") == {:ok, :direct}
    end

    test "unparseable URL → empty host, predicates miss, falls to default" do
      script = """
      function FindProxyForURL(url, host) {
        if (shExpMatch(host, "*.corp.example")) return "PROXY p:1";
        return "DIRECT";
      }
      """

      assert PAC.find_proxy(script, "not-a-url") == {:ok, :direct}
    end
  end
end
