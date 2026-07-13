defmodule Orchard.BeamPeerGrants.ControllerStartupVerifier do
  @moduledoc """
  Fails Controller startup unless the VM and database still authorize its launch.
  """

  use GenServer

  alias Orchard.BeamPeerGrants
  alias Orchard.RuntimeEndpoint.{DistributionLaunch, DistributionTLS}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec verify(keyword()) :: :ok | {:error, atom()}
  def verify(opts) when is_list(opts) do
    manifest_path = Keyword.get(opts, :manifest_path)
    distribution_launch = Keyword.get(opts, :distribution_launch, DistributionLaunch)
    grants = Keyword.get(opts, :grants, BeamPeerGrants)
    distribution_tls = Keyword.get(opts, :distribution_tls, DistributionTLS)

    with true <- is_binary(manifest_path) and manifest_path != "",
         {:ok, manifest} <- distribution_launch.load(manifest_path),
         true <- value(manifest, :role) == :controller,
         grant_id when is_binary(grant_id) <- value(manifest, :grant_id),
         {:ok, material} <- grants.distribution_launch_material(grant_id, material_opts(opts)),
         true <- exact_scope?(manifest, material),
         :ok <- distribution_launch.verify_vm(manifest, vm_opts(opts)),
         :ok <-
           distribution_tls.verify_options(
             value(manifest, :optfile_path),
             material.local_identity,
             material.peer_identity
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :beam_distribution_launch_contract_invalid}
    end
  rescue
    _error -> {:error, :beam_distribution_launch_contract_invalid}
  catch
    _kind, _reason -> {:error, :beam_distribution_launch_contract_invalid}
  end

  @impl true
  def init(opts) do
    case verify(opts) do
      :ok -> {:ok, opts}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp exact_scope?(manifest, material) do
    Enum.all?(material.scope, fn {key, expected} -> value(manifest, key) == expected end) and
      value(manifest, :local_identity_generation_id) == material.local_identity.generation_id
  end

  defp vm_opts(opts) do
    [
      current_node: Keyword.get(opts, :current_node, Node.self()),
      static_targets: Keyword.get(opts, :static_targets, []),
      cookie_file: Keyword.get(opts, :cookie_file)
    ]
    |> put_optional(opts, :argument_reader)
    |> put_optional(opts, :tls_versions)
    |> put_optional(opts, :now)
  end

  defp material_opts(opts) do
    if Keyword.has_key?(opts, :now), do: [now: opts[:now]], else: []
  end

  defp put_optional(target, source, key) do
    if Keyword.has_key?(source, key), do: Keyword.put(target, key, source[key]), else: target
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
