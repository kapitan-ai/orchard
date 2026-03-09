defmodule OrchardShared.MixProject do
  use Mix.Project

  def project do
    [
      app: :orchard_shared,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      # M0 exception: this shell is intentionally shallow and the threshold will
      # be raised once shared runtime behavior is added beyond the scaffold.
      test_coverage: [summary: [threshold: 0]],
      deps: deps()
    ]
  end

  def application do
    [
      mod: {OrchardShared.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:grpc, "~> 0.11.5"},
      {:protobuf, "~> 0.16.0"}
    ]
  end
end
