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
    with {:ok, initial_parent_identity} <- protected_parent_identity(parent, ops),
         {:ok, parent_identity} <-
           verify_parent_directory_cleanup(path, parent, initial_parent_identity, ops),
         {:ok, reservation} <-
           create_reservation(path, parent, parent_identity, ops, @reservation_attempts) do
      verify_reservation_cleanup(reservation)
    else
      {:error, reason} -> reservation_error(parent, reason)
    end
  end

  defp verify_parent_directory_cleanup(path, parent, parent_identity, ops) do
    case create_parent_probe(path, parent, parent_identity, ops, @reservation_attempts) do
      {:ok, probe_path, probe_identity, owner_uid, hierarchy} ->
        complete_parent_probe(
          probe_path,
          probe_identity,
          owner_uid,
          hierarchy,
          parent_identity,
          ops
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_parent_probe(
         probe_path,
         probe_identity,
         owner_uid,
         hierarchy,
         parent_identity,
         ops
       ) do
    case remove_owned_directory(probe_path, probe_identity, ops) do
      :ok ->
        with :ok <- verify_parent_hierarchy(hierarchy, owner_uid, ops) do
          {:ok, %{parent_identity | hierarchy: hierarchy, owner_uid: owner_uid}}
        end

      {:error, reason} ->
        cleanup_retry = remove_owned_directory(probe_path, probe_identity, ops)

        {:error,
         preserve_cleanup_result(
           {:parent_directory_probe_cleanup, reason},
           parent_probe_cleanup_retry: cleanup_retry
         )}
    end
  end

  defp create_parent_probe(_path, _parent, _parent_identity, _ops, 0),
    do: {:error, :parent_directory_probe_collision}

  defp create_parent_probe(path, parent, parent_identity, ops, attempts_left) do
    probe_path =
      Path.join(
        parent,
        ".#{Path.basename(path)}.preflight-dir-#{System.unique_integer([:positive])}"
      )

    case ops.mkdir(probe_path) do
      :ok ->
        prepare_parent_probe(probe_path, parent, parent_identity, ops)

      {:error, :eexist} ->
        create_parent_probe(path, parent, parent_identity, ops, attempts_left - 1)

      {:error, reason} ->
        {:error, {:parent_directory_probe_create, reason}}
    end
  end

  defp prepare_parent_probe(probe_path, parent, parent_identity, ops) do
    case ops.lstat(probe_path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        probe_identity = file_identity(stat)

        result =
          with :ok <- ops.chmod(probe_path, 0o700),
               :ok <- verify_path(probe_path, probe_identity, :directory, 0o700, ops),
               :ok <- verify_protected_parent(parent, parent_identity, ops),
               {:ok, hierarchy} <- trusted_parent_hierarchy(parent, stat.uid, ops) do
            {:ok, probe_path, probe_identity, stat.uid, hierarchy}
          end

        cleanup_failed_parent_probe(result, probe_path, probe_identity, ops)

      {:ok, _stat} ->
        {:error, :parent_directory_probe_type_changed}

      {:error, reason} ->
        {:error, {:parent_directory_probe_stat, reason}}
    end
  end

  defp cleanup_failed_parent_probe(
         {:ok, _result_path, _result_identity, _owner_uid, _hierarchy} = success,
         _argument_path,
         _argument_identity,
         _ops
       ),
       do: success

  defp cleanup_failed_parent_probe(
         {:error, reason},
         probe_path,
         probe_identity,
         ops
       ) do
    cleanup = remove_owned_directory(probe_path, probe_identity, ops)

    {:error,
     preserve_cleanup_result(
       {:parent_directory_probe_prepare, reason},
       parent_probe_cleanup: cleanup
     )}
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

  defp create_reservation(_path, _parent, _parent_identity, _ops, 0),
    do: {:error, :staging_collision}

  defp create_reservation(path, parent, parent_identity, ops, attempts_left) do
    staging_dir =
      Path.join(
        parent,
        ".#{Path.basename(path)}.staging-#{System.unique_integer([:positive])}"
      )

    case ops.mkdir(staging_dir) do
      :ok ->
        build_reservation(path, parent, parent_identity, staging_dir, ops)

      {:error, :eexist} ->
        create_reservation(path, parent, parent_identity, ops, attempts_left - 1)

      {:error, reason} ->
        {:error, {:staging_directory_create, reason}}
    end
  end

  defp build_reservation(path, parent, parent_identity, staging_dir, ops) do
    case ops.lstat(staging_dir) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        prepare_staging_directory(
          path,
          parent,
          parent_identity,
          staging_dir,
          file_identity(stat),
          ops
        )

      {:ok, _stat} ->
        {:error, {:staging_directory_prepare, :unexpected_path_type}}

      {:error, reason} ->
        {:error, {:staging_directory_stat, reason}}
    end
  end

  defp prepare_staging_directory(
         path,
         parent,
         parent_identity,
         staging_dir,
         directory_identity,
         ops
       ) do
    with :ok <- ops.chmod(staging_dir, 0o700),
         :ok <- verify_path(staging_dir, directory_identity, :directory, 0o700, ops) do
      open_reserved_file(
        path,
        parent,
        parent_identity,
        staging_dir,
        directory_identity,
        ops
      )
    else
      {:error, reason} ->
        cleanup = remove_owned_directory(staging_dir, directory_identity, ops)

        {:error,
         preserve_cleanup_result(
           {:staging_directory_prepare, reason},
           staging_directory_cleanup: cleanup
         )}
    end
  end

  defp open_reserved_file(
         path,
         parent,
         parent_identity,
         staging_dir,
         directory_identity,
         ops
       ) do
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
          parent_identity,
          staging_dir,
          staging_path,
          directory_identity,
          io,
          ops
        )

      {:error, reason} ->
        cleanup = remove_owned_directory(staging_dir, directory_identity, ops)

        {:error,
         preserve_cleanup_result(
           {:staging_file_create, reason},
           staging_directory_cleanup: cleanup
         )}
    end
  end

  defp secure_reserved_file(
         path,
         parent,
         parent_identity,
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
               parent_identity: parent_identity,
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
        close_result = ops.close(io)
        directory_cleanup = remove_owned_directory(staging_dir, directory_identity, ops)

        {:error,
         preserve_cleanup_result(
           {:staging_descriptor_stat, reason},
           descriptor_close: close_result,
           staging_directory_cleanup: directory_cleanup
         )}
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
    close_result = ops.close(io)
    staging_cleanup = remove_owned_path(staging_path, staging_identity, ops)
    directory_cleanup = remove_owned_directory(staging_dir, directory_identity, ops)

    {:error,
     preserve_cleanup_result(
       {:staging_file_prepare, reason},
       descriptor_close: close_result,
       staging_file_cleanup: staging_cleanup,
       staging_directory_cleanup: directory_cleanup
     )}
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
            cleanup_retry = remove_owned_path(probe_path, probe_identity, reservation.ops)

            fail_reservation_probe(
              reservation,
              preserve_cleanup_result(
                {:probe_cleanup, reason},
                probe_cleanup_retry: cleanup_retry
              )
            )
        end

      {:error, reason} ->
        close_result = reservation.ops.close(io)

        fail_reservation_probe(
          reservation,
          preserve_cleanup_result(
            {:probe_descriptor_stat, reason},
            probe_descriptor_close: close_result
          )
        )
    end
  end

  defp fail_reservation_probe(reservation, reason) do
    release_result = release_reservation(reservation)

    reservation_error(
      reservation.parent,
      preserve_cleanup_result(reason, reservation_release: release_result)
    )
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
         :ok <-
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
         :ok <- reservation.ops.close(reservation.io),
         :ok <- verify_protected_parent(reservation),
         :ok <- verify_published_output(reservation) do
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
      plaintext_redaction: redact_reservation(reservation),
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
      plaintext_redaction: redact_reservation(reservation),
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

  defp redact_reservation(reservation) do
    case redact_descriptor(reservation.io) do
      :ok ->
        :ok

      {:error, reason} ->
        paths = [reservation.staging_path, reservation.output_path]

        case redact_identity_bound_path(paths, reservation.staging_identity, reservation.ops) do
          :ok -> {:error, {:descriptor_redaction_failed, reason, :fallback_redacted}}
          {:error, fallback} -> {:error, {:plaintext_redaction_unresolved, reason, fallback}}
        end
    end
  end

  defp redact_identity_bound_path(paths, identity, ops),
    do: redact_identity_bound_path(paths, identity, ops, [])

  defp redact_identity_bound_path([], _identity, _ops, failures),
    do: {:error, Enum.reverse(failures)}

  defp redact_identity_bound_path([path | rest], identity, ops, failures) do
    case redact_opened_path(path, identity, ops) do
      :ok ->
        :ok

      {:redacted, close_error} ->
        {:error, [{path, {:descriptor_close, close_error}} | failures]}

      {:error, reason} ->
        redact_identity_bound_path(rest, identity, ops, [{path, reason} | failures])
    end
  end

  defp redact_opened_path(path, identity, ops) do
    case ops.open(path, [:read, :write, :binary]) do
      {:ok, io} ->
        verification = verify_descriptor(io, identity)
        redaction = if verification == :ok, do: redact_descriptor(io), else: verification
        close_result = ops.close(io)
        opened_path_redaction_result(redaction, close_result)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp opened_path_redaction_result(:ok, :ok), do: :ok
  defp opened_path_redaction_result(:ok, {:error, reason}), do: {:redacted, reason}
  defp opened_path_redaction_result({:error, reason}, _close_result), do: {:error, reason}

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

  defp file_identity(%File.Stat{} = stat) do
    {stat.type, stat.major_device, stat.minor_device, stat.inode}
  end

  defp remove_owned_path(path, identity, ops),
    do: remove_owned_via_quarantine(path, identity, :regular, ops, :rm)

  defp remove_owned_directory(path, identity, ops),
    do: remove_owned_via_quarantine(path, identity, :directory, ops, :rmdir)

  defp remove_owned_via_quarantine(path, identity, type, ops, operation) do
    case ops.lstat(path) do
      {:ok, stat} ->
        quarantine_if_identity_matches(path, stat, identity, type, ops, operation)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp quarantine_if_identity_matches(path, stat, identity, type, ops, operation) do
    if file_identity(stat) == identity and stat.type == type do
      create_cleanup_quarantine(path, identity, type, ops, operation, @reservation_attempts)
    else
      {:error, :path_identity_changed}
    end
  end

  defp create_cleanup_quarantine(_path, _identity, _type, _ops, _operation, 0),
    do: {:error, :cleanup_quarantine_collision}

  defp create_cleanup_quarantine(path, identity, type, ops, operation, attempts_left) do
    quarantine_dir =
      Path.join(
        Path.dirname(path),
        ".orchard-cleanup-#{System.unique_integer([:positive])}"
      )

    case ops.mkdir(quarantine_dir) do
      :ok ->
        prepare_cleanup_quarantine(path, identity, type, quarantine_dir, ops, operation)

      {:error, :eexist} ->
        create_cleanup_quarantine(path, identity, type, ops, operation, attempts_left - 1)

      {:error, reason} ->
        {:error, {:cleanup_quarantine_create, reason}}
    end
  end

  defp prepare_cleanup_quarantine(path, identity, type, quarantine_dir, ops, operation) do
    case ops.lstat(quarantine_dir) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        directory_identity = file_identity(stat)

        case secure_cleanup_quarantine(quarantine_dir, directory_identity, ops) do
          :ok ->
            move_to_cleanup_quarantine(
              path,
              identity,
              type,
              quarantine_dir,
              directory_identity,
              ops,
              operation
            )

          {:error, reason} ->
            cleanup = remove_owned(quarantine_dir, directory_identity, ops, :rmdir)

            {:error,
             preserve_cleanup_result(
               {:cleanup_quarantine_prepare, reason},
               cleanup_quarantine: cleanup
             )}
        end

      {:ok, _stat} ->
        {:error, :cleanup_quarantine_type_changed}

      {:error, reason} ->
        {:error, {:cleanup_quarantine_stat, reason}}
    end
  end

  defp secure_cleanup_quarantine(quarantine_dir, directory_identity, ops) do
    with :ok <- ops.chmod(quarantine_dir, 0o700) do
      verify_path(quarantine_dir, directory_identity, :directory, 0o700, ops)
    end
  end

  defp move_to_cleanup_quarantine(
         path,
         identity,
         type,
         quarantine_dir,
         directory_identity,
         ops,
         operation
       ) do
    quarantine_path = Path.join(quarantine_dir, Path.basename(path))

    case ops.rename(path, quarantine_path) do
      :ok ->
        verify_and_remove_quarantined(
          identity,
          type,
          quarantine_path,
          quarantine_dir,
          directory_identity,
          ops,
          operation
        )

      {:error, reason} ->
        cleanup = remove_owned(quarantine_dir, directory_identity, ops, :rmdir)

        {:error,
         preserve_cleanup_result(
           {:cleanup_quarantine_move, reason},
           cleanup_quarantine: cleanup
         )}
    end
  end

  defp verify_and_remove_quarantined(
         identity,
         type,
         quarantine_path,
         quarantine_dir,
         directory_identity,
         ops,
         operation
       ) do
    case ops.lstat(quarantine_path) do
      {:ok, stat} when stat.type == type ->
        if file_identity(stat) == identity do
          remove_quarantined(
            identity,
            quarantine_path,
            quarantine_dir,
            directory_identity,
            ops,
            operation
          )
        else
          {:error, {:path_identity_changed, {:preserved_at, quarantine_path}}}
        end

      {:ok, _stat} ->
        {:error, {:unexpected_path_type, {:preserved_at, quarantine_path}}}

      {:error, reason} ->
        {:error, {:cleanup_quarantine_verify, reason}}
    end
  end

  defp remove_quarantined(
         identity,
         quarantine_path,
         quarantine_dir,
         directory_identity,
         ops,
         operation
       ) do
    case remove_verified_path(quarantine_path, ops, operation) do
      :ok ->
        remove_owned(quarantine_dir, directory_identity, ops, :rmdir)

      {:error, reason} ->
        redaction =
          if operation == :rm,
            do: redact_identity_bound_path([quarantine_path], identity, ops),
            else: :ok

        {:error,
         preserve_cleanup_result(
           {:cleanup_quarantine_remove, reason},
           plaintext_redaction: redaction
         )}
    end
  end

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
