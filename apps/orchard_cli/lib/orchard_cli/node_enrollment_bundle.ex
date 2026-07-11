defmodule OrchardCLI.NodeEnrollmentBundle do
  @moduledoc false

  alias OrchardCLI.CertificatePin

  @maximum_bytes 65_536
  @maximum_lifetime_seconds 86_400
  @required_fields ~w(
    version enrollment_id node_id cluster_id issued_at expires_at controller token
  )

  @type t :: %{
          cluster_id: Ecto.UUID.t(),
          controller_id: Ecto.UUID.t(),
          controller_uri_san: String.t(),
          enrollment_id: Ecto.UUID.t(),
          expires_at: DateTime.t(),
          https_endpoint: String.t(),
          https_trust_anchor_der: binary(),
          https_trust_spki_sha256: String.t(),
          issued_at: DateTime.t(),
          node_id: Ecto.UUID.t(),
          runtime_trust_spki_sha256: String.t(),
          token: String.t()
        }

  @spec load(String.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def load(path, opts \\ []) when is_binary(path) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size <= @maximum_bytes,
         {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, bundle} <- validate(decoded, now) do
      {:ok, bundle}
    else
      {:error, :enrollment_bundle_expired} = error -> error
      _reason -> {:error, :invalid_enrollment_bundle}
    end
  rescue
    _error -> {:error, :invalid_enrollment_bundle}
  end

  defp validate(bundle, now) when is_map(bundle) do
    with :ok <- require_exact_version(bundle),
         :ok <- require_fields(bundle),
         {:ok, enrollment_id} <- uuid(bundle["enrollment_id"]),
         {:ok, node_id} <- uuid(bundle["node_id"]),
         {:ok, cluster_id} <- uuid(bundle["cluster_id"]),
         {:ok, issued_at} <- timestamp(bundle["issued_at"]),
         {:ok, expires_at} <- timestamp(bundle["expires_at"]),
         :ok <- validate_time_window(issued_at, expires_at, now),
         {:ok, controller} <- controller(bundle["controller"], cluster_id),
         :ok <- validate_token(bundle["token"]) do
      {:ok,
       %{
         enrollment_id: enrollment_id,
         node_id: node_id,
         cluster_id: cluster_id,
         issued_at: issued_at,
         expires_at: expires_at,
         https_endpoint: controller.https_endpoint,
         https_trust_anchor_der: controller.https_trust_anchor_der,
         https_trust_spki_sha256: controller.https_trust_spki_sha256,
         controller_id: controller.controller_id,
         controller_uri_san: controller.controller_uri_san,
         runtime_trust_spki_sha256: controller.runtime_trust_spki_sha256,
         token: bundle["token"]
       }}
    end
  end

  defp validate(_bundle, _now), do: {:error, :invalid_enrollment_bundle}

  defp require_exact_version(%{"version" => 1}), do: :ok
  defp require_exact_version(_bundle), do: {:error, :invalid_enrollment_bundle}

  defp require_fields(bundle) do
    if Enum.all?(@required_fields, &Map.has_key?(bundle, &1)) do
      :ok
    else
      {:error, :invalid_enrollment_bundle}
    end
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_enrollment_bundle}
    end
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _reason -> {:error, :invalid_enrollment_bundle}
    end
  end

  defp timestamp(_value), do: {:error, :invalid_enrollment_bundle}

  defp validate_time_window(issued_at, expires_at, now) do
    cond do
      DateTime.compare(expires_at, issued_at) != :gt ->
        {:error, :invalid_enrollment_bundle}

      DateTime.diff(expires_at, issued_at, :second) > @maximum_lifetime_seconds ->
        {:error, :invalid_enrollment_bundle}

      DateTime.compare(expires_at, now) != :gt ->
        {:error, :enrollment_bundle_expired}

      true ->
        :ok
    end
  end

  defp controller(controller, cluster_id) when is_map(controller) do
    with {:ok, controller_id} <- uuid(controller["id"]),
         {:ok, endpoint} <- https_endpoint(controller["https_endpoint"]),
         {:ok, trust_anchor_der} <-
           trust_anchor(
             controller["https_trust_anchor_pem"],
             controller["https_trust_spki_sha256"]
           ),
         :ok <- fingerprint(controller["runtime_trust_spki_sha256"]),
         :ok <-
           controller_uri(
             controller["uri_san"],
             cluster_id,
             controller_id
           ) do
      {:ok,
       %{
         controller_id: controller_id,
         controller_uri_san: controller["uri_san"],
         https_endpoint: endpoint,
         https_trust_anchor_der: trust_anchor_der,
         https_trust_spki_sha256: controller["https_trust_spki_sha256"],
         runtime_trust_spki_sha256: controller["runtime_trust_spki_sha256"]
       }}
    end
  end

  defp controller(_controller, _cluster_id), do: {:error, :invalid_enrollment_bundle}

  defp https_endpoint(value) when is_binary(value) do
    uri = URI.parse(value)

    valid =
      uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
        is_integer(uri.port) and is_nil(uri.userinfo) and is_nil(uri.query) and
        is_nil(uri.fragment) and uri.path in [nil, "", "/"]

    if valid,
      do: {:ok, URI.to_string(%{uri | path: nil})},
      else: {:error, :invalid_enrollment_bundle}
  end

  defp https_endpoint(_value), do: {:error, :invalid_enrollment_bundle}

  defp trust_anchor(pem, expected_pin) when is_binary(pem) do
    with :ok <- fingerprint(expected_pin),
         {:ok, der} <- CertificatePin.decode_pem(pem),
         {:ok, ^expected_pin} <- CertificatePin.from_der(der) do
      {:ok, der}
    else
      _reason -> {:error, :invalid_enrollment_bundle}
    end
  end

  defp trust_anchor(_pem, _expected_pin), do: {:error, :invalid_enrollment_bundle}

  defp fingerprint("sha256-" <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, digest} when byte_size(digest) == 32 -> :ok
      _reason -> {:error, :invalid_enrollment_bundle}
    end
  end

  defp fingerprint(_value), do: {:error, :invalid_enrollment_bundle}

  defp controller_uri(value, cluster_id, controller_id) do
    expected = "urn:orchard:cluster:#{cluster_id}:controller:#{controller_id}"
    if value == expected, do: :ok, else: {:error, :invalid_enrollment_bundle}
  end

  defp validate_token(value) when is_binary(value) do
    case String.split(value, ".", parts: 2) do
      ["orch_enr_" <> public, secret] when byte_size(public) > 0 and byte_size(secret) > 0 -> :ok
      _parts -> {:error, :invalid_enrollment_bundle}
    end
  end

  defp validate_token(_value), do: {:error, :invalid_enrollment_bundle}
end
