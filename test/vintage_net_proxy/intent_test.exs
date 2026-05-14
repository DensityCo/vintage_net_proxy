defmodule VintageNetProxy.IntentTest do
  use ExUnit.Case, async: true

  alias VintageNetProxy.Intent

  describe "normalize/1 :direct" do
    test "accepts direct mode" do
      assert {:ok, %{mode: :direct}} = Intent.normalize(%{mode: :direct})
    end

    test "strips unknown keys" do
      assert {:ok, %{mode: :direct}} = Intent.normalize(%{mode: :direct, junk: 1})
    end
  end

  describe "normalize/1 :auto" do
    test "accepts auto without pac_url" do
      assert {:ok, %{mode: :auto}} = Intent.normalize(%{mode: :auto})
    end

    test "accepts auto with explicit pac_url" do
      assert {:ok, %{mode: :auto, pac_url: "http://wpad/wpad.dat"}} =
               Intent.normalize(%{mode: :auto, pac_url: "http://wpad/wpad.dat"})
    end

    test "rejects empty pac_url" do
      assert {:error, _} = Intent.normalize(%{mode: :auto, pac_url: ""})
    end

    test "rejects non-string pac_url" do
      assert {:error, _} = Intent.normalize(%{mode: :auto, pac_url: 123})
    end
  end

  describe "normalize/1 :manual" do
    test "accepts minimal manual (scheme defaults to :http)" do
      assert {:ok, normalized} =
               Intent.normalize(%{mode: :manual, host: "p.corp", port: 8080})

      assert normalized == %{mode: :manual, scheme: :http, host: "p.corp", port: 8080}
    end

    test "accepts explicit scheme" do
      assert {:ok, %{scheme: :https}} =
               Intent.normalize(%{mode: :manual, scheme: :https, host: "p", port: 443})

      assert {:ok, %{scheme: :socks5}} =
               Intent.normalize(%{mode: :manual, scheme: :socks5, host: "s", port: 1080})
    end

    test "rejects invalid scheme" do
      assert {:error, _} =
               Intent.normalize(%{mode: :manual, scheme: :ftp, host: "p", port: 80})
    end

    test "accepts credentials" do
      assert {:ok, %{username: "alice", password: "secret"}} =
               Intent.normalize(%{
                 mode: :manual,
                 host: "p",
                 port: 80,
                 username: "alice",
                 password: "secret"
               })
    end

    test "rejects half credentials" do
      assert {:error, _} =
               Intent.normalize(%{mode: :manual, host: "p", port: 80, username: "alice"})

      assert {:error, _} =
               Intent.normalize(%{mode: :manual, host: "p", port: 80, password: "secret"})
    end

    test "accepts bypass list" do
      assert {:ok, %{bypass: ["*.local", "10.*"]}} =
               Intent.normalize(%{
                 mode: :manual,
                 host: "p",
                 port: 80,
                 bypass: ["*.local", "10.*"]
               })
    end

    test "rejects non-list bypass" do
      assert {:error, _} =
               Intent.normalize(%{mode: :manual, host: "p", port: 80, bypass: "*.local"})
    end

    test "rejects missing host" do
      assert {:error, _} = Intent.normalize(%{mode: :manual, port: 80})
    end

    test "rejects missing port" do
      assert {:error, _} = Intent.normalize(%{mode: :manual, host: "p"})
    end

    test "rejects out-of-range port" do
      assert {:error, _} = Intent.normalize(%{mode: :manual, host: "p", port: 0})
      assert {:error, _} = Intent.normalize(%{mode: :manual, host: "p", port: 70_000})
      assert {:error, _} = Intent.normalize(%{mode: :manual, host: "p", port: "80"})
    end
  end

  describe "normalize/1 invalid top-level" do
    test "missing mode" do
      assert {:error, _} = Intent.normalize(%{})
    end

    test "unknown mode" do
      assert {:error, _} = Intent.normalize(%{mode: :weird})
    end

    test "non-map input" do
      assert {:error, _} = Intent.normalize(:direct)
      assert {:error, _} = Intent.normalize("direct")
    end
  end

  describe "normalize!/1" do
    test "returns normalized intent on success" do
      assert %{mode: :direct} = Intent.normalize!(%{mode: :direct})
    end

    test "raises ArgumentError on failure" do
      assert_raise ArgumentError, fn -> Intent.normalize!(%{mode: :bogus}) end
    end
  end

  describe "to_descriptor/1" do
    test "extracts runtime fields from a manual intent" do
      manual = %{
        mode: :manual,
        scheme: :http,
        host: "p.corp",
        port: 8080,
        username: "alice",
        password: "secret",
        bypass: ["*.local"]
      }

      assert %{scheme: :http, host: "p.corp", port: 8080, username: "alice", password: "secret"} =
               Intent.to_descriptor(manual)

      refute Map.has_key?(Intent.to_descriptor(manual), :mode)
      refute Map.has_key?(Intent.to_descriptor(manual), :bypass)
    end

    test "preserves only scheme/host/port for minimal manual" do
      assert %{scheme: :http, host: "p", port: 80} =
               Intent.to_descriptor(%{mode: :manual, scheme: :http, host: "p", port: 80})
    end
  end

  describe "from_vintage_net_config/1" do
    test "delegates a valid :proxy field to normalize" do
      config = %{type: :something, proxy: %{mode: :direct}}
      assert Intent.from_vintage_net_config(config) == {:ok, %{mode: :direct}}
    end

    test "normalizes :auto with :pac_url" do
      config = %{proxy: %{mode: :auto, pac_url: "http://w/"}}

      assert Intent.from_vintage_net_config(config) ==
               {:ok, %{mode: :auto, pac_url: "http://w/"}}
    end

    test "propagates normalize errors" do
      config = %{proxy: %{mode: :bogus}}
      assert {:error, _reason} = Intent.from_vintage_net_config(config)
    end

    test "config map without a :proxy field → {:ok, nil}" do
      assert Intent.from_vintage_net_config(%{type: :something}) == {:ok, nil}
    end

    test "non-map :proxy field → {:ok, nil} (treated as absent)" do
      assert Intent.from_vintage_net_config(%{proxy: nil}) == {:ok, nil}
      assert Intent.from_vintage_net_config(%{proxy: "string"}) == {:ok, nil}
    end

    test "non-map input → {:ok, nil}" do
      assert Intent.from_vintage_net_config(nil) == {:ok, nil}
      assert Intent.from_vintage_net_config(:unknown) == {:ok, nil}
    end
  end
end
