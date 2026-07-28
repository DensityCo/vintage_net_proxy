defmodule VintageNetProxy.MixProject do
  use Mix.Project

  @version "0.1.4"
  @source_url "https://github.com/DensityCo/vintage_net_proxy"

  def project do
    [
      app: :vintage_net_proxy,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      xref: [exclude: [PropertyTable, VintageNet]],
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      optional_applications: [:vintage_net],
      mod: {VintageNetProxy.Application, []}
    ]
  end

  defp deps do
    [
      {:vintage_net, "~> 0.13", optional: true},
      # Test-only: confirms real consumer technologies preserve the `:proxy`
      # field through their `normalize/1` callbacks.
      {:vintage_net_ethernet, "~> 0.11", only: :test, runtime: false},
      {:vintage_net_wifi, "~> 0.12", only: :test, runtime: false},
      {:mimic, "~> 1.7", only: :test},
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Resolve a system HTTP proxy from DHCP Option 252 (WPAD) or manual config; expose via the VintageNet property table."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
