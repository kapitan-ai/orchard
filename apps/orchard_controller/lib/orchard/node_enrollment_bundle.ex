defmodule Orchard.NodeEnrollmentBundle do
  @moduledoc """
  Issues the canonical one-time Node Enrollment bundle content.

  The caller owns publication and must confirm successful delivery with
  `Orchard.NodeEnrollments.mark_issued/2`. Until then, the Enrollment remains
  non-redeemable in `pending_publication`.
  """

  alias Orchard.EndpointMetadata
  alias Orchard.NodeEnrollments
  alias Orchard.NodeTrust
  alias Orchard.TransportTLS.CertificateIdentity

  @default_expiry_seconds 3_600
  @maximum_expiry_seconds 86_400
  @maximum_display_name_bytes 128
  @maximum_intent_bytes 64
  @maximum_bundle_bytes 65_536
  @pool_id_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/
  @surface_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/
  @control_character_pattern ~r/[\p{Cc}\p{Cf}]/u

  @type issued_bundle :: %{
          contents: String.t(),
          enrollment: Orchard.Nodes.Enrollment.t(),
          filename: String.t()
        }

  @spec issue(map(), keyword()) :: {:ok, issued_bundle()} | {:error, term()}
  def issue(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, attrs} <- validate_attrs(attrs),
         {:ok, trust} <- NodeTrust.public_material(),
         {:ok, endpoint} <- controller_https_endpoint(),
         {:ok, _reconciliation} <-
           NodeEnrollments.reconcile_stale_pending_publications(now: now),
         {:ok, result} <-
           NodeEnrollments.create(
             enrollment_attrs(attrs, trust, now, attrs.expiry_seconds),
             now: now
           ) do
      finalize_issue(result, trust, endpoint, attrs)
    end
  end

  @spec validate_attrs(map()) :: {:ok, map()} | {:error, term()}
  def validate_attrs(attrs) when is_map(attrs) do
    normalized = %{
      creator_id: value(attrs, :creator_id),
      creator_type: value(attrs, :creator_type, "operator"),
      display_name: normalize_optional_text(value(attrs, :display_name)),
      expiry_seconds: value(attrs, :expiry_seconds, @default_expiry_seconds),
      pool_id: normalize_text(value(attrs, :pool_id, "general")),
      surface: normalize_text(value(attrs, :surface))
    }

    errors =
      [
        validate_expiry(normalized.expiry_seconds),
        validate_display_name(normalized.display_name),
        validate_intent(:pool_id, normalized.pool_id, @pool_id_pattern),
        validate_intent(:surface, normalized.surface, @surface_pattern)
      ]
      |> Enum.reject(&(&1 == :ok))
      |> Enum.map(fn {:error, error} -> error end)

    if errors == [],
      do: {:ok, normalized},
      else: {:error, {:invalid_enrollment_bundle_attrs, errors}}
  end

  @spec filename(String.t()) :: String.t()
  def filename(display_name) when is_binary(display_name) do
    stem =
      display_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> case do
        "" -> "node"
        value -> String.slice(value, 0, 48)
      end

    "orchard-#{stem}-enrollment.json"
  end

  defp enrollment_attrs(attrs, trust, now, expiry_seconds) do
    %{
      audit_metadata: %{
        "initial_pool_id" => attrs.pool_id,
        "surface" => attrs.surface
      },
      cluster_id: trust.cluster_id,
      creator_id: attrs.creator_id,
      creator_type: attrs.creator_type,
      expected_controller_id: trust.controller_id,
      expires_at: DateTime.add(now, expiry_seconds, :second),
      node: node_attrs(attrs.display_name),
      resume_verifier_metadata: %{"algorithm" => "sha256", "version" => 1},
      trust_authority_id: trust.trust_authority_id
    }
  end

  defp encode_bundle(result, trust, endpoint) do
    bundle = %{
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

    case Jason.encode(bundle, pretty: true) do
      {:ok, json} -> validate_bundle_size(json <> "\n")
      {:error, reason} -> {:error, {:bundle_encoding_failed, reason}}
    end
  end

  defp validate_bundle_size(contents) when byte_size(contents) <= @maximum_bundle_bytes,
    do: {:ok, contents}

  defp validate_bundle_size(_contents), do: {:error, {:bundle_too_large, @maximum_bundle_bytes}}

  defp finalize_issue(result, trust, endpoint, attrs) do
    case encode_bundle(result, trust, endpoint) do
      {:ok, contents} ->
        {:ok,
         %{
           contents: contents,
           enrollment: result.enrollment,
           filename: filename(result.enrollment.node.display_name)
         }}

      {:error, reason} ->
        reconcile_failed_issue(result.enrollment.id, attrs, reason)
    end
  end

  defp reconcile_failed_issue(enrollment_id, attrs, reason) do
    failure_code = publication_failure_code(reason)

    opts = [
      actor_id: attrs.creator_id || "node-enrollment-bundle",
      actor_type: attrs.creator_type,
      reason: Atom.to_string(failure_code)
    ]

    case NodeEnrollments.mark_output_failed(enrollment_id, opts) do
      {:ok, _enrollment} ->
        {:error, {:bundle_publication_failed, enrollment_id, :output_failed, failure_code}}

      {:error, reconciliation_reason} ->
        {:error,
         {:bundle_publication_reconciliation_failed, enrollment_id, failure_code,
          reconciliation_reason}}
    end
  end

  defp publication_failure_code({:bundle_too_large, _maximum}), do: :bundle_too_large

  defp publication_failure_code({:bundle_encoding_failed, _reason}),
    do: :bundle_encoding_failed

  defp controller_https_endpoint do
    with {:ok, metadata} <- EndpointMetadata.read(),
         :ok <- require_https_transport(metadata),
         {:ok, host} <- required_metadata(metadata.public_host),
         {:ok, port} <- required_metadata(metadata.api_https_port),
         {:ok, ca_certfile} <- required_metadata(metadata.ca_certfile),
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
         {:ok, fingerprint} <- CertificateIdentity.spki_fingerprint_from_pem(pem) do
      {:ok, %{pem: pem, spki_sha256: fingerprint}}
    else
      _reason -> {:error, :controller_https_trust_invalid}
    end
  end

  defp require_https_transport(%{transport_mode: mode})
       when mode in ["direct_https", "reverse_proxy"],
       do: :ok

  defp require_https_transport(_metadata), do: {:error, :controller_https_not_configured}

  defp required_metadata(nil), do: {:error, :controller_https_not_configured}
  defp required_metadata(value), do: {:ok, value}

  defp endpoint_host(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  defp node_attrs(display_name) when is_binary(display_name) and display_name != "",
    do: %{display_name: display_name}

  defp node_attrs(_display_name), do: %{}

  defp validate_expiry(seconds)
       when is_integer(seconds) and seconds > 0 and seconds <= @maximum_expiry_seconds,
       do: :ok

  defp validate_expiry(_seconds), do: invalid(:expiry_seconds, :out_of_range)

  defp validate_display_name(nil), do: :ok

  defp validate_display_name(display_name) when is_binary(display_name) do
    cond do
      display_name == "" ->
        invalid(:display_name, :empty)

      byte_size(display_name) > @maximum_display_name_bytes ->
        invalid(:display_name, :too_long)

      !String.valid?(display_name) ->
        invalid(:display_name, :invalid_format)

      Regex.match?(@control_character_pattern, display_name) ->
        invalid(:display_name, :invalid_format)

      true ->
        :ok
    end
  end

  defp validate_display_name(_display_name), do: invalid(:display_name, :invalid_format)

  defp validate_intent(field, value, pattern) when is_binary(value) do
    cond do
      value == "" -> invalid(field, :empty)
      byte_size(value) > @maximum_intent_bytes -> invalid(field, :too_long)
      !Regex.match?(pattern, value) -> invalid(field, :invalid_format)
      true -> :ok
    end
  end

  defp validate_intent(field, _value, _pattern), do: invalid(field, :invalid_format)

  defp invalid(field, reason), do: {:error, {field, reason}}

  defp normalize_optional_text(nil), do: nil
  defp normalize_optional_text(value), do: normalize_text(value)

  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value), do: value

  defp value(attrs, key, default \\ nil) do
    case Map.fetch(attrs, key) do
      {:ok, found} -> found
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
  end
end
