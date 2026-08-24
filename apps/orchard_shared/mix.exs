Code.require_file("../../config/product_version.exs", __DIR__)

defmodule OrchardShared.MixProject do
  use Mix.Project

  def project do
    [
      app: :orchard_shared,
      version: Orchard.ProductVersion.read!(),
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
      {:grpc, "~> 1.0"},
      {:grpc_server, "~> 1.0"},
      {:gun, "~> 2.4"},
      {:protobuf, "~> 0.17.0"},
      {:hackney, "~> 1.8", runtime: false},
      {:req, "~> 0.5", only: :test}
    ]
  end
end
