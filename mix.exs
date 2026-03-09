defmodule Orchard.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [preferred_envs: [coveralls: :test, "coveralls.html": :test]]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp releases do
    [
      orchard_controller: [
        applications: [
          orchard_shared: :permanent,
          orchard_controller: :permanent
        ]
      ],
      orchard_node_agent: [
        applications: [
          orchard_shared: :permanent,
          orchard_node_agent: :permanent
        ]
      ],
      orchard_cli: [
        applications: [
          orchard_shared: :permanent,
          orchard_cli: :permanent
        ]
      ]
    ]
  end
end
