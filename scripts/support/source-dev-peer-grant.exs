defmodule Orchard.SourceDevPeerGrant do
  alias Orchard.BeamPeerGrantDescriptor
  alias Orchard.BeamPeerGrants.ControllerPreflight
  alias Orchard.Node.BeamPeerGrantPreflight

  def run(["node-retrieve"]) do
    start_node_preflight_dependencies!()

    opts = node_opts()
    {:ok, grant} = BeamPeerGrantPreflight.retrieve_and_store(opts)
    IO.puts("stored grant #{grant.grant_id}")
  end

  def run(["node-preflight"]) do
    start_node_preflight_dependencies!()
    paths = launch_paths!(:node_agent)

    {:ok, result} =
      BeamPeerGrantPreflight.prepare_distribution(
        node_opts() ++
          [
            optfile_path: paths.optfile_path,
            manifest_path: paths.manifest_path
          ]
      )

    print_result(result)
  end

  def run(["controller-preflight"]) do
    start_controller_preflight_dependencies!()
    descriptor_path = required_env!("ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR")
    {:ok, descriptor} = BeamPeerGrantDescriptor.load(descriptor_path)
    paths = launch_paths!(:controller)

    {:ok, result} =
      ControllerPreflight.prepare(
        grant_id: descriptor.grant_id,
        optfile_path: paths.optfile_path,
        manifest_path: paths.manifest_path
      )

    print_result(result)
  end

  def run(_args) do
    raise "expected node-retrieve|node-preflight|controller-preflight"
  end

  defp node_opts do
    [
      identity_root: required_env!("ORCHARD_NODE_IDENTITY_ROOT"),
      descriptor_path: required_env!("ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR"),
      node_beam_name: required_env!("ORCHARD_BEAM_NODE_NAME")
    ]
  end

  defp launch_paths!(role) do
    root = required_env!("ORCHARD_BEAM_PEER_GRANT_STATE_ROOT") |> Path.expand()
    role_root = Path.join(root, Atom.to_string(role))
    ensure_private_directory!(root)
    ensure_private_directory!(role_root)

    %{
      manifest_path: Path.join(role_root, "launch.json"),
      optfile_path: Path.join(role_root, "ssl-dist.conf")
    }
  end

  defp start_node_preflight_dependencies! do
    {:ok, _apps} = Application.ensure_all_started(:orchard_shared)
    {:ok, _apps} = Application.ensure_all_started(:grpc)
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    start_grpc_client_supervisor!()
  end

  defp start_grpc_client_supervisor! do
    case Process.whereis(GRPC.Client.Supervisor) do
      nil ->
        {:ok, _pid} =
          DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)

        :ok

      _pid ->
        :ok
    end
  end

  defp start_controller_preflight_dependencies! do
    {:ok, _apps} = Application.ensure_all_started(:orchard_shared)
    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)
    {:ok, _apps} = Application.ensure_all_started(:postgrex)
    {:ok, _repo} = Orchard.Repo.start_link()
  end

  defp ensure_private_directory!(path) do
    case File.lstat(path) do
      {:ok, stat} ->
        unless stat.type == :directory and Bitwise.band(stat.mode, 0o777) == 0o700 do
          raise "peer-grant state directory is invalid"
        end

      {:error, :enoent} ->
        File.mkdir!(path)
        File.chmod!(path, 0o700)

      {:error, _reason} ->
        raise "peer-grant state directory is invalid"
    end
  end

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _other -> raise "#{name} is required"
    end
  end

  defp print_result(result) do
    IO.puts("manifest=#{result.manifest_path}")
    IO.puts("optfile=#{result.optfile_path}")
    IO.puts("grant_id=#{result.grant_id}")
  end
end

Orchard.SourceDevPeerGrant.run(System.argv())
