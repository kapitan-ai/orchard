defmodule OrchardCLI.Commands.NodeEnrollment do
  @moduledoc false

  alias Orchard.NodeEnrollments
  alias Orchard.NodeTrust
  alias OrchardCLI.CertificatePin
  alias OrchardCLI.EndpointMetadata
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
        strict: [output: :string, expires_in: :string]
      )

    with :ok <- reject_parse_errors(positional, invalid),
         {:ok, output_path} <- require_single_output(options),
         {:ok, expiry_seconds} <- parse_expiry(Keyword.get(options, :expires_in)) do
      {:ok, %{expiry_seconds: expiry_seconds, output_path: output_path}}
    end
  end

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

    with {:ok, trust} <- NodeTrust.public_material(),
         {:ok, endpoint} <- controller_https_endpoint(),
         {:ok, reservation} <- reserve_output(output, options.output_path) do
      issue_reserved(output, reservation, options, trust, endpoint)
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp issue_reserved(output, reservation, options, trust, endpoint) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, options.expiry_seconds, :second)

    attrs = %{
      audit_metadata: %{"surface" => "local_orchardctl"},
      cluster_id: trust.cluster_id,
      creator_id: "local-orchardctl",
      creator_type: "operator",
      expected_controller_id: trust.controller_id,
      expires_at: expires_at,
      resume_verifier_metadata: %{"algorithm" => "sha256", "version" => 1},
      trust_authority_id: trust.trust_authority_id
    }

    with {:ok, _reconciliation} <-
           NodeEnrollments.reconcile_stale_pending_publications(now: now),
         {:ok, result} <- NodeEnrollments.create(attrs, now: now) do
      publish_bundle(output, reservation, result, trust, endpoint)
    else
      {:error, reason} ->
        output.release(reservation)
        command_error(reason)
    end
  end

  defp publish_bundle(output, reservation, result, trust, endpoint) do
    bundle = enrollment_bundle(result, trust, endpoint)

    case Jason.encode(bundle, pretty: true) do
      {:ok, json} ->
        publish_encoded_bundle(output, reservation, result.enrollment.id, json <> "\n")

      {:error, _reason} ->
        handle_publication_failure(output, reservation, result.enrollment.id)
    end
  end

  defp publish_encoded_bundle(output, reservation, enrollment_id, contents) do
    case output.publish(reservation, contents) do
      {:ok, published} ->
        confirm_published_enrollment(output, published, enrollment_id)

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

  defp confirm_published_enrollment(output, published, enrollment_id) do
    case NodeEnrollments.mark_issued(enrollment_id,
           actor_id: "local-orchardctl",
           actor_type: "operator"
         ) do
      {:ok, _issued} ->
        publication_success(published.path, enrollment_id)

      {:error, _reason} ->
        reconcile_ambiguous_confirmation(output, published, enrollment_id)
    end
  end

  defp reconcile_ambiguous_confirmation(output, published, enrollment_id) do
    case NodeEnrollments.fetch(enrollment_id) do
      {:ok, %{state: state}} when state in [:issued, :consumed, :revoked, :expired] ->
        publication_success(published.path, enrollment_id)

      {:ok, %{state: state}} when state in [:pending_publication, :output_failed] ->
        handle_publication_failure(output, published, enrollment_id)

      {:error, _reason} ->
        {:error,
         "Error: bundle publication confirmation is unresolved. Enrollment ID: #{enrollment_id}. The protected output was retained for recovery.",
         1}
    end
  end

  defp publication_success(path, enrollment_id) do
    {:ok,
     "Node Enrollment bundle created at #{path}\n" <>
       "Enrollment ID: #{enrollment_id}"}
  end

  defp enrollment_bundle(result, trust, endpoint) do
    %{
      version: 1,
      enrollment_id: result.enrollment.id,
      node_id: result.enrollment.node_id,
      cluster_id: trust.cluster_id,
      expires_at: DateTime.to_iso8601(result.enrollment.expires_at),
      issued_at: DateTime.to_iso8601(result.enrollment.issued_at),
      controller: %{
        https_endpoint: endpoint.address,
        https_trust_anchor_pem: endpoint.trust_anchor_pem,
        https_trust_spki_sha256: endpoint.trust_spki_sha256,
        id: trust.controller_id,
        runtime_trust_spki_sha256: trust.ca_spki_fingerprint,
        uri_san: trust.controller_uri_san
      },
      token: result.bootstrap_token
    }
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

  defp controller_https_endpoint do
    with {:ok, metadata} <- EndpointMetadata.read(),
         :ok <- require_https_transport(metadata),
         {:ok, host} <- required_metadata(metadata.public_host, :public_host),
         {:ok, port} <- required_metadata(metadata.api_https_port, :api_https_port),
         {:ok, ca_certfile} <- required_metadata(metadata.ca_certfile, :ca_certfile),
         {:ok, trust} <- https_trust_material(ca_certfile) do
      {:ok,
       %{
         address: "https://#{endpoint_host(host)}:#{port}",
         trust_anchor_pem: trust.pem,
         trust_spki_sha256: trust.spki_sha256
       }}
    end
  end

  defp https_trust_material(path) do
    with {:ok, pem} <- File.read(path),
         {:ok, der} <- CertificatePin.decode_pem(pem),
         {:ok, fingerprint} <- CertificatePin.from_der(der) do
      {:ok, %{pem: pem, spki_sha256: fingerprint}}
    else
      _reason -> {:error, :controller_https_trust_invalid}
    end
  end

  defp require_https_transport(%{transport_mode: mode})
       when mode in ["direct_https", "reverse_proxy"],
       do: :ok

  defp require_https_transport(_metadata), do: {:error, :controller_https_not_configured}

  defp required_metadata(nil, _field), do: {:error, :controller_https_not_configured}
  defp required_metadata(value, _field), do: {:ok, value}

  defp endpoint_host(host) do
    if String.contains?(host, ":") do
      "[#{host}]"
    else
      host
    end
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

  defp command_error(_reason) do
    {:error, "Error: Node Enrollment issuance failed.", 1}
  end

  defp usage do
    "Usage: orchardctl nodes enrollment create --output PATH [--expires-in DURATION]"
  end
end
