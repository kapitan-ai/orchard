defmodule OrchardCLI.Commands.Cluster do
  @moduledoc false

  alias Orchard.ClusterManagement.ControlPlaneStatus
  alias Orchard.ControlPlane
  alias Orchard.Governance.ClusterBootstrap
  alias OrchardCLI.Commands.GovernanceHelpers
  alias OrchardCLI.RepoRuntime

  @cluster_status_object "cluster_management.cluster_status"
  @cluster_status_contract_version "orchard.cluster_management.cluster_status.v1"

  @cluster_init_object "cluster_management.cluster_init"
  @cluster_init_contract_version "orchard.cluster_management.cluster_init.v1"
  @reservation_attempts 3

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(["status" | rest]), do: run_status(rest)
  def run(["help"]), do: {:ok, group_usage()}
  def run(["--help"]), do: {:ok, group_usage()}
  def run([]), do: {:error, group_usage(), 1}

  def run(["init" | rest]), do: run_init(rest)

  def run(_args), do: {:error, group_usage(), 1}

  defp run_init(["help"]), do: {:ok, init_usage()}
  defp run_init(["--help"]), do: {:ok, init_usage()}

  defp run_init(args) do
    case parse_init_args(args) do
      {:ok, opts} -> run_init_parsed(opts)
      {:help, usage} -> {:ok, usage}
      {:error, message, code} -> {:error, message, code}
    end
  end

  defp run_init_parsed(opts) do
    json? = Keyword.get(opts, :json, false)

    result =
      with {:ok, output_path} <- fetch_required_output(opts),
           {:ok, reservation} <- reserve_output(output_path) do
        run_reserved_init(opts, reservation, json?)
      end

    case result do
      {:ok, _message} = success ->
        success

      {:error, code, message, exit_code} ->
        render_init_error(code, message, exit_code, json?)

      {:error, reason} ->
        init_error(reason, json?)
    end
  end

  defp run_reserved_init(opts, reservation, json?) do
    case confirm_recovery(opts) do
      :ok ->
        mint_reserved_admin(opts, reservation, json?)

      error ->
        release_before_return(reservation, error)
    end
  end

  defp mint_reserved_admin(opts, reservation, json?) do
    case mint_admin(opts) do
      {:ok, result} ->
        write_output_and_render(result, reservation, json?)

      error ->
        release_before_return(reservation, error)
    end
  end

  defp release_before_return(reservation, result) do
    case release_reservation(reservation) do
      :ok ->
        result

      {:error, reason} ->
        {:error, :output_parent_not_writable,
         "failed to clean reserved credential output: #{inspect(reason)}", 1}
    end
  end

  defp parse_init_args(args) do
    switches = [
      output: :string,
      json: :boolean,
      client_name: :string,
      force_new_admin: :boolean,
      yes: :boolean,
      help: :boolean
    ]

    case OptionParser.parse(args, strict: switches) do
      {opts, [], []} ->
        if Keyword.get(opts, :help, false), do: {:help, init_usage()}, else: {:ok, opts}

      {_opts, positional, []} ->
        {:error,
         "Error: unexpected argument(s): #{Enum.join(positional, ", ")}\n\n#{init_usage()}", 1}

      {_opts, _positional, [{flag, _value} | _unknown]} ->
        {:error, "Unknown option: #{format_unknown_flag(flag)}", 2}
    end
  end

  defp fetch_required_output(opts) do
    case Keyword.get(opts, :output) do
      nil -> {:error, :missing_output, "missing required option: --output", 1}
      path -> {:ok, Path.expand(path)}
    end
  end

  defp reserve_output(path) do
    ops = file_ops()
    parent = Path.dirname(path)

    cond do
      ops.exists?(path) or match?({:ok, _stat}, ops.lstat(path)) ->
        {:error, :output_path_exists, "output path already exists: #{path}", 1}

      not ops.dir?(parent) ->
        {:error, :output_parent_missing, "output parent directory does not exist: #{parent}", 1}

      true ->
        reserve_output_in_parent(path, parent, ops)
    end
  end

  defp reserve_output_in_parent(path, parent, ops) do
    case create_reservation(path, parent, ops, @reservation_attempts) do
      {:ok, reservation} ->
        verify_reservation_cleanup(reservation)

      {:error, reason} ->
        reservation_error(parent, reason)
    end
  end

  defp create_reservation(_path, _parent, _ops, 0), do: {:error, :staging_collision}

  defp create_reservation(path, parent, ops, attempts_left) do
    staging_dir =
      Path.join(
        parent,
        ".#{Path.basename(path)}.staging-#{System.unique_integer([:positive])}"
      )

    case ops.mkdir(staging_dir) do
      :ok ->
        build_reservation(path, parent, staging_dir, ops)

      {:error, :eexist} ->
        create_reservation(path, parent, ops, attempts_left - 1)

      {:error, reason} ->
        {:error, {:staging_directory_create, reason}}
    end
  end

  defp build_reservation(path, parent, staging_dir, ops) do
    with {:ok, directory_stat} <- ops.lstat(staging_dir),
         :ok <- require_type(directory_stat, :directory),
         directory_identity = file_identity(directory_stat),
         :ok <- ops.chmod(staging_dir, 0o700),
         :ok <- verify_path(staging_dir, directory_identity, :directory, 0o700, ops) do
      open_reserved_file(path, parent, staging_dir, directory_identity, ops)
    else
      {:error, reason} ->
        {:error, {:staging_directory_prepare, reason}}
    end
  end

  defp open_reserved_file(path, parent, staging_dir, directory_identity, ops) do
    staging_path =
      Path.join(
        staging_dir,
        ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive])}"
      )

    case ops.open(staging_path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        secure_reserved_file(
          path,
          parent,
          staging_dir,
          staging_path,
          directory_identity,
          io,
          ops
        )

      {:error, reason} ->
        _cleanup = remove_owned_directory(staging_dir, directory_identity, ops)
        {:error, {:staging_file_create, reason}}
    end
  end

  defp secure_reserved_file(
         path,
         parent,
         staging_dir,
         staging_path,
         directory_identity,
         io,
         ops
       ) do
    case descriptor_identity(io) do
      {:ok, staging_identity} ->
        result =
          with :ok <- verify_path(staging_path, staging_identity, :regular, nil, ops),
               :ok <- ops.chmod(staging_path, 0o600),
               :ok <- verify_path(staging_path, staging_identity, :regular, 0o600, ops) do
            {:ok,
             %{
               output_path: path,
               parent: parent,
               staging_dir: staging_dir,
               staging_path: staging_path,
               directory_identity: directory_identity,
               staging_identity: staging_identity,
               io: io,
               ops: ops
             }}
          end

        cleanup_failed_reservation(
          result,
          io,
          staging_path,
          staging_identity,
          staging_dir,
          directory_identity,
          ops
        )

      {:error, reason} ->
        _close = ops.close(io)
        _directory_cleanup = remove_owned_directory(staging_dir, directory_identity, ops)
        {:error, {:staging_descriptor_stat, reason}}
    end
  end

  defp cleanup_failed_reservation(
         {:ok, _reservation} = success,
         _io,
         _staging_path,
         _staging_identity,
         _staging_dir,
         _directory_identity,
         _ops
       ),
       do: success

  defp cleanup_failed_reservation(
         {:error, reason},
         io,
         staging_path,
         staging_identity,
         staging_dir,
         directory_identity,
         ops
       ) do
    _close = ops.close(io)
    _staging_cleanup = remove_owned_path(staging_path, staging_identity, ops)
    _directory_cleanup = remove_owned_directory(staging_dir, directory_identity, ops)
    {:error, {:staging_file_prepare, reason}}
  end

  defp verify_reservation_cleanup(reservation) do
    probe_path =
      Path.join(
        reservation.staging_dir,
        ".#{Path.basename(reservation.output_path)}.preflight-#{System.unique_integer([:positive])}"
      )

    case reservation.ops.open(probe_path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        verify_probe_file(reservation, probe_path, io)

      {:error, reason} ->
        fail_reservation_probe(reservation, {:probe_create, reason})
    end
  end

  defp verify_probe_file(reservation, probe_path, io) do
    case descriptor_identity(io) do
      {:ok, probe_identity} ->
        close_result = reservation.ops.close(io)

        cleanup_result =
          with :ok <- verify_path(probe_path, probe_identity, :regular, nil, reservation.ops),
               :ok <- close_result do
            remove_owned_path(probe_path, probe_identity, reservation.ops)
          end

        case cleanup_result do
          :ok ->
            {:ok, reservation}

          {:error, reason} ->
            _cleanup_retry = remove_owned_path(probe_path, probe_identity, reservation.ops)
            fail_reservation_probe(reservation, {:probe_cleanup, reason})
        end

      {:error, reason} ->
        _close = reservation.ops.close(io)
        fail_reservation_probe(reservation, {:probe_descriptor_stat, reason})
    end
  end

  defp fail_reservation_probe(reservation, reason) do
    _release = release_reservation(reservation)
    reservation_error(reservation.parent, reason)
  end

  defp reservation_error(parent, reason) do
    {:error, :output_parent_not_writable,
     "output parent directory is not writable: #{parent}: #{format_file_error(reason)}", 1}
  end

  defp confirm_recovery(opts) do
    if Keyword.get(opts, :force_new_admin, false) and not Keyword.get(opts, :yes, false) do
      {:error, :recovery_confirmation_required,
       "--force-new-admin requires --yes before minting a recovery admin credential.", 2}
    else
      :ok
    end
  end

  defp mint_admin(opts) do
    mint_opts =
      [actor_id: "local-orchardctl"]
      |> maybe_put_client_name(opts)

    RepoRuntime.with_repo(fn -> do_mint_admin(opts, mint_opts) end)
    |> unwrap_mint_admin()
  end

  defp do_mint_admin(opts, mint_opts) do
    if Keyword.get(opts, :force_new_admin, false) do
      ClusterBootstrap.mint_recovery_admin(mint_opts)
    else
      ClusterBootstrap.mint_first_admin(mint_opts)
    end
  end

  defp unwrap_mint_admin({:ok, result}), do: result
  defp unwrap_mint_admin({:error, reason}), do: {:error, reason}

  defp maybe_put_client_name(mint_opts, opts) do
    case Keyword.fetch(opts, :client_name) do
      {:ok, client_name} -> Keyword.put(mint_opts, :client_name, client_name)
      :error -> mint_opts
    end
  end

  defp write_output_and_render(result, reservation, json?) do
    case write_output(reservation, result) do
      :ok ->
        {:ok, render_init_success(result, reservation.output_path, json?)}

      {:error, message} ->
        message =
          [message, output_failed_persistence_warning(mark_output_failed(result, message))]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        {:error, :one_time_secret_output_failed, message, 1}
    end
  end

  defp mark_output_failed(result, message) do
    RepoRuntime.with_repo(fn ->
      ClusterBootstrap.mark_output_failed(result, %{
        "reason" => message,
        "api_token_prefix" => result.api_token_prefix
      })
    end)
  end

  defp output_failed_persistence_warning({:ok, {:ok, _result}}), do: nil

  defp output_failed_persistence_warning({:ok, {:error, reason}}) do
    "Failed to record output_failed status/audit: #{format_persistence_error(reason)}"
  end

  defp output_failed_persistence_warning({:error, {:database_unavailable, message}}) do
    "Failed to record output_failed status/audit: #{message}"
  end

  defp format_persistence_error(%Ecto.Changeset{} = changeset) do
    changeset.errors |> inspect()
  end

  defp format_persistence_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_persistence_error(reason), do: inspect(reason)

  defp write_output(reservation, result) do
    payload =
      Jason.encode!(%{
        object: "cluster_management.cluster_admin_credential",
        api_client_id: result.api_client_id,
        api_token_id: result.api_token_id,
        api_token_prefix: result.api_token_prefix,
        api_token: result.token
      })

    with :ok <-
           verify_path(
             reservation.staging_path,
             reservation.staging_identity,
             :regular,
             0o600,
             reservation.ops
           ),
         :ok <- write_descriptor(reservation.io, payload),
         :ok <- verify_descriptor(reservation.io, reservation.staging_identity),
         :ok <-
           verify_path(
             reservation.staging_path,
             reservation.staging_identity,
             :regular,
             0o600,
             reservation.ops
           ),
         :ok <- reservation.ops.ln(reservation.staging_path, reservation.output_path),
         :ok <- verify_published_output(reservation),
         :ok <-
           remove_owned_path(
             reservation.staging_path,
             reservation.staging_identity,
             reservation.ops
           ),
         :ok <-
           remove_owned_directory(
             reservation.staging_dir,
             reservation.directory_identity,
             reservation.ops
           ),
         :ok <- reservation.ops.close(reservation.io) do
      :ok
    else
      {:error, reason} ->
        contain_failed_output(reservation, reason)
    end
  end

  defp contain_failed_output(reservation, reason) do
    message =
      "cluster init minted a credential but One-time Secret Output failed: " <>
        format_file_error(reason)

    {:error, cleanup_message} = contain_failed_cleanup(reservation)
    {:error, message <> "; " <> cleanup_message}
  end

  defp contain_failed_cleanup(reservation) do
    containment = [
      plaintext_redaction: redact_descriptor(reservation.io),
      descriptor_close: reservation.ops.close(reservation.io),
      temporary_cleanup_retry:
        remove_owned_path(
          reservation.staging_path,
          reservation.staging_identity,
          reservation.ops
        ),
      staging_directory_cleanup:
        remove_owned_directory(
          reservation.staging_dir,
          reservation.directory_identity,
          reservation.ops
        )
    ]

    detail =
      containment
      |> Enum.reject(fn {_step, result} -> result == :ok end)
      |> inspect()

    {:error,
     "cluster init minted a credential but temporary secret cleanup was required; " <>
       "containment=#{detail}"}
  end

  defp release_reservation(reservation) do
    results = [
      plaintext_redaction: redact_descriptor(reservation.io),
      descriptor_close: reservation.ops.close(reservation.io),
      temporary_cleanup:
        remove_owned_path(
          reservation.staging_path,
          reservation.staging_identity,
          reservation.ops
        ),
      staging_directory_cleanup:
        remove_owned_directory(
          reservation.staging_dir,
          reservation.directory_identity,
          reservation.ops
        )
    ]

    case Enum.reject(results, fn {_step, result} -> result == :ok end) do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  defp write_descriptor(io, contents) do
    with :ok <- IO.binwrite(io, contents), do: :file.sync(io)
  end

  defp redact_descriptor(io) do
    with {:ok, 0} <- :file.position(io, :bof),
         :ok <- :file.truncate(io),
         do: :file.sync(io)
  end

  defp verify_descriptor(io, identity) do
    case descriptor_identity(io) do
      {:ok, ^identity} -> :ok
      {:ok, _other} -> {:error, :staging_descriptor_identity_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_published_output(reservation) do
    verify_path(
      reservation.output_path,
      reservation.staging_identity,
      :regular,
      0o600,
      reservation.ops
    )
  end

  defp descriptor_identity(io) do
    case :file.read_file_info(io) do
      {:ok, record} -> {:ok, record |> File.Stat.from_record() |> file_identity()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_path(path, identity, type, mode, ops) do
    case ops.lstat(path) do
      {:ok, stat} ->
        cond do
          file_identity(stat) != identity -> {:error, :path_identity_changed}
          stat.type != type -> {:error, :unexpected_path_type}
          is_integer(mode) and Bitwise.band(stat.mode, 0o777) != mode -> {:error, :unsafe_mode}
          true -> :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_type(%File.Stat{type: type}, type), do: :ok
  defp require_type(_stat, _type), do: {:error, :unexpected_path_type}

  defp file_identity(%File.Stat{} = stat) do
    {stat.type, stat.major_device, stat.minor_device, stat.inode}
  end

  defp remove_owned_path(path, identity, ops),
    do: remove_owned(path, identity, ops, :rm)

  defp remove_owned_directory(path, identity, ops),
    do: remove_owned(path, identity, ops, :rmdir)

  defp remove_owned(path, identity, ops, operation) do
    case ops.lstat(path) do
      {:ok, stat} ->
        remove_if_identity_matches(path, stat, identity, ops, operation)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_if_identity_matches(path, stat, identity, ops, operation) do
    if file_identity(stat) == identity do
      remove_verified_path(path, ops, operation)
    else
      {:error, :path_identity_changed}
    end
  end

  defp remove_verified_path(path, ops, operation) do
    case apply(ops, operation, [path]) do
      :ok -> verify_path_absent(path, ops)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_path_absent(path, ops) do
    case ops.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :path_reappeared}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_init_success(result, output_path, true) do
    Jason.encode!(
      %{
        object: @cluster_init_object,
        contract_version: @cluster_init_contract_version,
        api_client_id: result.api_client_id,
        api_token_id: result.api_token_id,
        api_token_prefix: result.api_token_prefix,
        recovery: result.recovery?,
        output_path: output_path,
        next_steps: [
          "Provision named admin API Clients for regular operators.",
          "Revoke this bootstrap credential after named admin access is verified."
        ]
      },
      pretty: true
    )
  end

  defp render_init_success(result, output_path, false) do
    lines = [
      "Cluster admin credential minted.",
      "One-time Secret Output: #{output_path}",
      "API Client ID: #{result.api_client_id}",
      "API Token ID: #{result.api_token_id}",
      "API Token prefix: #{result.api_token_prefix}",
      "Recovery credential: #{if(result.recovery?, do: "yes", else: "no")}",
      "Next: provision named admin API Clients for regular operators, verify access, then revoke this bootstrap credential."
    ]

    Enum.join(lines, "\n")
  end

  defp render_init_error(code, message, exit_code, true) do
    {:error,
     Jason.encode!(%{object: "error", code: Atom.to_string(code), message: message},
       pretty: true
     ), exit_code}
  end

  defp render_init_error(code, message, exit_code, false) do
    {:error, append_usage(code, "Error: #{message}"), exit_code}
  end

  defp append_usage(:missing_output, text), do: text <> "\n\n" <> init_usage()
  defp append_usage(_code, text), do: text

  defp init_error(%Ecto.Changeset{} = changeset, true) do
    {:error,
     Jason.encode!(
       %{
         object: "error",
         code: "cluster_init_invalid",
         errors: GovernanceHelpers.format_changeset_errors(changeset)
       },
       pretty: true
     ), 1}
  end

  defp init_error(%Ecto.Changeset{} = changeset, false) do
    detail = changeset |> GovernanceHelpers.format_changeset_errors() |> Enum.join("; ")
    {:error, "Error: cluster_init_invalid: #{detail}", 1}
  end

  defp init_error({:database_unavailable, _message} = reason, json?) do
    RepoRuntime.command_error(reason, json?)
  end

  defp init_error(reason, true) when is_atom(reason) do
    {:error, Jason.encode!(%{object: "error", code: Atom.to_string(reason)}, pretty: true), 1}
  end

  defp init_error(reason, false) when is_atom(reason),
    do: {:error, "Error: #{human_init_reason(reason)}", 1}

  defp human_init_reason(:cluster_already_initialized), do: "cluster_already_initialized"
  defp human_init_reason(:controller_standby), do: "this controller is in standby mode."

  defp human_init_reason(:controller_leadership_unproven),
    do: "this controller has not proven local leadership."

  defp human_init_reason(reason), do: Atom.to_string(reason)

  defp run_status(["help"]), do: {:ok, status_usage()}

  defp run_status(args) do
    case parse_status_args(args) do
      {:ok, %{json?: json?}} ->
        RepoRuntime.run(
          fn ->
            status = ControlPlane.read_only_status()
            {:ok, render_status(status, json?)}
          end,
          json: json?
        )

      {:help, usage} ->
        {:ok, usage}

      {:error, message, code} ->
        {:error, message, code}
    end
  end

  defp parse_status_args(args) do
    case OptionParser.parse(args, strict: [json: :boolean, help: :boolean]) do
      {opts, [], []} ->
        if Keyword.get(opts, :help, false) do
          {:help, status_usage()}
        else
          {:ok, %{json?: Keyword.get(opts, :json, false)}}
        end

      {_opts, _rest, [{flag, _value} | _unknown]} ->
        {:error, "Unknown option: #{format_unknown_flag(flag)}", 2}

      _other ->
        {:error, status_usage(), 1}
    end
  end

  defp render_status(%ControlPlaneStatus{} = status, true),
    do: status |> cluster_status_map() |> encode_json()

  defp render_status(%ControlPlaneStatus{} = status, false), do: render_status_text(status)

  defp cluster_status_map(%ControlPlaneStatus{} = status) do
    control_plane = ControlPlaneStatus.to_map(status)

    %{
      object: @cluster_status_object,
      contract_version: @cluster_status_contract_version,
      summary: %{
        deployment_mode: status.deployment_mode,
        controller_role: status.controller_role,
        advisory_lock_status: status.advisory_lock_status
      },
      control_plane: control_plane
    }
  end

  defp render_status_text(%ControlPlaneStatus{} = status) do
    [
      "Role: #{format_status_value(status.controller_role)}",
      "Deployment: #{format_status_value(status.deployment_mode)}",
      "This controller: #{status.this_controller_identity || "unknown"}",
      "Leader: #{status.leader_identity || "unknown"}",
      "Advisory lock: #{format_status_value(status.advisory_lock_status)}",
      "Lock age: #{format_lock_age(status.lock_age_ms)}",
      "Last renewed: #{format_timestamp(status.last_renewed_at)}",
      "Write paths: #{format_status_value(status.standby_write_path_behavior)}",
      leadership_error_line(status.last_observed_leadership_error)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp leadership_error_line(nil), do: nil
  defp leadership_error_line(message), do: "Leadership error: #{message}"

  defp format_lock_age(nil), do: "unknown"
  defp format_lock_age(milliseconds), do: "#{milliseconds} ms"

  defp format_timestamp(nil), do: "unknown"
  defp format_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp format_timestamp(timestamp), do: to_string(timestamp)

  defp format_status_value("active_standby"), do: "Active/Standby"

  defp format_status_value(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.downcase()
  end

  defp format_status_value(value), do: value |> to_string() |> format_status_value()

  defp encode_json(payload), do: Jason.encode!(payload, pretty: true)

  defp format_unknown_flag(flag), do: to_string(flag)

  defp format_file_error({step, reason}),
    do: "#{step}: #{format_file_error(reason)}"

  defp format_file_error(reason) when is_atom(reason),
    do: reason |> :file.format_error() |> to_string()

  defp format_file_error(reason), do: inspect(reason)

  defp file_ops, do: Application.get_env(:orchard_cli, :cluster_file_ops, File)

  defp group_usage do
    """
    Usage: orchardctl cluster <command>

    Commands:
      init     Initialize controller-side cluster bootstrap state (SPEC.md 11.9).
      status   Show read-only cluster and Active/Standby control-plane status.
    """
    |> String.trim()
  end

  defp init_usage do
    """
    Usage: orchardctl cluster init --output <path> [--json] [--client-name <name>] [--force-new-admin --yes]

    Mint the first cluster-admin API Client credential as a local controller-host operation.

    Options:
      --output <path>      Required one-time secret output path.
      --json               Emit stable JSON for automation.
      --client-name <name> API Client name to create.
      --force-new-admin    Mint an additional recovery admin credential.
      --yes                Confirm recovery mint when --force-new-admin is set.
    """
    |> String.trim()
  end

  defp status_usage do
    """
    Usage: orchardctl cluster status [--json]

    Show read-only cluster status, including the Active/Standby control-plane signal category.

    Options:
      --json   Emit stable JSON for automation.
    """
    |> String.trim()
  end
end
