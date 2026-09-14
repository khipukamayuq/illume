defmodule Illume.MixProject do
  use Mix.Project

  def project do
    [
      app: :illume,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: Illume.CLI],
      dialyzer: [plt_file: {:no_warn, "priv/plts/dialyzer.plt"}]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Illume.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req_anthropic, "~> 0.2"},
      {:telemetry, "~> 1.2"},
      {:mox, "~> 1.1", only: :test},
      {:plug, "~> 1.18", only: :test},
      {:anubis_mcp, "~> 2.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
