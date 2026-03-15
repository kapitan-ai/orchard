defmodule Orchard.MixProject do
  use Mix.Project

  @protoc_gen_elixir_version "0.16.0"

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [preferred_envs: [coveralls: :test, "coveralls.html": :test]]
  end

  defp aliases do
    [
      "proto.gen": [&proto_gen/1],
      "proto.gen.worker": [&proto_gen_worker/1]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_dna, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.1", only: [:dev, :test], runtime: false},
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

  defp proto_gen(_args) do
    File.mkdir_p!("apps/orchard_shared/lib/cluster/v1")

    protoc_path =
      executable!(
        "protoc",
        "Install it with `brew install protobuf` before running `mix proto.gen`."
      )

    plugin_path = protoc_gen_elixir!()

    validate_protoc_gen_elixir_version!(plugin_path)

    case System.cmd(
           protoc_path,
           [
             "-I",
             "proto",
             "--plugin=protoc-gen-elixir=#{plugin_path}",
             "--elixir_out=plugins=grpc,package_prefix=Orchard:apps/orchard_shared/lib",
             "proto/cluster/v1/common.proto",
             "proto/cluster/v1/events.proto",
             "proto/cluster/v1/runtime.proto"
           ],
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("proto.gen failed with exit status #{status}")
    end
  end

  defp cluster_proto_sources do
    [
      Path.absname("proto/cluster/v1/common.proto"),
      Path.absname("proto/cluster/v1/events.proto"),
      Path.absname("proto/cluster/v1/runtime.proto")
    ]
  end

  defp proto_gen_worker(_args) do
    uv_path =
      executable!(
        "uv",
        "Install uv (https://docs.astral.sh/uv/) before running `mix proto.gen.worker`."
      )

    worker_pkg = "native/orchard_worker_mlx"
    proto_root = Path.absname("proto")
    worker_proto_root = Path.absname(Path.join(worker_pkg, "proto"))
    worker_proto = Path.absname(Path.join(worker_proto_root, "orchard/worker/v1/worker_runtime.proto"))
    output_dir = Path.absname(Path.join(worker_pkg, "src/orchard_worker_mlx/generated"))

    File.mkdir_p!(output_dir)

    proto_inputs = cluster_proto_sources() ++ [worker_proto]

    case System.cmd(
           uv_path,
           [
             "run", "--directory", worker_pkg,
             "python", "-m", "grpc_tools.protoc",
             "-I", proto_root,
             "-I", worker_proto_root,
             "--python_out=#{output_dir}",
             "--grpc_python_out=#{output_dir}"
           ] ++ proto_inputs,
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Mix.shell().info("""
        Python cluster + worker bindings generated.
        NOTE: Elixir binding (apps/orchard_node_agent/lib/orchard/node/worker_runtime.pb.ex)
        is maintained manually — update it by hand when the proto changes.
        """)

      {_output, status} ->
        Mix.raise("proto.gen.worker failed with exit status #{status}")
    end
  end

  defp protoc_gen_elixir! do
    fallback_path = Path.join([System.user_home!(), ".mix", "escripts", "protoc-gen-elixir"])

    case System.find_executable("protoc-gen-elixir") ||
           if(File.exists?(fallback_path), do: fallback_path) do
      nil ->
        Mix.raise(
          "protoc-gen-elixir not found. Install it with `mix escript.install hex protobuf #{@protoc_gen_elixir_version}` before running `mix proto.gen`."
        )

      path ->
        path
    end
  end

  defp validate_protoc_gen_elixir_version!(plugin_path) do
    case System.cmd(plugin_path, ["--version"], stderr_to_stdout: true) do
      {version, 0} ->
        if String.trim(version) == @protoc_gen_elixir_version do
          :ok
        else
          Mix.raise(
            "protoc-gen-elixir #{String.trim(version)} found, but Orchard expects #{@protoc_gen_elixir_version}. Reinstall with `mix escript.install hex protobuf #{@protoc_gen_elixir_version}`."
          )
        end

      {_output, status} ->
        Mix.raise("failed to inspect protoc-gen-elixir version (exit status #{status})")
    end
  end

  defp executable!(name, install_hint) do
    case System.find_executable(name) do
      nil -> Mix.raise("#{name} not found. #{install_hint}")
      path -> path
    end
  end
end
