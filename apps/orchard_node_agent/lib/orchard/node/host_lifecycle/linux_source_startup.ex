defmodule Orchard.Node.HostLifecycle.LinuxSourceStartup do
  @moduledoc """
  Linux source-profile adapter for kernel-proven Node Identity Root ownership.

  The native guardian owns the directory lock and the Agent's parent-death
  link. Registered credentials remain under the existing Peer Grant contract.
  """

  alias Orchard.Node.{RuntimeTLS, SourceStartup.Error}

  import Bitwise, only: [band: 2]

  @credential_fields [:certfile, :keyfile, :cacertfile, :controller_certfile]

  @doc """
  Rejects legacy identity selectors, split roots and unproven guardian context.
  """
  @spec verify!(keyword(), keyword(), keyword(), map(), String.t()) :: map()
  def verify!(config, runtime, grants, environment, subject_pid) do
    validate_selection!(runtime, grants, environment)

    guard = %{
      root: environment["ORCHARD_NODE_IDENTITY_ROOT"],
      marker: environment["ORCHARD_NODE_ROOT_GUARD"],
      subject_pid: subject_pid,
      verification_mode: Keyword.get(config, :verification_mode, :application),
      helper_path: config[:helper_path],
      filesystem: Keyword.get(config, :filesystem, File),
      runner: Keyword.get(config, :runner, &System.cmd/3)
    }

    recheck!(guard, runtime, grants, environment)
    loader = Keyword.get(grants, :identity_loader, RuntimeTLS)

    identity =
      case loader.load_registered_identity(guard.root, require_controller_certificate: true) do
        {:ok, identity} -> identity
        {:error, _reason} -> raise Error, reason: :registered_identity_required
      end

    validate_credentials!(identity, guard.root)
    recheck!(guard, runtime, grants, environment)
    Map.put(guard, :node_id, identity.node_id)
  end

  @doc """
  Revalidates the current kernel holder and both effective identity roots.
  """
  @spec recheck!(map(), keyword(), keyword(), map()) :: :ok
  def recheck!(guard, runtime, grants, environment) do
    unless roots_match?(guard, runtime, grants, environment) do
      raise Error, reason: :identity_root_mismatch
    end

    if is_binary(guard.helper_path) and is_function(guard.runner, 3) do
      case run_verifier(guard) do
        {_output, 0} -> verify_credential_ancestry!(guard)
        _other -> raise Error, reason: :guardian_unproven
      end
    else
      raise Error, reason: :guardian_unavailable
    end
  end

  @doc """
  Ensures identity resolution did not move the root or replace its registered UUID.
  """
  @spec after_identity!(map(), keyword(), keyword(), map()) :: :ok
  def after_identity!(guard, runtime, grants, environment) do
    recheck!(guard, runtime, grants, environment)

    unless runtime[:node_id] == guard.node_id do
      raise Error, reason: :registered_identity_mismatch
    end

    :ok
  end

  defp validate_selection!(runtime, grants, environment) do
    validate_peer_grants!(grants, environment)

    unless is_nil(environment["ORCHARD_NODE_ID"]) and
             is_nil(environment["ORCHARD_NODE_IDENTITY_PATH"]) and
             is_nil(runtime[:node_id]) and is_nil(runtime[:node_identity_path]) do
      raise Error, reason: :legacy_identity_forbidden
    end
  end

  defp validate_peer_grants!(grants, environment) do
    unless environment["ORCHARD_SOURCE_DEV_ROLE"] == "node_agent" and
             grants[:enabled] == true and
             is_binary(environment["ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR"]) and
             environment["ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR"] != "" and
             grants[:descriptor_path] == environment["ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR"] do
      raise Error, reason: :peer_grant_node_required
    end
  end

  defp validate_credentials!(identity, root) do
    if not registered_credentials?(identity, root) do
      raise Error, reason: :registered_identity_required
    end
  end

  defp registered_credentials?(identity, root) do
    is_binary(identity[:node_id]) and identity[:node_id] != "" and
      Enum.all?(@credential_fields, fn key ->
        path = identity[key]
        is_binary(path) and String.starts_with?(Path.expand(path), root <> "/generations/")
      end)
  end

  defp roots_match?(guard, runtime, grants, environment) do
    root_path?(guard.root) and environment["ORCHARD_NODE_IDENTITY_ROOT"] == guard.root and
      environment["ORCHARD_NODE_ROOT_GUARD"] == guard.marker and
      runtime[:node_identity_root] == guard.root and grants[:identity_root] == guard.root
  end

  defp verify_credential_ancestry!(guard) do
    with {:ok, %{type: :directory, uid: owner}} <- guard.filesystem.lstat(guard.root),
         {:ok, %{type: :directory, uid: ^owner, mode: mode}} <-
           guard.filesystem.lstat(Path.join(guard.root, "generations")),
         true <- band(mode, 0o7777) == 0o700 do
      :ok
    else
      _other -> raise Error, reason: :registered_identity_layout_invalid
    end
  end

  defp root_path?(root),
    do: is_binary(root) and String.starts_with?(root, "/") and Path.expand(root) == root

  defp run_verifier(guard) do
    command = if guard.verification_mode == :preflight, do: "--verify-preflight", else: "--verify"

    guard.runner.(
      guard.helper_path,
      [command, guard.root, guard.marker, guard.subject_pid],
      stderr_to_stdout: true
    )
  rescue
    _error in [ArgumentError, ErlangError] -> {:unavailable, 78}
  end
end
