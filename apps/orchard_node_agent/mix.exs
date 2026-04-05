defmodule OrchardNodeAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :orchard_node_agent,
      version: "0.4.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      # M0 exception: this shell is intentionally shallow and the threshold will
      # be raised once node-agent behavior extends beyond the scaffold.
      test_coverage: [summary: [threshold: 0]],
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Orchard.NodeAgent.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:orchard_shared, in_umbrella: true},
      {:req, "~> 0.5"},
      {:req_s3, "~> 0.2"}
    ]
  end
end
