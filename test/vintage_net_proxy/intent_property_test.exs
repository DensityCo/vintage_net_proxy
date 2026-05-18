defmodule VintageNetProxy.IntentPropertyTest do
  @moduledoc """
  Property-based tests for `VintageNetProxy.Intent.normalize/1`.

  `normalize/1` is a parser at a trust boundary: it consumes
  arbitrary maps under a consumer's `:proxy` config field and either
  produces a sanitized intent or an error. Properties here pin down
  total-function safety (no crashes on garbage input), mode dispatch,
  field preservation for valid configs, and idempotence.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias VintageNetProxy.{Intent, TestGenerators}

  # --- Generators ---

  # Random non-map values; explicitly the cases the type signature
  # has to handle without raising.
  defp non_map_gen do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.integer(),
      StreamData.atom(:alphanumeric),
      StreamData.string(:printable),
      StreamData.list_of(StreamData.integer()),
      StreamData.tuple({StreamData.integer(), StreamData.integer()})
    ])
  end

  # A map with garbage keys/values — random :mode (often invalid) and
  # arbitrary extra keys. Used to fuzz the mode-dispatch and unknown-key
  # behavior.
  defp arbitrary_config_map_gen do
    gen all(
          mode_field <-
            StreamData.one_of([
              StreamData.constant(:direct),
              StreamData.constant(:auto),
              StreamData.constant(:manual),
              StreamData.atom(:alphanumeric),
              StreamData.integer(),
              StreamData.constant(nil)
            ]),
          extras <-
            StreamData.map_of(
              StreamData.atom(:alphanumeric),
              StreamData.one_of([
                StreamData.integer(),
                StreamData.boolean(),
                StreamData.string(:printable)
              ]),
              max_length: 4
            )
        ) do
      Map.put(extras, :mode, mode_field)
    end
  end

  # --- Total-function safety ---

  property "normalize/1 never raises for any term" do
    check all(term <- StreamData.one_of([non_map_gen(), arbitrary_config_map_gen()])) do
      result = Intent.normalize(term)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  property "normalize/1 of a non-map always errors" do
    check all(term <- non_map_gen()) do
      assert match?({:error, _}, Intent.normalize(term))
    end
  end

  property "normalize/1 of a map with no :mode key errors" do
    check all(extras <- StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.integer())) do
      cleaned = Map.delete(extras, :mode)
      assert match?({:error, _}, Intent.normalize(cleaned))
    end
  end

  # --- Mode dispatch ---

  property ":direct mode always normalizes to %{mode: :direct}, ignoring extras" do
    check all(extras <- StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.integer())) do
      config = Map.put(extras, :mode, :direct)
      assert Intent.normalize(config) == {:ok, %{mode: :direct}}
    end
  end

  property "an invalid :mode atom always errors" do
    check all(
            other <- StreamData.atom(:alphanumeric),
            other not in [:direct, :auto, :manual]
          ) do
      assert match?({:error, _}, Intent.normalize(%{mode: other}))
    end
  end

  # --- Auto mode round-trip / field preservation ---

  property ":auto with no :pac_url normalizes to %{mode: :auto}" do
    check all(extras <- StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.integer())) do
      # Drop :pac_url so the extras can't accidentally satisfy the field.
      config = extras |> Map.delete(:pac_url) |> Map.put(:mode, :auto)
      assert Intent.normalize(config) == {:ok, %{mode: :auto}}
    end
  end

  property ":auto with a non-empty string :pac_url preserves it" do
    check all(url <- TestGenerators.pac_url()) do
      assert {:ok, intent} = Intent.normalize(%{mode: :auto, pac_url: url})
      assert intent.mode == :auto
      assert intent.pac_url == url
    end
  end

  property ":auto with a non-binary, non-nil :pac_url errors" do
    check all(
            bad <-
              StreamData.one_of([
                StreamData.integer(),
                StreamData.boolean(),
                StreamData.list_of(StreamData.integer())
              ])
          ) do
      assert match?({:error, _}, Intent.normalize(%{mode: :auto, pac_url: bad}))
    end
  end

  # --- Manual mode round-trip / field preservation ---

  property "valid :manual configs normalize and preserve required fields" do
    check all(config <- TestGenerators.manual_intent()) do
      assert {:ok, intent} = Intent.normalize(config)
      assert intent.mode == :manual
      assert intent.scheme == config.scheme
      assert intent.host == config.host
      assert intent.port == config.port
    end
  end

  property "valid :manual configs preserve optional credentials and bypass" do
    check all(config <- TestGenerators.manual_intent_with_optionals()) do
      assert {:ok, intent} = Intent.normalize(config)
      assert Map.get(intent, :username) == Map.get(config, :username)
      assert Map.get(intent, :password) == Map.get(config, :password)
      assert Map.get(intent, :bypass) == Map.get(config, :bypass)
    end
  end

  property ":manual missing :host always errors" do
    check all(
            port <- TestGenerators.port(),
            scheme <- StreamData.member_of(TestGenerators.schemes())
          ) do
      assert match?({:error, _}, Intent.normalize(%{mode: :manual, port: port, scheme: scheme}))
    end
  end

  property ":manual missing :port always errors" do
    check all(
            host <- TestGenerators.host(),
            scheme <- StreamData.member_of(TestGenerators.schemes())
          ) do
      assert match?({:error, _}, Intent.normalize(%{mode: :manual, host: host, scheme: scheme}))
    end
  end

  property ":manual with port out of [1, 65535] errors" do
    check all(
            host <- TestGenerators.host(),
            bad_port <-
              StreamData.one_of([
                StreamData.integer(-1_000..0),
                StreamData.integer(65_536..100_000)
              ])
          ) do
      assert match?({:error, _}, Intent.normalize(%{mode: :manual, host: host, port: bad_port}))
    end
  end

  # --- Idempotence ---

  property "normalize is idempotent on its own output" do
    check all(
            config <-
              StreamData.one_of([
                StreamData.constant(%{mode: :direct}),
                TestGenerators.auto_intent(),
                TestGenerators.manual_intent_with_optionals()
              ])
          ) do
      assert {:ok, intent} = Intent.normalize(config)
      assert Intent.normalize(intent) == {:ok, intent}
    end
  end
end
