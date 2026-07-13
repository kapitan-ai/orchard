defmodule Orchard.BeamPeerGrants.ControllerPreflight do
  @moduledoc """
  Publishes one source-development Controller exact-pair Distribution launch.
  """

  alias Orchard.BeamPeerGrants
  alias Orchard.RuntimeEndpoint.{DistributionLaunch, DistributionTLS}

  @spec prepare(keyword()) :: {:ok, map()} | {:error, atom()}
  def prepare(opts) when is_list(opts) do
    if Keyword.get(opts, :current_node, Node.self()) == :nonode@nohost do
      prepare_nondistributed(opts)
    else
      {:error, :beam_distribution_preflight_requires_nondistributed_vm}
    end
  rescue
    _error -> {:error, :beam_distribution_preflight_invalid}
  catch
    _kind, _reason -> {:error, :beam_distribution_preflight_invalid}
  end

  defp prepare_nondistributed(opts) do
    grant_id = Keyword.get(opts, :grant_id)
    optfile_path = Keyword.get(opts, :optfile_path)
    manifest_path = Keyword.get(opts, :manifest_path)
    grants = Keyword.get(opts, :grants, BeamPeerGrants)
    distribution_tls = Keyword.get(opts, :distribution_tls, DistributionTLS)
    distribution_launch = Keyword.get(opts, :distribution_launch, DistributionLaunch)

    with true <- required?(grant_id, optfile_path, manifest_path),
         {:ok, material} <- grants.distribution_launch_material(grant_id, material_opts(opts)),
         :ok <-
           distribution_tls.write_options(
             optfile_path,
             material.local_identity,
             material.peer_identity
           ),
         :ok <-
           distribution_tls.verify_options(
             optfile_path,
             material.local_identity,
             material.peer_identity
           ),
         :ok <-
           distribution_launch.write(
             manifest_path,
             launch_attrs(material, optfile_path)
           ) do
      {:ok,
       %{
         grant_id: grant_id,
         manifest_path: Path.expand(manifest_path),
         optfile_path: Path.expand(optfile_path)
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :beam_distribution_preflight_invalid}
    end
  end

  defp launch_attrs(material, optfile_path) do
    Map.merge(material.scope, %{
      role: :controller,
      optfile_path: optfile_path,
      local_identity_generation_id: material.local_identity.generation_id
    })
  end

  defp material_opts(opts) do
    if Keyword.has_key?(opts, :now), do: [now: opts[:now]], else: []
  end

  defp required?(grant_id, optfile_path, manifest_path) do
    Enum.all?([grant_id, optfile_path, manifest_path], &(is_binary(&1) and &1 != ""))
  end
end
