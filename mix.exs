defmodule VintageNetProxy.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/DensityCo/vintage_net_proxy"

  def project do
    [
      app: :vintage_net_proxy,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {VintageNetProxy.Application, []}
    ]
  end

  defp deps do
    [
      {:vintage_net, "~> 0.13"},
      # Test-only: confirms real consumer technologies preserve the `:proxy`
      # field through their `normalize/1` callbacks.
      {:vintage_net_ethernet, "~> 0.11", only: :test, runtime: false},
      {:vintage_net_wifi, "~> 0.12", only: :test, runtime: false},
      {:mimic, "~> 1.7", only: :test},
      {:stream_data, "~> 1.0", only: :test},
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
