Code.require_file("../../config/product_version.exs", __DIR__)

defmodule OrchardController.MixProject do
  use Mix.Project

  def project do
    [
      app: :orchard_controller,
      version: Orchard.ProductVersion.read!(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      mod: {Orchard.Application, []},
      extra_applications: [:crypto, :logger, :public_key, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:argon2_elixir, "~> 4.1"},
      {:orchard_shared, in_umbrella: true},
      {:bandit, "~> 1.5"},
      {:cors_plug, "~> 3.0"},
      {:ecto_sql, "~> 3.11"},
      {:esbuild, "~> 0.9", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:req, "~> 0.5"},
      {:sentry, "~> 12.0"},
      {:hackney, "~> 1.8"},
      {:phoenix, "~> 1.7.20"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_live_view, "~> 1.1.28"},
      {:phoenix_pubsub, "~> 2.1"},
      {:postgrex, ">= 0.0.0"},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:tidewave, "~> 0.9", only: :dev},
      {:telemetry_metrics, "~> 1.0"},
      # Apache-2.0
      {:telemetry_metrics_prometheus_core, "1.2.1"},
      {:telemetry_poller, "~> 1.0"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": [&npm_ci/1],
      "assets.build": ["tailwind orchard", "esbuild orchard"],
      "assets.deploy": [
        "tailwind orchard --minify",
        "esbuild orchard --minify",
        "phx.digest"
      ]
    ]
  end

  defp npm_ci(_args) do
    npm =
      System.find_executable("npm") ||
        Mix.raise("npm not found. Run `mise install` before running `mix assets.setup`.")

    case System.cmd(
           npm,
           ["ci", "--ignore-scripts"],
           cd: Path.expand("../..", __DIR__),
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("npm ci --ignore-scripts failed with exit status #{status}")
    end
  end
end
