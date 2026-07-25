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
  @cluster_init_contract_version "orchard.cluster_management.cluster_init.v2"

  @private_directory_mode 0o700
  @secret_file_mode 0o600
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
           :ok <- confirm_recovery(opts),
           {:ok, reservation} <- reserve_output(output_path) do
        mint_reserved_admin(opts, reservation, json?)
      end

    render_init_result(result, json?)
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
      :ok -> result
      {:error, reason} -> {:cleanup_unresolved, result, reason}
    end
  end

  defp render_init_result({:ok, _message} = success, _json?), do: success

  defp render_init_result({:cleanup_unresolved, primary_error, cleanup_error}, json?) do
    primary_error
    |> render_init_result(json?)
    |> decorate_error(
      json?,
      "cleanup_unresolved",
      "Cleanup unresolved",
      format_file_error(cleanup_error)
    )
  end

  defp render_init_result({:output_failure, code, message, details, exit_code}, true) do
    payload =
      details
      |> Map.merge(%{
        object: "error",
        contract_version: @cluster_init_contract_version,
        code: Atom.to_string(code),
        message: message
      })

    {:error, Jason.encode!(payload, pretty: true), exit_code}
  end

  defp render_init_result({:output_failure, _code, message, _details, exit_code}, false),
    do: {:error, "Error: " <> message, exit_code}

  defp render_init_result({:error, code, message, exit_code}, json?),
    do: render_init_error(code, message, exit_code, json?)

  defp render_init_result({:error, reason}, json?), do: init_error(reason, json?)

  defp decorate_error({:error, message, exit_code}, true, key, _label, detail) do
    payload = message |> Jason.decode!() |> Map.put(key, detail)
    {:error, Jason.encode!(payload, pretty: true), exit_code}
  end

  defp decorate_error({:error, message, exit_code}, false, _key, label, detail),
    do: {:error, message <> "\n" <> label <> ": " <> detail, exit_code}

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
         {:ok, staging_dir, staging_path, io} <- open_output_reservation(parent, ops),
         {:ok, reservation} <-
           prepare_output_reservation(
             path,
             parent,
             parent_identity,
             staging_dir,
             staging_path,
             io,
             ops
           ) do
      {:ok, reservation}
    else
      {:error, :eexist} ->
        {:error, :output_path_exists, "output path already exists: #{path}", 1}

      {:error, reason} ->
        reservation_error(path, parent, reason)
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

  defp open_output_reservation(parent, ops) do
    staging_dir =
      Path.join(parent, ".orchard-cluster-init-#{Ecto.UUID.generate()}")

    staging_path = Path.join(staging_dir, "credential")

    with :ok <- ops.mkdir(staging_dir),
         :ok <- ops.chmod(staging_dir, @private_directory_mode),
         {:ok, io} <- ops.open(staging_path, [:write, :exclusive, :binary]) do
      {:ok, staging_dir, staging_path, io}
    else
      {:error, reason} ->
        cleanup = cleanup_unopened_staging_directory(staging_dir, ops)
        {:error, preserve_cleanup_result(reason, staging_cleanup: cleanup)}
    end
  end

  defp prepare_output_reservation(
         path,
         parent,
         parent_identity,
         staging_dir,
         staging_path,
         io,
         ops
       ) do
    case descriptor_stat(io) do
      {:ok, stat} ->
        reservation = %{
          output_path: path,
          output_identity: file_identity(stat),
          parent: parent,
          parent_identity: parent_identity,
          staging_dir: staging_dir,
          staging_path: staging_path,
          io: io,
          cleanup_io: nil,
          ops: ops
        }

        result =
          with :ok <- ops.chmod(staging_path, @secret_file_mode),
               :ok <- verify_bound_output(reservation),
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
      verify_bound_output(reservation)
    end
  end

  defp install_reserved_output(reservation) do
    with :ok <- reservation.ops.ln(reservation.staging_path, reservation.output_path),
         :ok <- verify_reserved_output(reservation),
         :ok <- sync_output_directory(reservation),
         :ok <- verify_bound_output(reservation),
         :ok <- reservation.ops.rm(reservation.staging_path),
         :ok <- reservation.ops.rmdir(reservation.staging_dir),
         :ok <- sync_output_directory(reservation) do
      {:ok, %{reservation | staging_dir: nil, staging_path: nil}}
    end
  end

  defp bind_cleanup_descriptor(reservation) do
    case reservation.ops.open(reservation.staging_path, [:read, :write, :binary]) do
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
        verify_bound_output(reservation)
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

  defp reservation_error(path, parent, {:cleanup_unresolved, reason, failures}),
    do: {:cleanup_unresolved, reservation_error(path, parent, reason), failures}

  defp reservation_error(path, parent, reason) do
    detail = format_file_error(reason)

    case reservation_category(reason) do
      :parent_untrusted ->
        {:error, :output_parent_not_writable,
         "output parent directory is not writable: #{parent}: #{detail}", 1}

      :parent_missing ->
        {:error, :output_parent_missing,
         "output parent directory does not exist: #{parent}: #{detail}", 1}

      :identity_changed ->
        {:error, :output_path_identity_changed,
         "output path identity changed during reservation: #{path}: #{detail}", 1}

      :mode_changed ->
        {:error, :output_path_mode_changed,
         "output path protection is no longer 0600 during reservation: #{path}: #{detail}", 1}

      :reservation_failed ->
        {:error, :output_reservation_failed, "output path reservation failed: #{path}: #{detail}",
         1}
    end
  end

  defp reservation_category({:output_parent_hierarchy_untrusted, _path}), do: :parent_untrusted
  defp reservation_category(:output_parent_cross_user_writable), do: :parent_untrusted

  defp reservation_category({:reserved_output_path, reason}), do: reserved_path_category(reason)

  defp reservation_category({:cleanup_descriptor_open, reason}),
    do: reserved_path_category(reason)

  defp reservation_category(reason) when reason in [:eacces, :eperm, :erofs],
    do: :parent_untrusted

  defp reservation_category(reason) when reason in [:enoent, :enotdir], do: :parent_missing

  defp reservation_category(reason)
       when reason in [
              :path_identity_changed,
              :output_parent_identity_changed,
              :output_descriptor_identity_changed,
              :unexpected_path_type
            ],
       do: :identity_changed

  defp reservation_category(:unsafe_mode), do: :mode_changed
  defp reservation_category({_step, reason}), do: reservation_category(reason)
  defp reservation_category(_reason), do: :reservation_failed

  defp reserved_path_category(reason) when reason in [:enoent, :enotdir], do: :identity_changed
  defp reserved_path_category(reason), do: reservation_category(reason)

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
      {:ok, warnings} ->
        {:ok, render_init_success(result, reservation.output_path, warnings, json?)}

      {:error, failure} ->
        render_output_failure(result, reservation, failure)
    end
  end

  defp render_output_failure(result, reservation, failure) do
    contained? = plaintext_contained?(failure)
    code = output_failure_code(contained?)

    message =
      [
        operator_output_failure(failure),
        containment_guidance(reservation, result, contained?),
        output_failed_persistence_warning(
          mark_output_failed(result, persisted_output_failure(failure))
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    {:output_failure, code, message,
     output_failure_details(result, reservation, failure, contained?), 1}
  end

  defp plaintext_contained?(failure),
    do: Keyword.get(failure.containment, :plaintext_redaction) == :ok

  defp output_failure_code(true), do: :one_time_secret_output_unconfirmed
  defp output_failure_code(false), do: :one_time_secret_containment_unresolved

  defp output_failure_details(result, reservation, failure, contained?) do
    %{
      credential_authority: "committed_active",
      publication: "unconfirmed",
      containment: if(contained?, do: "confirmed_logical", else: "unresolved"),
      plaintext_may_remain: true,
      recovery_required: true,
      api_token_prefix: result.api_token_prefix,
      output_path: reservation.output_path,
      failure_category: failure_category(failure.reason),
      cleanup_failures: public_containment_failures(failure.containment),
      recovery_actions: recovery_actions(result, reservation)
    }
  end

  defp public_containment_failures(containment) do
    Enum.map(containment_failures(containment), fn {step, result} ->
      %{
        step: Atom.to_string(step),
        category: containment_result_category(result)
      }
    end)
  end

  defp recovery_actions(result, reservation) do
    [
      "Revoke API token prefix #{result.api_token_prefix}.",
      "Inspect #{reservation.parent} before cleanup; never delete the selected pathname unless its identity is independently verified.",
      "After revocation, retry with --force-new-admin --yes and a different --output path."
    ]
  end

  defp operator_output_failure(failure) do
    reason_text =
      "cluster init minted a credential but One-time Secret Output failed: " <>
        format_file_error(failure.reason)

    case containment_failures(failure.containment) do
      [] ->
        reason_text

      failures ->
        reason_text <> "; descriptor-bound containment incomplete: " <> inspect(failures)
    end
  end

  defp persisted_output_failure(failure) do
    category =
      failure
      |> plaintext_contained?()
      |> output_failure_code()
      |> Atom.to_string()
      |> Kernel.<>(":" <> failure_category(failure.reason))

    case containment_failures(failure.containment) do
      [] ->
        category

      failures ->
        category <>
          "; containment_unresolved:" <>
          Enum.map_join(failures, ",", fn {step, result} ->
            Atom.to_string(step) <> "=" <> containment_result_category(result)
          end)
    end
  end

  defp containment_result_category({:error, reason}), do: failure_category(reason)
  defp containment_result_category(_result), do: "unclassified"

  defp failure_category({:output_parent_hierarchy_untrusted, _path}),
    do: "output_parent_hierarchy_untrusted"

  defp failure_category({step, reason}) when is_atom(step),
    do: Atom.to_string(step) <> "." <> failure_category(reason)

  defp failure_category(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_category(_reason), do: "unclassified"

  defp containment_failures(containment),
    do: Enum.reject(containment, fn {_step, result} -> result == :ok end)

  defp containment_guidance(reservation, result, true) do
    "Publication is unconfirmed after credential commit. Logical plaintext containment was " <>
      "confirmed through the bound descriptor. Plaintext may remain on storage media because " <>
      "this is not a physical-media sanitization claim. Revoke API token prefix " <>
      "#{result.api_token_prefix}, inspect #{reservation.parent}, and retry with " <>
      "--force-new-admin --yes against a different --output path. Never delete " <>
      "#{reservation.output_path} unless its identity is independently verified because it " <>
      "may name unrelated data."
  end

  defp containment_guidance(reservation, result, false) do
    "Manual containment required: descriptor-bound redaction failed, so plaintext may remain " <>
      "in the protected staging namespace within #{reservation.parent} or through an externally " <>
      "retained descriptor. Revoke API token prefix #{result.api_token_prefix} before retrying. " <>
      "Never delete #{reservation.output_path} unless its identity is independently verified " <>
      "because it may name unrelated data."
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
         :ok <- verify_bound_output(reservation),
         :ok <- verify_descriptor(reservation.cleanup_io, reservation.output_identity),
         :ok <- write_descriptor(reservation, payload),
         :ok <- verify_descriptor(reservation.io, reservation.output_identity),
         :ok <- verify_descriptor(reservation.cleanup_io, reservation.output_identity),
         :ok <- verify_protected_parent(reservation),
         :ok <- verify_bound_output(reservation) do
      close_publication_descriptor(reservation)
    else
      {:error, reason} ->
        contain_failed_output(reservation, reason, false)
    end
  end

  defp close_publication_descriptor(reservation) do
    case reservation.ops.close(reservation.io) do
      :ok ->
        case install_reserved_output(reservation) do
          {:ok, committed_reservation} ->
            finish_committed_output(committed_reservation)

          {:error, reason} ->
            contain_failed_output(reservation, reason, true)
        end

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
        {:ok, []}

      {:error, reason} ->
        Logger.warning(
          "cluster init recovery descriptor close failed after output commit: " <>
            format_file_error(reason)
        )

        {:ok, ["cleanup_descriptor_close_unconfirmed"]}
    end
  end

  defp contain_failed_output(reservation, reason, publication_close_attempted?) do
    {:error,
     %{
       reason: reason,
       containment: contain_reservation(reservation, publication_close_attempted?)
     }}
  end

  defp contain_reservation(reservation, publication_close_attempted?) do
    [
      plaintext_redaction: redact_reservation(reservation, not publication_close_attempted?),
      publication_descriptor_close:
        close_publication_after_abort(reservation, publication_close_attempted?),
      cleanup_descriptor_close: close_cleanup_descriptor(reservation),
      staging_metadata_cleanup: cleanup_staging_metadata(reservation)
    ]
  end

  defp release_reservation(reservation) do
    containment = contain_reservation(reservation, false)

    case containment_failures(containment) do
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

  defp redact_reservation(reservation, publication_usable?) do
    primary = reservation.cleanup_io || reservation.io

    case redact_descriptor(reservation.ops, primary) do
      :ok ->
        :ok

      {:error, reason} ->
        redact_via_publication(reservation, primary, publication_usable?, reason)
    end
  end

  defp redact_via_publication(reservation, primary, publication_usable?, reason) do
    if publication_usable? and primary != reservation.io do
      case redact_descriptor(reservation.ops, reservation.io) do
        :ok -> :ok
        {:error, _fallback_reason} -> {:error, reason}
      end
    else
      {:error, reason}
    end
  end

  defp descriptor_write(ops, io, contents) do
    if descriptor_ops?(ops, :write, 2),
      do: ops.write(io, contents),
      else: IO.binwrite(io, contents)
  end

  defp descriptor_sync(ops, io) do
    if descriptor_ops?(ops, :sync, 1),
      do: ops.sync(io),
      else: :file.sync(io)
  end

  defp descriptor_position(ops, io, position) do
    result =
      if descriptor_ops?(ops, :position, 2),
        do: ops.position(io, position),
        else: :file.position(io, position)

    case result do
      {:ok, _position} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp descriptor_truncate(ops, io) do
    if descriptor_ops?(ops, :truncate, 1),
      do: ops.truncate(io),
      else: :file.truncate(io)
  end

  defp sync_output_directory(reservation) do
    if descriptor_ops?(reservation.ops, :sync_directory, 1),
      do: reservation.ops.sync_directory(reservation.parent),
      else: sync_directory(reservation.parent)
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, directory} ->
        sync_result = :file.sync(directory)
        close_result = :file.close(directory)

        if sync_result == :ok and close_result == :ok,
          do: :ok,
          else: {:error, :eio}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp descriptor_ops?(ops, function, arity) do
    ops != File and Code.ensure_loaded?(ops) and function_exported?(ops, function, arity)
  end

  defp verify_descriptor(io, identity) do
    case descriptor_identity(io) do
      {:ok, ^identity} -> :ok
      {:ok, _other} -> {:error, :output_descriptor_identity_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_reserved_output(reservation) do
    verify_reserved_path(
      reservation.output_path,
      reservation.output_identity,
      reservation.ops
    )
  end

  defp verify_bound_output(reservation) do
    verify_reserved_path(
      reservation.staging_path,
      reservation.output_identity,
      reservation.ops
    )
  end

  defp verify_reserved_path(path, identity, ops) do
    case verify_path(path, identity, :regular, 0o600, ops) do
      :ok -> :ok
      {:error, reason} -> {:error, {:reserved_output_path, reason}}
    end
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

  defp cleanup_staging_metadata(%{staging_dir: nil, staging_path: nil}), do: :ok

  defp cleanup_staging_metadata(reservation) do
    path_result = remove_reserved_staging_if_present(reservation)
    directory_result = remove_directory_if_present(reservation.staging_dir, reservation.ops)

    preserve_cleanup_result(:staging_cleanup,
      staging_path: path_result,
      staging_dir: directory_result
    )
    |> case do
      :staging_cleanup -> :ok
      {:cleanup_unresolved, :staging_cleanup, failures} -> {:error, failures}
    end
  end

  defp cleanup_unopened_staging_directory(staging_dir, ops),
    do: remove_directory_if_present(staging_dir, ops)

  defp remove_reserved_staging_if_present(reservation) do
    case verify_bound_output(reservation) do
      :ok -> remove_if_present(reservation.staging_path, reservation.ops)
      {:error, {:reserved_output_path, :enoent}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_if_present(path, ops) do
    case ops.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_directory_if_present(path, ops) do
    case ops.rmdir(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
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

  defp render_init_success(result, output_path, warnings, true) do
    Jason.encode!(
      %{
        object: @cluster_init_object,
        contract_version: @cluster_init_contract_version,
        credential_authority: "committed_active",
        publication: "confirmed",
        containment: "not_required",
        api_client_id: result.api_client_id,
        api_token_id: result.api_token_id,
        api_token_prefix: result.api_token_prefix,
        recovery: result.recovery?,
        output_path: output_path,
        warnings: warnings,
        next_steps: [
          "Provision named admin API Clients for regular operators.",
          "Revoke this bootstrap credential after named admin access is verified."
        ]
      },
      pretty: true
    )
  end

  defp render_init_success(result, output_path, warnings, false) do
    lines =
      [
        "Cluster admin credential minted.",
        "Credential authority: committed_active",
        "Publication: confirmed",
        "Containment: not_required",
        "One-time Secret Output: #{output_path}",
        "API Client ID: #{result.api_client_id}",
        "API Token ID: #{result.api_token_id}",
        "API Token prefix: #{result.api_token_prefix}",
        "Recovery credential: #{if(result.recovery?, do: "yes", else: "no")}",
        "Next: provision named admin API Clients for regular operators, verify access, then revoke this bootstrap credential."
      ] ++ Enum.map(warnings, &"Warning: #{&1}")

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
