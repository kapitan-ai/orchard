defmodule OrchardCLI.Commands.NodeEnrollment do
  @moduledoc false

  alias Orchard.NodeAdmissionPreauthorizations
  alias Orchard.NodeEnrollmentBundle
  alias Orchard.NodeEnrollments
  alias OrchardCLI.ExclusiveOutput
  alias OrchardCLI.RepoRuntime

  @default_expiry_seconds 3_600
  @maximum_expiry_seconds 86_400
  @duration_pattern ~r/\A([1-9][0-9]*)(s|m|h)?\z/

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(["create", "--help"]), do: {:ok, usage()}
  def run(["create", "help"]), do: {:ok, usage()}

  def run(["create" | args]) do
    with {:ok, options} <- parse_create_args(args) do
      RepoRuntime.run(fn -> issue(options) end)
    end
  end

  def run(_args), do: {:error, usage(), 1}

  defp parse_create_args(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          expires_in: :string,
          admit_on_join: :boolean,
          pool_id: :string,
          pool_revision: :string,
          routing_policy_id: :string,
          routing_policy_revision: :string,
          controller_dispatch_ceiling: :integer,
          capacity_policy_reason: :string,
          preview_output: :string,
          preview_file: :string,
          confirm_digest: :string,
          json: :boolean
        ]
      )

    with :ok <- reject_parse_errors(positional, invalid),
         {:ok, output_path} <- require_single_output(options),
         {:ok, expiry_seconds} <- parse_expiry(Keyword.get(options, :expires_in)),
         {:ok, admission} <- parse_admission_options(options) do
      {:ok,
       Map.merge(admission, %{
         expiry_seconds: expiry_seconds,
         output_path: output_path,
         preview_output: Keyword.get(options, :preview_output),
         preview_file: Keyword.get(options, :preview_file),
         confirm_digest: Keyword.get(options, :confirm_digest),
         json?: Keyword.get(options, :json, false)
       })}
    end
  end

  defp parse_admission_options(options) do
    admit? = Keyword.get(options, :admit_on_join, false)

    attrs = %{
      admit_on_join: admit?,
      pool_id: Keyword.get(options, :pool_id, "general"),
      pool_revision: Keyword.get(options, :pool_revision, "1"),
      routing_policy_id: Keyword.get(options, :routing_policy_id),
      routing_policy_revision: Keyword.get(options, :routing_policy_revision, "1"),
      controller_dispatch_ceiling: Keyword.get(options, :controller_dispatch_ceiling, 1),
      capacity_policy_reason: Keyword.get(options, :capacity_policy_reason)
    }

    valid? =
      not admit? or
        (present?(attrs.routing_policy_id) and present?(attrs.capacity_policy_reason) and
           attrs.controller_dispatch_ceiling >= 0)

    if valid? do
      {:ok, attrs}
    else
      {:error,
       "Error: --admit-on-join requires --routing-policy-id and --capacity-policy-reason; --controller-dispatch-ceiling must be non-negative.\n\n#{usage()}",
       1}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp reject_parse_errors([], []), do: :ok

  defp reject_parse_errors(_positional, _invalid) do
    {:error, "Error: invalid arguments.\n\n#{usage()}", 1}
  end

  defp require_single_output(options) do
    case Keyword.get_values(options, :output) do
      [path] when is_binary(path) and path != "" -> {:ok, path}
      [] -> {:error, "Error: --output PATH is required.\n\n#{usage()}", 1}
      _paths -> {:error, "Error: --output may be specified only once.\n\n#{usage()}", 1}
    end
  end

  defp parse_expiry(nil), do: {:ok, @default_expiry_seconds}

  defp parse_expiry(value) do
    with [_, amount, unit] <- Regex.run(@duration_pattern, value),
         {amount, ""} <- Integer.parse(amount),
         seconds <- duration_seconds(amount, unit),
         :ok <- validate_expiry(seconds) do
      {:ok, seconds}
    else
      _reason ->
        {:error,
         "Error: --expires-in must be a positive duration in seconds or use s, m, or h, up to 24h.",
         1}
    end
  end

  defp duration_seconds(amount, ""), do: amount
  defp duration_seconds(amount, "s"), do: amount
  defp duration_seconds(amount, "m"), do: amount * 60
  defp duration_seconds(amount, "h"), do: amount * 3_600

  defp validate_expiry(seconds) when seconds <= @maximum_expiry_seconds, do: :ok
  defp validate_expiry(_seconds), do: {:error, :expiry_exceeds_maximum}

  defp issue(options) do
    output = output_impl()

    case reserve_output(output, options.output_path) do
      {:ok, reservation} -> issue_reserved(output, reservation, options)
      {:error, reason} -> command_error(reason)
    end
  end

  defp issue_reserved(output, reservation, options) do
    attrs = %{
      creator_id: "local-orchardctl",
      creator_type: "operator",
      admit_on_join: options.admit_on_join,
      capacity_policy_reason: options.capacity_policy_reason,
      controller_dispatch_ceiling: options.controller_dispatch_ceiling,
      display_name: nil,
      expiry_seconds: options.expiry_seconds,
      pool_id: options.pool_id,
      pool_revision: options.pool_revision,
      routing_policy_id: options.routing_policy_id,
      routing_policy_revision: options.routing_policy_revision,
      surface: "local_orchardctl"
    }

    issue_with_admission_preview(output, reservation, attrs, options)
  end

  defp issue_with_admission_preview(output, reservation, %{admit_on_join: false} = attrs, options) do
    publish_issued_bundle(output, reservation, bundle_issuer_impl().issue(attrs), options)
  end

  defp issue_with_admission_preview(output, reservation, attrs, options) do
    now = DateTime.utc_now()

    case resolve_admission_preview(attrs, options, now) do
      {:ok, preview} when options.confirm_digest == preview.digest ->
        result =
          bundle_issuer_impl().issue(attrs,
            now: now,
            preauthorization_preview: preview,
            confirmation_digest: preview.digest
          )

        publish_issued_bundle(output, reservation, result, options)

      {:ok, preview} ->
        output.release(reservation)
        persist_preview_and_require_confirmation(output, preview, options)

      {:error, reason} ->
        output.release(reservation)
        command_error(reason)
    end
  end

  defp resolve_admission_preview(attrs, %{preview_file: nil}, now) do
    bundle_issuer_impl().preview_admission(attrs, now: now)
  end

  defp resolve_admission_preview(_attrs, %{preview_file: path}, _now) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      NodeAdmissionPreauthorizations.restore_preview(decoded)
    else
      _reason -> {:error, :invalid_node_admission_preauthorization_preview}
    end
  end

  defp persist_preview_and_require_confirmation(output, preview, options) do
    case maybe_publish_preview(output, preview, options.preview_output) do
      :ok -> confirmation_required(preview, options.json?)
      {:error, reason} -> command_error(reason)
    end
  end

  defp maybe_publish_preview(_output, _preview, nil), do: :ok

  defp maybe_publish_preview(output, preview, path) do
    contents =
      Jason.encode!(NodeAdmissionPreauthorizations.preview_to_map(preview), pretty: true) <> "\n"

    with {:ok, reservation} <- reserve_output(output, path),
         {:ok, _published} <- output.publish(reservation, contents) do
      :ok
    end
  end

  defp publish_issued_bundle(output, reservation, result, options) do
    case result do
      {:ok, bundle} ->
        publish_bundle(output, reservation, bundle, options)

      {:error, reason} ->
        output.release(reservation)
        command_error(reason)
    end
  end

  defp publish_bundle(output, reservation, bundle, options) do
    publish_encoded_bundle(
      output,
      reservation,
      bundle.enrollment.id,
      bundle.contents,
      Map.get(bundle, :preauthorization),
      options
    )
  end

  defp publish_encoded_bundle(
         output,
         reservation,
         enrollment_id,
         contents,
         preauthorization,
         options
       ) do
    case output.publish(reservation, contents) do
      {:ok, published} ->
        confirm_published_enrollment(
          output,
          published,
          enrollment_id,
          preauthorization,
          options
        )

      {:error, {:publication_failed, :cleanup_complete, _reason}} ->
        mark_publication_failed(enrollment_id)

      {:error, {:publication_failed, {:cleanup_unresolved, _cleanup_reason}, _reason}} ->
        {:error,
         "Error: bundle publication failed and output cleanup is unresolved. Enrollment ID: #{enrollment_id}. The Enrollment remains non-redeemable pending reconciliation.",
         1}

      {:error, _reason} ->
        handle_publication_failure(output, reservation, enrollment_id)
    end
  end

  defp confirm_published_enrollment(
         output,
         published,
         enrollment_id,
         preauthorization,
         options
       ) do
    case mark_published_issued(enrollment_id) do
      {:ok, _issued} ->
        publication_success(published.path, enrollment_id, preauthorization, options)

      {:error, _reason} ->
        reconcile_ambiguous_confirmation(
          output,
          published,
          enrollment_id,
          preauthorization,
          options
        )
    end
  end

  defp mark_published_issued(enrollment_id) do
    case publication_confirmation_checkpoint() do
      :ok ->
        NodeEnrollments.mark_issued(enrollment_id,
          actor_id: "local-orchardctl",
          actor_type: "operator"
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp publication_confirmation_checkpoint do
    case Application.get_env(:orchard_cli, :node_enrollment_publication_fault_injector) do
      injector when is_function(injector, 1) -> injector.(:before_mark_issued)
      _other -> :ok
    end
  end

  defp reconcile_ambiguous_confirmation(
         output,
         published,
         enrollment_id,
         preauthorization,
         options
       ) do
    case NodeEnrollments.fetch(enrollment_id) do
      {:ok, %{state: state}} when state in [:issued, :consumed, :revoked, :expired] ->
        publication_success(published.path, enrollment_id, preauthorization, options)

      {:ok, %{state: state}} when state in [:pending_publication, :output_failed] ->
        handle_publication_failure(output, published, enrollment_id)

      {:error, _reason} ->
        {:error,
         "Error: bundle publication confirmation is unresolved. Enrollment ID: #{enrollment_id}. The protected output was retained for recovery.",
         1}
    end
  end

  defp publication_success(path, enrollment_id, preauthorization, %{json?: true}) do
    {:ok,
     Jason.encode!(%{
       "bundle_path" => path,
       "enrollment_id" => enrollment_id,
       "preauthorization_id" => preauthorization_id(preauthorization),
       "status" => "issued"
     })}
  end

  defp publication_success(path, enrollment_id, preauthorization, _options) do
    preauthorization_line =
      case preauthorization do
        nil -> ""
        value -> "\nAdmission preauthorization ID: #{value.id}"
      end

    {:ok,
     "Node Enrollment bundle created at #{path}\n" <>
       "Enrollment ID: #{enrollment_id}" <> preauthorization_line}
  end

  defp preauthorization_id(nil), do: nil
  defp preauthorization_id(preauthorization), do: preauthorization.id

  defp confirmation_required(preview, true) do
    {:error,
     Jason.encode!(%{
       "error" => "confirmation_required",
       "preview" => NodeAdmissionPreauthorizations.preview_to_map(preview),
       "preview_digest" => preview.digest,
       "warnings" => preview.warnings
     }), 2}
  end

  defp confirmation_required(preview, false) do
    {:error,
     "Admission-on-join requires confirmation of the exact saved preview.\n" <>
       Enum.join(preview.warnings, "\n") <>
       "\nPreview digest: #{preview.digest}\n" <>
       "Repeat with --preview-file PATH --confirm-digest #{preview.digest}.", 2}
  end

  defp handle_publication_failure(output, reservation, enrollment_id) do
    case output.release(reservation) do
      :ok ->
        mark_publication_failed(enrollment_id)

      {:error, _cleanup_reason} ->
        unresolved_cleanup_error(enrollment_id)
    end
  end

  defp unresolved_cleanup_error(enrollment_id) do
    case NodeEnrollments.fetch(enrollment_id) do
      {:ok, %{state: :output_failed}} ->
        {:error,
         "Error: Enrollment #{enrollment_id} is output_failed, but output cleanup could not be confirmed.",
         1}

      _other ->
        {:error,
         "Error: bundle publication cleanup is unresolved. Enrollment ID: #{enrollment_id}. The Enrollment remains non-redeemable pending reconciliation.",
         1}
    end
  end

  defp mark_publication_failed(enrollment_id) do
    case mark_output_failed(enrollment_id) do
      {:ok, _enrollment} ->
        {:error,
         "Error: bundle publication failed. Enrollment #{enrollment_id} was marked output_failed.",
         1}

      {:error, _reason} ->
        {:error,
         "Error: bundle publication failed and its Enrollment could not be marked output_failed. Enrollment ID: #{enrollment_id}",
         1}
    end
  end

  defp mark_output_failed(enrollment_id) do
    NodeEnrollments.mark_output_failed(enrollment_id,
      actor_id: "local-orchardctl",
      actor_type: "operator"
    )
  end

  defp reserve_output(output, path) do
    case output.reserve(path) do
      {:ok, reservation} -> {:ok, reservation}
      {:error, :eexist} -> {:error, :output_exists}
      {:error, :parent_not_owner_only} -> {:error, :output_parent_not_owner_only}
      {:error, reason} -> {:error, {:output_preflight_failed, reason}}
    end
  end

  defp output_impl do
    Application.get_env(:orchard_cli, :node_enrollment_output_impl, ExclusiveOutput)
  end

  defp bundle_issuer_impl do
    Application.get_env(
      :orchard_cli,
      :node_enrollment_bundle_impl,
      NodeEnrollmentBundle
    )
  end

  defp command_error({:error, message, code}), do: {:error, message, code}

  defp command_error(:node_trust_not_initialized) do
    {:error, "Error: internal Node trust is not initialized on this Controller host.", 1}
  end

  defp command_error(:controller_https_not_configured) do
    {:error, "Error: the Controller HTTPS endpoint is not configured for enrollment.", 1}
  end

  defp command_error(:controller_https_trust_invalid) do
    {:error, "Error: the Controller HTTPS trust certificate is unavailable or invalid.", 1}
  end

  defp command_error(:not_found) do
    {:error, "Error: Controller endpoint metadata is not present on this host.", 1}
  end

  defp command_error({:malformed, _message}) do
    {:error, "Error: Controller endpoint metadata is invalid.", 1}
  end

  defp command_error(:output_exists) do
    {:error, "Error: output path already exists; refusing to overwrite it.", 1}
  end

  defp command_error(:output_parent_not_owner_only) do
    {:error,
     "Error: output directory must be owner-only; run `chmod 700` on it (or choose an owner-only directory) before retrying.",
     1}
  end

  defp command_error({:output_preflight_failed, reason}) do
    {:error, "Error: output path preflight failed: #{:file.format_error(reason)}.", 1}
  end

  defp command_error(:controller_standby) do
    {:error, "Error: Node Enrollment issuance is leader-only on this Controller.", 1}
  end

  defp command_error(:controller_leadership_unproven) do
    {:error, "Error: Controller leadership could not be proven; no Enrollment was issued.", 1}
  end

  defp command_error({:bundle_publication_failed, enrollment_id, :output_failed, failure_code}) do
    {:error,
     "Error: Enrollment #{enrollment_id} is output_failed because #{failure_label(failure_code)}. No bundle was published. Correct the Controller configuration, then create a new enrollment.",
     1}
  end

  defp command_error(
         {:bundle_publication_reconciliation_failed, enrollment_id, failure_code,
          _reconciliation_reason}
       ) do
    {:error,
     "Error: no bundle was published. Enrollment #{enrollment_id} remains non-redeemable pending reconciliation after #{failure_label(failure_code)}, and its provisioned Node name remains reserved. Record the Enrollment ID and retry with a distinct Node name after Controller recovery.",
     1}
  end

  defp command_error(_reason) do
    {:error, "Error: Node Enrollment issuance failed.", 1}
  end

  defp failure_label(:bundle_too_large), do: "the enrollment bundle exceeded 65536 bytes"
  defp failure_label(:bundle_encoding_failed), do: "the enrollment bundle could not be encoded"

  defp usage do
    "Usage: orchardctl nodes enrollment create --output PATH [--expires-in DURATION] " <>
      "[--admit-on-join --pool-id ID --routing-policy-id ID " <>
      "--capacity-policy-reason REASON [--controller-dispatch-ceiling N] " <>
      "(--preview-output PATH | --preview-file PATH --confirm-digest DIGEST)] [--json]"
  end
end
