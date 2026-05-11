defmodule VintageNetProxy.ConfigTest do
  use ExUnit.Case, async: true

  alias VintageNetProxy.Config

  describe "normalize/1 :direct" do
    test "accepts direct mode" do
      assert {:ok, %{mode: :direct}} = Config.normalize(%{mode: :direct})
    end

    test "strips unknown keys" do
      assert {:ok, %{mode: :direct}} = Config.normalize(%{mode: :direct, junk: 1})
    end
  end

  describe "normalize/1 :auto" do
    test "accepts auto without pac_url" do
      assert {:ok, %{mode: :auto}} = Config.normalize(%{mode: :auto})
    end

    test "accepts auto with explicit pac_url" do
      assert {:ok, %{mode: :auto, pac_url: "http://wpad/wpad.dat"}} =
               Config.normalize(%{mode: :auto, pac_url: "http://wpad/wpad.dat"})
    end

    test "rejects empty pac_url" do
      assert {:error, _} = Config.normalize(%{mode: :auto, pac_url: ""})
    end

    test "rejects non-string pac_url" do
      assert {:error, _} = Config.normalize(%{mode: :auto, pac_url: 123})
    end
  end

  describe "normalize/1 :manual" do
    test "accepts minimal manual (scheme defaults to :http)" do
      assert {:ok, normalized} =
               Config.normalize(%{mode: :manual, host: "p.corp", port: 8080})

      assert normalized == %{mode: :manual, scheme: :http, host: "p.corp", port: 8080}
    end

    test "accepts explicit scheme" do
      assert {:ok, %{scheme: :https}} =
               Config.normalize(%{mode: :manual, scheme: :https, host: "p", port: 443})

      assert {:ok, %{scheme: :socks5}} =
               Config.normalize(%{mode: :manual, scheme: :socks5, host: "s", port: 1080})
    end

    test "rejects invalid scheme" do
      assert {:error, _} =
               Config.normalize(%{mode: :manual, scheme: :ftp, host: "p", port: 80})
    end

    test "accepts credentials" do
      assert {:ok, %{username: "alice", password: "secret"}} =
               Config.normalize(%{
                 mode: :manual,
                 host: "p",
                 port: 80,
                 username: "alice",
                 password: "secret"
               })
    end

    test "rejects half credentials" do
      assert {:error, _} =
               Config.normalize(%{mode: :manual, host: "p", port: 80, username: "alice"})

      assert {:error, _} =
               Config.normalize(%{mode: :manual, host: "p", port: 80, password: "secret"})
    end

    test "accepts bypass list" do
      assert {:ok, %{bypass: ["*.local", "10.*"]}} =
               Config.normalize(%{
                 mode: :manual,
                 host: "p",
                 port: 80,
                 bypass: ["*.local", "10.*"]
               })
    end

    test "rejects non-list bypass" do
      assert {:error, _} =
               Config.normalize(%{mode: :manual, host: "p", port: 80, bypass: "*.local"})
    end

    test "rejects missing host" do
      assert {:error, _} = Config.normalize(%{mode: :manual, port: 80})
    end

    test "rejects missing port" do
      assert {:error, _} = Config.normalize(%{mode: :manual, host: "p"})
    end

    test "rejects out-of-range port" do
      assert {:error, _} = Config.normalize(%{mode: :manual, host: "p", port: 0})
      assert {:error, _} = Config.normalize(%{mode: :manual, host: "p", port: 70_000})
      assert {:error, _} = Config.normalize(%{mode: :manual, host: "p", port: "80"})
    end
  end

  describe "normalize/1 invalid top-level" do
    test "missing mode" do
      assert {:error, _} = Config.normalize(%{})
    end

    test "unknown mode" do
      assert {:error, _} = Config.normalize(%{mode: :weird})
    end

    test "non-map input" do
      assert {:error, _} = Config.normalize(:direct)
      assert {:error, _} = Config.normalize("direct")
    end
  end

  describe "normalize!/1" do
    test "returns normalized config on success" do
      assert %{mode: :direct} = Config.normalize!(%{mode: :direct})
    end

    test "raises ArgumentError on failure" do
      assert_raise ArgumentError, fn -> Config.normalize!(%{mode: :bogus}) end
    end
  end

  describe "to_descriptor/1" do
    test "extracts runtime fields from a manual config" do
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
               Config.to_descriptor(manual)

      refute Map.has_key?(Config.to_descriptor(manual), :mode)
      refute Map.has_key?(Config.to_descriptor(manual), :bypass)
    end

    test "preserves only scheme/host/port for minimal manual" do
      assert %{scheme: :http, host: "p", port: 80} =
               Config.to_descriptor(%{mode: :manual, scheme: :http, host: "p", port: 80})
    end
  end
end
