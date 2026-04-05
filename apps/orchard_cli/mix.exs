defmodule OrchardCLI.MixProject do
  use Mix.Project

  def project do
    [
      app: :orchard_cli,
      version: "0.4.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      # M0 exception: this shell is intentionally shallow and the threshold will
      # be raised once orchardctl has non-trivial runtime behavior.
      test_coverage: [summary: [threshold: 0]],
      escript: [main_module: OrchardCLI],
      deps: deps()
    ]
  end

  def application do
    [
      mod: {OrchardCLI.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:orchard_shared, in_umbrella: true},
      {:orchard_controller, in_umbrella: true}
    ]
  end
end
