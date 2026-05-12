defmodule Duxedo.MixProject do
  use Mix.Project

  def project do
    [
      app: :duxedo,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Duxedo.Application, []}
    ]
  end

  defp deps do
    [
      {:dux, "~> 0.3"},
      {:adbc, "~> 0.7"},
      {:telemetry, "~> 0.4.3 or ~> 1.0"},
      {:telemetry_metrics, "~> 0.6 or ~> 1.0"},
      {:elixir_uuid, "> 1.2.0"},
      {:term_ui, "~> 1.0.0-rc", optional: true}
    ]
  end
end
