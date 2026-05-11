defmodule VintageNetProxy.PAC.PredicateTest do
  use ExUnit.Case, async: true

  alias VintageNetProxy.PAC.Predicate

  describe "atom: isPlainHostName" do
    test "no dot → true" do
      assert Predicate.eval("isPlainHostName(host)", "intranet")
    end

    test "dotted host → false" do
      refute Predicate.eval("isPlainHostName(host)", "intranet.corp")
    end
  end

  describe "atom: shExpMatch" do
    test "star wildcard" do
      assert Predicate.eval(~s|shExpMatch(host, "*.corp")|, "api.corp")
      refute Predicate.eval(~s|shExpMatch(host, "*.corp")|, "api.example")
    end

    test "? wildcard matches a single character" do
      assert Predicate.eval(~s|shExpMatch(host, "h?st")|, "host")
      refute Predicate.eval(~s|shExpMatch(host, "h?st")|, "hoost")
    end

    test "case-insensitive" do
      assert Predicate.eval(~s|shExpMatch(host, "*.CORP")|, "api.corp")
    end
  end

  describe "atom: dnsDomainIs" do
    test "matching suffix" do
      assert Predicate.eval(~s|dnsDomainIs(host, ".corp.example")|, "api.corp.example")
    end

    test "non-matching suffix" do
      refute Predicate.eval(~s|dnsDomainIs(host, ".corp.example")|, "api.example")
    end

    test "case-insensitive both directions" do
      assert Predicate.eval(~s|dnsDomainIs(host, ".CORP.example")|, "api.corp.example")
      assert Predicate.eval(~s|dnsDomainIs(host, ".corp.example")|, "API.CORP.EXAMPLE")
    end
  end

  describe "atom: host equality" do
    test "host == literal" do
      assert Predicate.eval(~s|host == "localhost"|, "localhost")
      refute Predicate.eval(~s|host == "localhost"|, "elsewhere")
    end

    test "host === literal (strict equality variant)" do
      assert Predicate.eval(~s|host === "localhost"|, "localhost")
    end

    test "case-insensitive" do
      assert Predicate.eval(~s|host == "LocalHost"|, "localhost")
    end
  end

  describe "atom: isInNet" do
    test "IP-literal host inside network" do
      assert Predicate.eval(~s|isInNet(host, "10.0.0.0", "255.0.0.0")|, "10.1.2.3")
    end

    test "IP-literal host outside network" do
      refute Predicate.eval(~s|isInNet(host, "10.0.0.0", "255.0.0.0")|, "192.168.1.1")
    end

    test "non-literal host returns false" do
      refute Predicate.eval(~s|isInNet(host, "10.0.0.0", "255.0.0.0")|, "intranet")
      refute Predicate.eval(~s|isInNet(host, "10.0.0.0", "255.0.0.0")|, "api.corp.example")
    end
  end

  describe "boolean composition" do
    test "|| — left match" do
      assert Predicate.eval(
               ~s{isPlainHostName(host) || dnsDomainIs(host, ".corp")},
               "intranet"
             )
    end

    test "|| — right match" do
      assert Predicate.eval(
               ~s{isPlainHostName(host) || dnsDomainIs(host, ".corp")},
               "api.corp"
             )
    end

    test "|| — neither match" do
      refute Predicate.eval(
               ~s{isPlainHostName(host) || dnsDomainIs(host, ".corp")},
               "api.example"
             )
    end

    test "&& — both match" do
      assert Predicate.eval(
               ~s|dnsDomainIs(host, ".corp") && shExpMatch(host, "api*")|,
               "api.corp"
             )
    end

    test "&& — one side fails" do
      refute Predicate.eval(
               ~s|dnsDomainIs(host, ".corp") && shExpMatch(host, "api*")|,
               "web.corp"
             )
    end

    test "! negation" do
      assert Predicate.eval("!isPlainHostName(host)", "foo.example")
      refute Predicate.eval("!isPlainHostName(host)", "intranet")
    end

    test "&& binds tighter than ||" do
      # A || B && C  =>  A || (B && C)
      # host = api.corp; A = isPlainHostName = false; B = dnsDomainIs(".corp") = true;
      # C = shExpMatch("web*") = false  →  false || (true && false) = false
      refute Predicate.eval(
               ~s{isPlainHostName(host) || dnsDomainIs(host, ".corp") && shExpMatch(host, "web*")},
               "api.corp"
             )

      # Same predicate, C = shExpMatch("api*") = true  →  false || (true && true) = true
      assert Predicate.eval(
               ~s{isPlainHostName(host) || dnsDomainIs(host, ".corp") && shExpMatch(host, "api*")},
               "api.corp"
             )
    end

    test "parentheses override precedence" do
      # (A || B) && C — without parens this would be A || (B && C)
      assert Predicate.eval(
               ~s{(isPlainHostName(host) || dnsDomainIs(host, ".corp")) && shExpMatch(host, "api*")},
               "api.corp"
             )

      refute Predicate.eval(
               ~s{(isPlainHostName(host) || dnsDomainIs(host, ".corp")) && shExpMatch(host, "api*")},
               "web.corp"
             )
    end

    test "chained || — left-associative, any match wins" do
      expr =
        ~s{isPlainHostName(host) || dnsDomainIs(host, ".corp") || dnsDomainIs(host, ".local")}

      assert Predicate.eval(expr, "x.local")
      assert Predicate.eval(expr, "api.corp")
      assert Predicate.eval(expr, "intranet")
      refute Predicate.eval(expr, "external.example")
    end
  end

  describe "real-world Mozilla-style compound predicate" do
    @expr ~s{isPlainHostName(host) || dnsDomainIs(host, ".mozilla.org") || isInNet(host, "10.0.0.0", "255.0.0.0")}

    test "plain hostname bypasses" do
      assert Predicate.eval(@expr, "intranet")
    end

    test "internal domain bypasses" do
      assert Predicate.eval(@expr, "wiki.mozilla.org")
    end

    test "RFC1918 IP literal bypasses" do
      assert Predicate.eval(@expr, "10.1.2.3")
    end

    test "external host doesn't match" do
      refute Predicate.eval(@expr, "github.com")
    end
  end

  describe "error handling" do
    test "unsupported atom evaluates to false" do
      refute Predicate.eval(~s|myIpAddress() == "10.0.0.1"|, "intranet")
    end

    test "unbalanced parens — falls through to false" do
      refute Predicate.eval("(isPlainHostName(host)", "intranet")
      refute Predicate.eval("isPlainHostName(host))", "intranet")
    end

    test "garbage — falls through to false" do
      refute Predicate.eval("$$$", "intranet")
    end

    test "empty expression — false" do
      refute Predicate.eval("", "intranet")
    end

    test "trailing tokens after a complete expression — false" do
      refute Predicate.eval("isPlainHostName(host) extra", "intranet")
    end
  end
end
