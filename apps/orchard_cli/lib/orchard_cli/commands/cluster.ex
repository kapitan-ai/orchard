defmodule OrchardCLI.Commands.Cluster do
  @moduledoc false

  require Logger

  alias Orchard.ClusterManagement.ControlPlaneStatus
  alias Orchard.ControlPlane
  alias Orchard.Governance.ClusterBootstrap
  alias OrchardCLI.Commands.GovernanceHelpers
  alias OrchardCLI.RepoRuntime

  @cluster_status_object "cluster_management.cluster_status"
  @cluster_status_contract_version "orchard.cluster_management.cluster_status.v1"

  @cluster_init_object "cluster_management.cluster_init"
  @cluster_init_contract_version "orchard.cluster_management.cluster_init.v1"
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

      {:cleanup_unresolved, primary_error, cleanup_error} ->
        render_cleanup_unresolved(primary_error, cleanup_error, json?)

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
        {:cleanup_unresolved, result, reason}
    end
  end

  defp render_cleanup_unresolved(primary_error, cleanup_error, json?) do
    {:error, message, exit_code} = render_primary_init_error(primary_error, json?)
    cleanup_detail = format_file_error(cleanup_error)

    if json? do
      payload =
        message
        |> Jason.decode!()
        |> Map.put("cleanup_unresolved", cleanup_detail)

      {:error, Jason.encode!(payload, pretty: true), exit_code}
    else
      {:error, message <> "\nCleanup unresolved: " <> cleanup_detail, exit_code}
    end
  end

  defp render_primary_init_error({:error, code, message, exit_code}, json?),
    do: render_init_error(code, message, exit_code, json?)

  defp render_primary_init_error({:error, reason}, json?), do: init_error(reason, json?)

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
    with {:ok, parent_identity} <- protected_parent_identity(parent, ops),
         {:ok, io} <- open_output_reservation(path, ops),
         {:ok, reservation} <-
           prepare_output_reservation(path, parent, parent_identity, io, ops) do
      {:ok, reservation}
    else
      {:error, :eexist} ->
        {:error, :output_path_exists, "output path already exists: #{path}", 1}

      {:error, reason} ->
        reservation_error(parent, reason)
    end
  end

  defp protected_parent_identity(parent, ops) do
    case ops.lstat(parent) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        if Bitwise.band(stat.mode, 0o022) == 0 do
          {:ok,
           %{
             immediate: file_identity(stat),
             hierarchy: nil,
             owner_uid: nil
           }}
        else
          {:error, :output_parent_cross_user_writable}
        end

      {:ok, _stat} ->
        {:error, :unexpected_path_type}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_output_reservation(path, ops) do
    ops.open(path, [:write, :exclusive, :binary])
  end

  defp prepare_output_reservation(path, parent, parent_identity, io, ops) do
    case descriptor_stat(io) do
      {:ok, stat} ->
        reservation = %{
          output_path: path,
          output_identity: file_identity(stat),
          parent: parent,
          parent_identity: parent_identity,
          io: io,
          cleanup_io: nil,
          ops: ops
        }

        result =
          with :ok <- ops.chmod(path, 0o600),
               :ok <- verify_path(path, reservation.output_identity, :regular, 0o600, ops),
               {:ok, hierarchy} <- trusted_parent_hierarchy(parent, stat.uid, ops),
               parent_identity = %{
                 parent_identity
                 | hierarchy: hierarchy,
                   owner_uid: stat.uid
               },
               reservation = %{reservation | parent_identity: parent_identity},
               :ok <- verify_protected_parent(reservation),
               :ok <- preflight_descriptor(reservation) do
            bind_cleanup_descriptor(reservation)
          end

        close_failed_reservation(result, reservation)

      {:error, reason} ->
        close_result = ops.close(io)

        {:error,
         preserve_cleanup_result(
           {:output_descriptor_stat, reason},
           descriptor_close: close_result
         )}
    end
  end

  defp close_failed_reservation({:ok, _prepared} = success, _original), do: success

  defp close_failed_reservation({:error, reason}, reservation) do
    cleanup = release_reservation(reservation)
    {:error, preserve_cleanup_result(reason, reservation_release: cleanup)}
  end

  defp preflight_descriptor(reservation) do
    with :ok <- descriptor_position(reservation.ops, reservation.io, :bof),
         :ok <- descriptor_truncate(reservation.ops, reservation.io),
         :ok <- descriptor_sync(reservation.ops, reservation.io),
         :ok <- verify_descriptor(reservation.io, reservation.output_identity) do
      verify_path(
        reservation.output_path,
        reservation.output_identity,
        :regular,
        0o600,
        reservation.ops
      )
    end
  end

  defp bind_cleanup_descriptor(reservation) do
    case reservation.ops.open(reservation.output_path, [:read, :write, :binary]) do
      {:ok, cleanup_io} ->
        prepare_cleanup_descriptor(%{reservation | cleanup_io: cleanup_io})

      {:error, reason} ->
        {:error, {:cleanup_descriptor_open, reason}}
    end
  end

  defp prepare_cleanup_descriptor(reservation) do
    result =
      with :ok <- verify_descriptor(reservation.cleanup_io, reservation.output_identity),
           :ok <- redact_descriptor(reservation.ops, reservation.cleanup_io),
           :ok <- verify_descriptor(reservation.cleanup_io, reservation.output_identity),
           :ok <- verify_protected_parent(reservation) do
        verify_reserved_output(reservation)
      end

    case result do
      :ok ->
        {:ok, reservation}

      {:error, reason} ->
        cleanup = reservation.ops.close(reservation.cleanup_io)

        {:error,
         preserve_cleanup_result(
           {:cleanup_descriptor_prepare, reason},
           cleanup_descriptor_close: cleanup
         )}
    end
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

    with :ok <- verify_protected_parent(reservation),
         :ok <- verify_reserved_output(reservation),
         :ok <- verify_descriptor(reservation.cleanup_io, reservation.output_identity),
         :ok <- write_descriptor(reservation, payload),
         :ok <- verify_descriptor(reservation.io, reservation.output_identity),
         :ok <- verify_descriptor(reservation.cleanup_io, reservation.output_identity),
         :ok <- verify_protected_parent(reservation),
         :ok <- verify_reserved_output(reservation) do
      close_publication_descriptor(reservation)
    else
      {:error, reason} ->
        contain_failed_output(reservation, reason, false)
    end
  end

  defp close_publication_descriptor(reservation) do
    case reservation.ops.close(reservation.io) do
      :ok ->
        finish_committed_output(reservation)

      {:error, reason} ->
        contain_failed_output(reservation, reason, true)
    end
  end

  defp finish_committed_output(reservation) do
    with :ok <- verify_descriptor(reservation.cleanup_io, reservation.output_identity),
         :ok <- verify_protected_parent(reservation),
         :ok <- verify_reserved_output(reservation) do
      close_cleanup_after_commit(reservation)
    else
      {:error, reason} ->
        contain_failed_output(reservation, reason, true)
    end
  end

  defp close_cleanup_after_commit(reservation) do
    case reservation.ops.close(reservation.cleanup_io) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "cluster init recovery descriptor close failed after output commit: " <>
            format_file_error(reason)
        )

        :ok
    end
  end

  defp contain_failed_output(reservation, reason, publication_close_attempted?) do
    message =
      "cluster init minted a credential but One-time Secret Output failed: " <>
        format_file_error(reason)

    {:error, cleanup_message} =
      contain_failed_cleanup(reservation, publication_close_attempted?)

    {:error, message <> "; " <> cleanup_message}
  end

  defp contain_failed_cleanup(reservation, publication_close_attempted?) do
    containment = [
      plaintext_redaction: redact_reservation(reservation),
      publication_descriptor_close:
        close_publication_after_abort(reservation, publication_close_attempted?),
      cleanup_descriptor_close: close_cleanup_descriptor(reservation)
    ]

    detail =
      containment
      |> Enum.reject(fn {_step, result} -> result == :ok end)
      |> inspect()

    {:error,
     "cluster init minted a credential but descriptor-bound cleanup was required; " <>
       "containment=#{detail}"}
  end

  defp release_reservation(reservation) do
    results = [
      plaintext_redaction: redact_reservation(reservation),
      publication_descriptor_close: reservation.ops.close(reservation.io),
      cleanup_descriptor_close: close_cleanup_descriptor(reservation)
    ]

    case Enum.reject(results, fn {_step, result} -> result == :ok end) do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  defp close_publication_after_abort(_reservation, true), do: :ok

  defp close_publication_after_abort(reservation, false),
    do: reservation.ops.close(reservation.io)

  defp close_cleanup_descriptor(%{cleanup_io: nil}), do: :ok

  defp close_cleanup_descriptor(reservation),
    do: reservation.ops.close(reservation.cleanup_io)

  defp write_descriptor(reservation, contents) do
    with :ok <- descriptor_write(reservation.ops, reservation.io, contents),
         do: descriptor_sync(reservation.ops, reservation.io)
  end

  defp redact_descriptor(ops, io) do
    with :ok <- descriptor_position(ops, io, :bof),
         :ok <- descriptor_truncate(ops, io),
         do: descriptor_sync(ops, io)
  end

  defp redact_reservation(reservation) do
    redact_descriptor(
      reservation.ops,
      reservation.cleanup_io || reservation.io
    )
  end

  defp descriptor_write(ops, io, contents) do
    if ops != File and function_exported?(ops, :write, 2),
      do: ops.write(io, contents),
      else: IO.binwrite(io, contents)
  end

  defp descriptor_sync(ops, io) do
    if ops != File and function_exported?(ops, :sync, 1),
      do: ops.sync(io),
      else: :file.sync(io)
  end

  defp descriptor_position(ops, io, position) do
    result =
      if ops != File and function_exported?(ops, :position, 2),
        do: ops.position(io, position),
        else: :file.position(io, position)

    case result do
      {:ok, _position} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp descriptor_truncate(ops, io) do
    if ops != File and function_exported?(ops, :truncate, 1),
      do: ops.truncate(io),
      else: :file.truncate(io)
  end

  defp verify_descriptor(io, identity) do
    case descriptor_identity(io) do
      {:ok, ^identity} -> :ok
      {:ok, _other} -> {:error, :output_descriptor_identity_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_reserved_output(reservation) do
    verify_path(
      reservation.output_path,
      reservation.output_identity,
      :regular,
      0o600,
      reservation.ops
    )
  end

  defp verify_protected_parent(reservation) do
    verify_protected_parent(
      reservation.parent,
      reservation.parent_identity,
      reservation.ops
    )
  end

  defp verify_protected_parent(
         _parent,
         %{hierarchy: hierarchy, owner_uid: owner_uid},
         ops
       )
       when is_list(hierarchy) and is_integer(owner_uid),
       do: verify_parent_hierarchy(hierarchy, owner_uid, ops)

  defp verify_protected_parent(parent, %{immediate: expected_identity}, ops) do
    with :ok <-
           verify_path(
             parent,
             expected_identity,
             :directory,
             nil,
             ops
           ),
         {:ok, parent_identity} <-
           protected_parent_identity(parent, ops),
         true <- parent_identity.immediate == expected_identity do
      :ok
    else
      false -> {:error, :output_parent_identity_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp trusted_parent_hierarchy(parent, owner_uid, ops) do
    parent
    |> parent_component_paths()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, hierarchy} ->
      case trusted_parent_component(path, owner_uid, ops) do
        {:ok, component} -> {:cont, {:ok, [component | hierarchy]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hierarchy} -> {:ok, Enum.reverse(hierarchy)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp trusted_parent_component(path, owner_uid, ops) do
    with {:ok, lexical_stat} <- ops.lstat(path),
         :ok <- verify_lexical_parent_component(lexical_stat, owner_uid, path),
         {:ok, %File.Stat{type: :directory} = target_stat} <- ops.stat(path),
         true <-
           trusted_parent_owner?(target_stat.uid, owner_uid) and
             trusted_parent_mode?(target_stat.mode) do
      {:ok, {path, file_identity(lexical_stat), file_identity(target_stat)}}
    else
      false -> {:error, {:output_parent_hierarchy_untrusted, path}}
      {:ok, _stat} -> {:error, :unexpected_path_type}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_lexical_parent_component(
         %File.Stat{type: :directory, uid: uid, mode: mode},
         owner_uid,
         path
       ) do
    if trusted_parent_owner?(uid, owner_uid) and trusted_parent_mode?(mode),
      do: :ok,
      else: {:error, {:output_parent_hierarchy_untrusted, path}}
  end

  defp verify_lexical_parent_component(
         %File.Stat{type: :symlink, uid: uid},
         owner_uid,
         path
       ) do
    if trusted_parent_owner?(uid, owner_uid),
      do: :ok,
      else: {:error, {:output_parent_hierarchy_untrusted, path}}
  end

  defp verify_lexical_parent_component(_stat, _owner_uid, _path),
    do: {:error, :unexpected_path_type}

  defp verify_parent_hierarchy(hierarchy, owner_uid, ops) do
    Enum.reduce_while(hierarchy, :ok, fn
      {path, expected_lexical_identity, expected_target_identity}, :ok ->
        case trusted_parent_component(path, owner_uid, ops) do
          {:ok, {^path, ^expected_lexical_identity, ^expected_target_identity}} -> {:cont, :ok}
          {:ok, _other} -> {:halt, {:error, :output_parent_identity_changed}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp trusted_parent_owner?(uid, owner_uid), do: uid == owner_uid or uid == 0

  defp trusted_parent_mode?(mode) do
    Bitwise.band(mode, 0o022) == 0 or Bitwise.band(mode, 0o1000) != 0
  end

  defp parent_component_paths(parent) do
    [root | components] = Path.split(parent)
    [root | Enum.scan(components, root, fn component, path -> Path.join(path, component) end)]
  end

  defp preserve_cleanup_result(reason, cleanup_results) do
    case Enum.reject(cleanup_results, fn {_step, result} -> result == :ok end) do
      [] -> reason
      failures -> {:cleanup_unresolved, reason, failures}
    end
  end

  defp descriptor_identity(io) do
    with {:ok, stat} <- descriptor_stat(io), do: {:ok, file_identity(stat)}
  end

  defp descriptor_stat(io) do
    case :file.read_file_info(io) do
      {:ok, record} -> {:ok, File.Stat.from_record(record)}
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

  defp file_identity(%File.Stat{} = stat) do
    {stat.type, stat.major_device, stat.minor_device, stat.inode}
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
