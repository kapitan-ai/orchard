defmodule Orchard.NodeEnrollment.PKI do
  @moduledoc false

  require Record

  Record.defrecord(
    :certification_request,
    :CertificationRequest,
    Record.extract(:CertificationRequest, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :certification_request_info,
    :CertificationRequestInfo,
    Record.extract(:CertificationRequestInfo, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :request_public_key_info,
    :CertificationRequestInfo_subjectPKInfo,
    Record.extract(:CertificationRequestInfo_subjectPKInfo,
      from_lib: "public_key/include/public_key.hrl"
    )
  )

  Record.defrecord(
    :request_public_key_algorithm,
    :CertificationRequestInfo_subjectPKInfo_algorithm,
    Record.extract(:CertificationRequestInfo_subjectPKInfo_algorithm,
      from_lib: "public_key/include/public_key.hrl"
    )
  )

  Record.defrecord(
    :request_signature_algorithm,
    :CertificationRequest_signatureAlgorithm,
    Record.extract(:CertificationRequest_signatureAlgorithm,
      from_lib: "public_key/include/public_key.hrl"
    )
  )

  Record.defrecord(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :validity,
    :Validity,
    Record.extract(:Validity, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :signature_algorithm,
    :SignatureAlgorithm,
    Record.extract(:SignatureAlgorithm, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :public_key_algorithm,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :otp_subject_public_key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :subject_public_key_info,
    :SubjectPublicKeyInfo,
    Record.extract(:SubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :algorithm_identifier,
    :AlgorithmIdentifier,
    Record.extract(:AlgorithmIdentifier, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :attribute_type_and_value,
    :AttributeTypeAndValue,
    Record.extract(:AttributeTypeAndValue, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :basic_constraints,
    :BasicConstraints,
    Record.extract(:BasicConstraints, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :authority_key_identifier,
    :AuthorityKeyIdentifier,
    Record.extract(:AuthorityKeyIdentifier, from_lib: "public_key/include/public_key.hrl")
  )

  @curve_oid {1, 2, 840, 10_045, 3, 1, 7}
  @ec_public_key_oid {1, 2, 840, 10_045, 2, 1}
  @ecdsa_sha256_oid {1, 2, 840, 10_045, 4, 3, 2}
  @common_name_oid {2, 5, 4, 3}
  @basic_constraints_oid {2, 5, 29, 19}
  @key_usage_oid {2, 5, 29, 15}
  @extended_key_usage_oid {2, 5, 29, 37}
  @subject_alt_name_oid {2, 5, 29, 17}
  @subject_key_identifier_oid {2, 5, 29, 14}
  @authority_key_identifier_oid {2, 5, 29, 35}
  @server_auth_oid {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @client_auth_oid {1, 3, 6, 1, 5, 5, 7, 3, 2}
  @node_certificate_lifetime_seconds 7_776_000

  @type csr_material :: %{
          csr_fingerprint: String.t(),
          csr_pem: String.t(),
          node_uri_san: String.t(),
          private_key_pem: String.t(),
          public_key_fingerprint: String.t()
        }

  @spec generate_csr(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, csr_material()} | {:error, :node_identity_generation_failed}
  def generate_csr(cluster_id, node_id) do
    node_uri = node_uri(cluster_id, node_id)
    key = :public_key.generate_key({:namedCurve, @curve_oid})
    {_private, parameters, point} = private_key_parts(key)

    info =
      certification_request_info(
        version: 0,
        subject: distinguished_name(node_uri),
        subjectPKInfo:
          request_public_key_info(
            algorithm:
              request_public_key_algorithm(
                algorithm: @ec_public_key_oid,
                parameters: encode_request_parameters(parameters)
              ),
            subjectPublicKey: point
          ),
        attributes: []
      )

    info_der = :public_key.der_encode(:CertificationRequestInfo, info)
    signature = :public_key.sign(info_der, :sha256, key)

    request =
      certification_request(
        certificationRequestInfo: info,
        signatureAlgorithm:
          request_signature_algorithm(
            algorithm: @ecdsa_sha256_oid,
            parameters: :asn1_NOVALUE
          ),
        signature: signature
      )

    csr_der = :public_key.der_encode(:CertificationRequest, request)

    {:ok,
     %{
       csr_fingerprint: fingerprint(csr_der),
       csr_pem: pem(:CertificationRequest, csr_der),
       node_uri_san: node_uri,
       private_key_pem: private_key_pem(key),
       public_key_fingerprint: public_key_fingerprint(point, parameters)
     }}
  rescue
    _error -> {:error, :node_identity_generation_failed}
  catch
    _kind, _reason -> {:error, :node_identity_generation_failed}
  end

  @spec verify_csr(String.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :invalid_node_csr}
  def verify_csr(csr_pem, cluster_id, node_id) do
    expected_uri = node_uri(cluster_id, node_id)

    with {:ok, csr_der} <- decode_pem(csr_pem, :CertificationRequest),
         {:ok, verified} <- verify_request(csr_der, expected_uri) do
      {:ok, verified}
    else
      _reason -> {:error, :invalid_node_csr}
    end
  rescue
    _error -> {:error, :invalid_node_csr}
  catch
    _kind, _reason -> {:error, :invalid_node_csr}
  end

  @spec verify_local_identity(String.t(), String.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :invalid_node_identity}
  def verify_local_identity(private_key_pem, csr_pem, cluster_id, node_id) do
    with {:ok, private_identity} <- private_key_identity(private_key_pem),
         {:ok, csr_identity} <- verify_csr(csr_pem, cluster_id, node_id),
         true <-
           private_identity.public_key_fingerprint == csr_identity.public_key_fingerprint do
      {:ok,
       Map.merge(csr_identity, %{
         private_key_public_key_fingerprint: private_identity.public_key_fingerprint
       })}
    else
      _reason -> {:error, :invalid_node_identity}
    end
  rescue
    _error -> {:error, :invalid_node_identity}
  catch
    _kind, _reason -> {:error, :invalid_node_identity}
  end

  @spec certificate_identity(Ecto.UUID.t(), String.t()) :: %{
          identifier: String.t(),
          serial: pos_integer()
        }
  def certificate_identity(enrollment_id, csr_fingerprint) do
    digest = :crypto.hash(:sha256, enrollment_id <> ":" <> csr_fingerprint)
    <<serial::unsigned-big-integer-size(128), _rest::binary>> = digest

    %{
      identifier: "nodecert_" <> Base.url_encode64(digest, padding: false),
      serial: max(serial, 1)
    }
  end

  @spec issue_node_certificate(map()) ::
          {:ok, map()} | {:error, :node_certificate_issuance_failed}
  def issue_node_certificate(attrs) when is_map(attrs) do
    case verify_csr(
           Map.fetch!(attrs, :csr_pem),
           Map.fetch!(attrs, :cluster_id),
           Map.fetch!(attrs, :node_id)
         ) do
      {:ok, csr} -> issue_verified_certificate(attrs, csr)
      {:error, _reason} -> {:error, :node_certificate_issuance_failed}
    end
  rescue
    _error -> {:error, :node_certificate_issuance_failed}
  catch
    _kind, _reason -> {:error, :node_certificate_issuance_failed}
  end

  @spec validate_issued_identity(map()) :: :ok | {:error, :invalid_node_certificate}
  def validate_issued_identity(attrs) when is_map(attrs) do
    node_der = decode_certificate(Map.fetch!(attrs, :node_certificate_pem))
    ca_der = decode_certificate(Map.fetch!(attrs, :runtime_ca_certificate_pem))
    node_material = certificate_public_material(node_der)
    ca_material = certificate_public_material(ca_der)
    node_tbs = certificate_tbs(node_der)
    ca_tbs = certificate_tbs(ca_der)
    now = Map.get(attrs, :now, DateTime.utc_now())
    expected_uri = node_uri(Map.fetch!(attrs, :cluster_id), Map.fetch!(attrs, :node_id))

    expected_identity =
      certificate_identity(
        Map.fetch!(attrs, :enrollment_id),
        Map.fetch!(attrs, :csr_fingerprint)
      )

    valid =
      valid_certificate_authority?(
        node_der,
        node_tbs,
        ca_der,
        ca_tbs,
        ca_material,
        attrs,
        now
      ) and
        valid_node_certificate?(
          node_material,
          node_tbs,
          expected_uri,
          expected_identity,
          attrs,
          now
        )

    if valid, do: :ok, else: {:error, :invalid_node_certificate}
  rescue
    _error -> {:error, :invalid_node_certificate}
  catch
    _kind, _reason -> {:error, :invalid_node_certificate}
  end

  @spec node_uri(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def node_uri(cluster_id, node_id) do
    "urn:orchard:cluster:#{cluster_id}:node:#{node_id}"
  end

  defp verify_request(csr_der, expected_uri) do
    request = :public_key.der_decode(:CertificationRequest, csr_der)
    info = certification_request(request, :certificationRequestInfo)
    signature_algorithm = certification_request(request, :signatureAlgorithm)
    signature = certification_request(request, :signature)
    subject = certification_request_info(info, :subject)
    public_key_info = certification_request_info(info, :subjectPKInfo)
    algorithm = request_public_key_info(public_key_info, :algorithm)
    point = request_public_key_info(public_key_info, :subjectPublicKey)
    encoded_parameters = request_public_key_algorithm(algorithm, :parameters)
    parameters = decode_request_parameters(encoded_parameters)

    valid =
      request_signature_algorithm(signature_algorithm, :algorithm) == @ecdsa_sha256_oid and
        request_public_key_algorithm(algorithm, :algorithm) == @ec_public_key_oid and
        parameters == {:namedCurve, @curve_oid} and
        subject == distinguished_name(expected_uri) and
        :public_key.verify(
          :public_key.der_encode(:CertificationRequestInfo, info),
          :sha256,
          signature,
          {{:ECPoint, point}, parameters}
        )

    if valid do
      {:ok,
       %{
         csr_der: csr_der,
         csr_fingerprint: fingerprint(csr_der),
         node_uri_san: expected_uri,
         parameters: parameters,
         point: point,
         public_key_fingerprint: public_key_fingerprint(point, parameters)
       }}
    else
      {:error, :invalid_node_csr}
    end
  end

  defp issue_verified_certificate(attrs, csr) do
    ca_key = decode_private_key(Map.fetch!(attrs, :ca_private_key_pem))
    ca_der = decode_certificate(Map.fetch!(attrs, :ca_certificate_pem))
    ca_certificate = :public_key.pkix_decode_cert(ca_der, :otp)
    ca_tbs = otp_certificate(ca_certificate, :tbsCertificate)
    now = Map.fetch!(attrs, :now)
    not_after = DateTime.add(now, @node_certificate_lifetime_seconds, :second)

    certificate_der =
      otp_tbs_certificate(
        version: :v3,
        serialNumber: Map.fetch!(attrs, :serial),
        signature: certificate_signature_algorithm(),
        issuer: otp_tbs_certificate(ca_tbs, :subject),
        validity:
          validity(
            notBefore: validity_time(DateTime.add(now, -60, :second)),
            notAfter: validity_time(not_after)
          ),
        subject: distinguished_name(csr.node_uri_san),
        subjectPublicKeyInfo:
          otp_subject_public_key_info(
            algorithm:
              public_key_algorithm(
                algorithm: @ec_public_key_oid,
                parameters: csr.parameters
              ),
            subjectPublicKey: {:ECPoint, csr.point}
          ),
        extensions: node_extensions(csr, ca_key)
      )
      |> :public_key.pkix_sign(ca_key)

    if :public_key.pkix_verify(certificate_der, private_public_key(ca_key)) do
      {:ok,
       %{
         certificate_identifier: Map.fetch!(attrs, :certificate_identifier),
         certificate_pem: pem(:Certificate, certificate_der),
         certificate_serial: Integer.to_string(Map.fetch!(attrs, :serial)),
         csr_fingerprint: csr.csr_fingerprint,
         node_uri_san: csr.node_uri_san,
         not_after: DateTime.to_iso8601(not_after),
         public_key_fingerprint: csr.public_key_fingerprint
       }}
    else
      {:error, :node_certificate_issuance_failed}
    end
  end

  defp node_extensions(csr, ca_key) do
    [
      extension(
        extnID: @basic_constraints_oid,
        critical: true,
        extnValue: basic_constraints(cA: false)
      ),
      extension(extnID: @key_usage_oid, critical: true, extnValue: [:digitalSignature]),
      extension(
        extnID: @extended_key_usage_oid,
        critical: false,
        extnValue: [@server_auth_oid, @client_auth_oid]
      ),
      extension(
        extnID: @subject_alt_name_oid,
        critical: false,
        extnValue: [uniformResourceIdentifier: String.to_charlist(csr.node_uri_san)]
      ),
      extension(
        extnID: @subject_key_identifier_oid,
        critical: false,
        extnValue: :crypto.hash(:sha, csr.point)
      ),
      extension(
        extnID: @authority_key_identifier_oid,
        critical: false,
        extnValue: authority_key_identifier(keyIdentifier: subject_key_identifier(ca_key))
      )
    ]
  end

  defp encode_request_parameters(parameters) do
    {:asn1_OPENTYPE, :public_key.der_encode(:EcpkParameters, parameters)}
  end

  defp decode_request_parameters({:asn1_OPENTYPE, der}) do
    :public_key.der_decode(:EcpkParameters, der)
  end

  defp decode_request_parameters(_parameters), do: :invalid

  defp certificate_public_material(der) do
    certificate = :public_key.pkix_decode_cert(der, :otp)
    tbs = otp_certificate(certificate, :tbsCertificate)
    info = otp_tbs_certificate(tbs, :subjectPublicKeyInfo)
    algorithm = otp_subject_public_key_info(info, :algorithm)
    parameters = public_key_algorithm(algorithm, :parameters)
    {:ECPoint, point} = otp_subject_public_key_info(info, :subjectPublicKey)

    %{
      public_key: {{:ECPoint, point}, parameters},
      public_key_fingerprint: public_key_fingerprint(point, parameters)
    }
  end

  defp valid_certificate_authority?(
         node_der,
         node_tbs,
         ca_der,
         ca_tbs,
         ca_material,
         attrs,
         now
       ) do
    certificate_path_valid?(node_der, node_tbs, ca_der, ca_tbs, ca_material) and
      certificate_valid_now?(ca_tbs, now) and
      ca_material.public_key_fingerprint == Map.fetch!(attrs, :runtime_trust_spki_sha256) and
      valid_ca_extensions?(ca_tbs)
  end

  defp valid_node_certificate?(node_material, node_tbs, expected_uri, identity, attrs, now) do
    certificate_valid_now?(node_tbs, now) and
      node_material.public_key_fingerprint == Map.fetch!(attrs, :public_key_fingerprint) and
      valid_node_extensions?(node_tbs, expected_uri) and
      otp_tbs_certificate(node_tbs, :serialNumber) == identity.serial and
      Map.fetch!(attrs, :certificate_serial) == Integer.to_string(identity.serial) and
      Map.fetch!(attrs, :certificate_identifier) == identity.identifier
  end

  defp certificate_path_valid?(node_der, node_tbs, ca_der, ca_tbs, ca_material) do
    :public_key.pkix_verify(ca_der, ca_material.public_key) and
      :public_key.pkix_verify(node_der, ca_material.public_key) and
      otp_tbs_certificate(node_tbs, :issuer) == otp_tbs_certificate(ca_tbs, :subject) and
      otp_tbs_certificate(ca_tbs, :issuer) == otp_tbs_certificate(ca_tbs, :subject)
  end

  defp certificate_valid_now?(tbs, now) do
    certificate_validity = otp_tbs_certificate(tbs, :validity)
    not_before = certificate_time(validity(certificate_validity, :notBefore))
    not_after = certificate_time(validity(certificate_validity, :notAfter))
    current = Calendar.strftime(now, "%Y%m%d%H%M%SZ")

    is_binary(not_before) and is_binary(not_after) and
      not_before <= current and current < not_after
  end

  defp certificate_time({:generalTime, value}), do: List.to_string(value)

  defp certificate_time({:utcTime, value}) do
    case List.to_string(value) do
      <<year::binary-size(2), rest::binary>> = utc when byte_size(utc) == 13 ->
        century = if String.to_integer(year) < 50, do: "20", else: "19"
        century <> year <> rest

      _other ->
        nil
    end
  end

  defp certificate_time(_value), do: nil

  defp valid_node_extensions?(tbs, expected_uri) do
    extensions = otp_tbs_certificate(tbs, :extensions)

    extension_value(extensions, @basic_constraints_oid) == basic_constraints(cA: false) and
      extension_value(extensions, @key_usage_oid) == [:digitalSignature] and
      extension_value(extensions, @extended_key_usage_oid) ==
        [@server_auth_oid, @client_auth_oid] and
      extension_value(extensions, @subject_alt_name_oid) ==
        [uniformResourceIdentifier: String.to_charlist(expected_uri)]
  end

  defp valid_ca_extensions?(tbs) do
    extensions = otp_tbs_certificate(tbs, :extensions)

    extension_value(extensions, @basic_constraints_oid) == basic_constraints(cA: true) and
      extension_value(extensions, @key_usage_oid) == [:keyCertSign, :cRLSign]
  end

  defp extension_value(extensions, oid) do
    Enum.find_value(extensions, fn entry ->
      if extension(entry, :extnID) == oid, do: extension(entry, :extnValue)
    end)
  end

  defp certificate_tbs(der) do
    der
    |> :public_key.pkix_decode_cert(:otp)
    |> otp_certificate(:tbsCertificate)
  end

  defp certificate_signature_algorithm do
    signature_algorithm(algorithm: @ecdsa_sha256_oid, parameters: :asn1_NOVALUE)
  end

  defp distinguished_name(common_name) do
    {:rdnSequence,
     [
       [
         attribute_type_and_value(
           type: @common_name_oid,
           value: {:utf8String, common_name}
         )
       ]
     ]}
  end

  defp private_key_parts({:ECPrivateKey, _version, private, parameters, point, _attributes}) do
    {private, parameters, point}
  end

  defp private_key_identity(pem) do
    key = decode_private_key(pem)
    {private, {:namedCurve, @curve_oid} = parameters, _encoded_point} = private_key_parts(key)
    {derived_point, ^private} = :crypto.generate_key(:ecdh, :secp256r1, private)

    {:ok,
     %{
       public_key_fingerprint: public_key_fingerprint(derived_point, parameters)
     }}
  rescue
    _error -> {:error, :invalid_node_identity}
  catch
    _kind, _reason -> {:error, :invalid_node_identity}
  end

  defp private_public_key(key) do
    {_private, parameters, point} = private_key_parts(key)
    {{:ECPoint, point}, parameters}
  end

  defp subject_key_identifier(key) do
    {_private, _parameters, point} = private_key_parts(key)
    :crypto.hash(:sha, point)
  end

  defp public_key_fingerprint(point, parameters) do
    subject_public_key_info(
      algorithm:
        algorithm_identifier(
          algorithm: @ec_public_key_oid,
          parameters: parameters
        ),
      subjectPublicKey: point
    )
    |> then(&:public_key.der_encode(:SubjectPublicKeyInfo, &1))
    |> fingerprint()
  end

  defp fingerprint(bytes) do
    "sha256-" <> Base.url_encode64(:crypto.hash(:sha256, bytes), padding: false)
  end

  defp private_key_pem(key) do
    entry = :public_key.pem_entry_encode(:ECPrivateKey, key)
    :public_key.pem_encode([entry])
  end

  defp pem(type, der), do: :public_key.pem_encode([{type, der, :not_encrypted}])

  defp decode_pem(pem, type) do
    case :public_key.pem_decode(pem) do
      [{^type, der, :not_encrypted}] -> {:ok, der}
      _entries -> {:error, :invalid_pem}
    end
  end

  defp decode_private_key(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end

  defp decode_certificate(pem) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    der
  end

  defp validity_time(datetime) when datetime.year < 2050 do
    {:utcTime, String.to_charlist(Calendar.strftime(datetime, "%y%m%d%H%M%SZ"))}
  end

  defp validity_time(datetime) do
    {:generalTime, String.to_charlist(Calendar.strftime(datetime, "%Y%m%d%H%M%SZ"))}
  end
end
