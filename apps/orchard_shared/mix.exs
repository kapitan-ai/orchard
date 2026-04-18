defmodule OrchardShared.MixProject do
  use Mix.Project

  def project do
    [
      app: :orchard_shared,
      version: "0.5.0-dev",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      # M0 exception: this shell is intentionally shallow and the threshold will
      # be raised once shared runtime behavior is added beyond the scaffold.
      test_coverage: [summary: [threshold: 0]],
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      mod: {OrchardShared.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:grpc, "~> 0.11.5"},
      {:protobuf, "~> 0.16.0"},
      {:sentry, "~> 10.2", runtime: false},
      {:hackney, "~> 1.8", runtime: false},
      {:req, "~> 0.5", only: :test}
    ]
  end
end
