Code.require_file("../../config/product_version.exs", __DIR__)

defmodule OrchardNodeAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :orchard_node_agent,
      version: Orchard.ProductVersion.read!(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      # M0 exception: this shell is intentionally shallow and the threshold will
      # be raised once node-agent behavior extends beyond the scaffold.
      test_coverage: [summary: [threshold: 0]],
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

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
      {:req_s3, "~> 0.2"},
      {:sentry, "~> 13.0"},
      {:hackney, "~> 4.7"}
    ]
  end
end
