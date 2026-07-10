defmodule Orchard.NodeTrust.PKI do
  @moduledoc false

  require Record

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
  @client_auth_oid {1, 3, 6, 1, 5, 5, 7, 3, 2}
  @ca_lifetime_seconds 315_360_000
  @controller_lifetime_seconds 7_776_000

  @spec generate(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t()) ::
          {:ok, map()} | {:error, :node_trust_pki_generation_failed}
  def generate(cluster_id, controller_id, authority_id, generation_id, now) do
    ca_key = generate_private_key()
    controller_key = generate_private_key()
    controller_uri = controller_uri(cluster_id, controller_id)
    ca_der = ca_certificate(ca_key, cluster_id, now)

    controller_der =
      controller_certificate(
        controller_key,
        ca_key,
        cluster_id,
        controller_id,
        controller_uri,
        now
      )

    material = %{
      generation_id: generation_id,
      cluster_id: cluster_id,
      controller_id: controller_id,
      trust_authority_id: authority_id,
      controller_uri_san: controller_uri,
      ca_private_key_pem: private_key_pem(ca_key),
      ca_certificate_pem: certificate_pem(ca_der),
      ca_certificate_fingerprint: fingerprint(ca_der),
      ca_spki_fingerprint: spki_fingerprint(ca_key),
      controller_private_key_pem: private_key_pem(controller_key),
      controller_certificate_pem: certificate_pem(controller_der),
      controller_certificate_fingerprint: fingerprint(controller_der)
    }

    if valid_material?(material) do
      {:ok, material}
    else
      {:error, :node_trust_pki_generation_failed}
    end
  rescue
    _error -> {:error, :node_trust_pki_generation_failed}
  catch
    _kind, _reason -> {:error, :node_trust_pki_generation_failed}
  end

  @spec valid_material?(map()) :: boolean()
  def valid_material?(material) do
    decoded = decode_material(material)

    [
      valid_identifiers?(material),
      valid_controller_identity?(material),
      private_keys_match_certificates?(decoded),
      certificate_signatures_valid?(decoded),
      certificate_extensions_valid?(material, decoded),
      fingerprints_valid?(material, decoded),
      decoded.controller_public_key != decoded.ca_public_key
    ]
    |> Enum.all?()
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp decode_material(material) do
    ca_key = decode_private_key(Map.fetch!(material, :ca_private_key_pem))
    controller_key = decode_private_key(Map.fetch!(material, :controller_private_key_pem))

    %{
      ca_key: ca_key,
      controller_key: controller_key,
      ca_der: decode_certificate(Map.fetch!(material, :ca_certificate_pem)),
      controller_der: decode_certificate(Map.fetch!(material, :controller_certificate_pem)),
      ca_public_key: private_public_key(ca_key),
      controller_public_key: private_public_key(controller_key)
    }
  end

  defp valid_controller_identity?(material) do
    expected =
      controller_uri(
        Map.fetch!(material, :cluster_id),
        Map.fetch!(material, :controller_id)
      )

    Map.fetch!(material, :controller_uri_san) == expected
  end

  defp private_keys_match_certificates?(decoded) do
    private_public_point(decoded.ca_key) == certificate_public_point(decoded.ca_der) and
      private_public_point(decoded.controller_key) ==
        certificate_public_point(decoded.controller_der)
  end

  defp certificate_signatures_valid?(decoded) do
    :public_key.pkix_verify(decoded.ca_der, decoded.ca_public_key) and
      :public_key.pkix_verify(decoded.controller_der, decoded.ca_public_key)
  end

  defp certificate_extensions_valid?(material, decoded) do
    valid_ca_extensions?(decoded.ca_der) and
      valid_controller_extensions?(
        decoded.controller_der,
        Map.fetch!(material, :controller_uri_san)
      )
  end

  defp fingerprints_valid?(material, decoded) do
    fingerprint(decoded.ca_der) == Map.fetch!(material, :ca_certificate_fingerprint) and
      spki_fingerprint(decoded.ca_key) == Map.fetch!(material, :ca_spki_fingerprint) and
      fingerprint(decoded.controller_der) ==
        Map.fetch!(material, :controller_certificate_fingerprint)
  end

  defp valid_identifiers?(material) do
    [:cluster_id, :controller_id, :trust_authority_id, :generation_id]
    |> Enum.map(&Map.fetch!(material, &1))
    |> Enum.all?(&match?({:ok, _uuid}, Ecto.UUID.cast(&1)))
  end

  defp generate_private_key do
    :public_key.generate_key({:namedCurve, @curve_oid})
  end

  defp ca_certificate(ca_key, cluster_id, now) do
    signature = certificate_signature_algorithm()
    public_key_info = otp_public_key_info(ca_key)
    subject = distinguished_name("Orchard Node Trust CA #{cluster_id}")
    key_identifier = subject_key_identifier(ca_key)

    extensions = [
      extension(
        extnID: @basic_constraints_oid,
        critical: true,
        extnValue: basic_constraints(cA: true)
      ),
      extension(
        extnID: @key_usage_oid,
        critical: true,
        extnValue: [:keyCertSign, :cRLSign]
      ),
      extension(
        extnID: @subject_key_identifier_oid,
        critical: false,
        extnValue: key_identifier
      ),
      extension(
        extnID: @authority_key_identifier_oid,
        critical: false,
        extnValue: authority_key_identifier(keyIdentifier: key_identifier)
      )
    ]

    otp_tbs_certificate(
      version: :v3,
      serialNumber: serial_number(),
      signature: signature,
      issuer: subject,
      validity: certificate_validity(now, @ca_lifetime_seconds),
      subject: subject,
      subjectPublicKeyInfo: public_key_info,
      extensions: extensions
    )
    |> :public_key.pkix_sign(ca_key)
  end

  defp controller_certificate(
         controller_key,
         ca_key,
         cluster_id,
         controller_id,
         controller_uri,
         now
       ) do
    extensions = [
      extension(
        extnID: @basic_constraints_oid,
        critical: true,
        extnValue: basic_constraints(cA: false)
      ),
      extension(extnID: @key_usage_oid, critical: true, extnValue: [:digitalSignature]),
      extension(
        extnID: @extended_key_usage_oid,
        critical: false,
        extnValue: [@client_auth_oid]
      ),
      extension(
        extnID: @subject_alt_name_oid,
        critical: false,
        extnValue: [uniformResourceIdentifier: String.to_charlist(controller_uri)]
      ),
      extension(
        extnID: @subject_key_identifier_oid,
        critical: false,
        extnValue: subject_key_identifier(controller_key)
      ),
      extension(
        extnID: @authority_key_identifier_oid,
        critical: false,
        extnValue: authority_key_identifier(keyIdentifier: subject_key_identifier(ca_key))
      )
    ]

    otp_tbs_certificate(
      version: :v3,
      serialNumber: serial_number(),
      signature: certificate_signature_algorithm(),
      issuer: distinguished_name("Orchard Node Trust CA #{cluster_id}"),
      validity: certificate_validity(now, @controller_lifetime_seconds),
      subject: distinguished_name("Orchard Runtime Controller #{controller_id}"),
      subjectPublicKeyInfo: otp_public_key_info(controller_key),
      extensions: extensions
    )
    |> :public_key.pkix_sign(ca_key)
  end

  defp certificate_signature_algorithm do
    signature_algorithm(algorithm: @ecdsa_sha256_oid, parameters: :asn1_NOVALUE)
  end

  defp otp_public_key_info(key) do
    {_point, parameters} = private_public_key(key)

    otp_subject_public_key_info(
      algorithm: public_key_algorithm(algorithm: @ec_public_key_oid, parameters: parameters),
      subjectPublicKey: private_public_point(key)
    )
  end

  defp private_public_key({:ECPrivateKey, _version, _private, parameters, point, _attributes}) do
    {{:ECPoint, point}, parameters}
  end

  defp private_public_point({:ECPrivateKey, _version, _private, _parameters, point, _attributes}) do
    {:ECPoint, point}
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

  defp certificate_validity(now, lifetime_seconds) do
    validity(
      notBefore: validity_time(DateTime.add(now, -60, :second)),
      notAfter: validity_time(DateTime.add(now, lifetime_seconds, :second))
    )
  end

  defp validity_time(datetime) when datetime.year < 2050 do
    {:utcTime, String.to_charlist(Calendar.strftime(datetime, "%y%m%d%H%M%SZ"))}
  end

  defp validity_time(datetime) do
    {:generalTime, String.to_charlist(Calendar.strftime(datetime, "%Y%m%d%H%M%SZ"))}
  end

  defp subject_key_identifier(key) do
    {:ECPoint, point} = private_public_point(key)
    :crypto.hash(:sha, point)
  end

  defp spki_fingerprint(key) do
    {{:ECPoint, point}, parameters} = private_public_key(key)

    der =
      subject_public_key_info(
        algorithm:
          algorithm_identifier(
            algorithm: @ec_public_key_oid,
            parameters: parameters
          ),
        subjectPublicKey: point
      )
      |> then(&:public_key.der_encode(:SubjectPublicKeyInfo, &1))

    fingerprint(der)
  end

  defp certificate_pem(der) do
    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  end

  defp private_key_pem(key) do
    entry = :public_key.pem_entry_encode(:ECPrivateKey, key)
    :public_key.pem_encode([entry])
  end

  defp decode_private_key(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end

  defp decode_certificate(pem) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    der
  end

  defp certificate_public_point(der) do
    certificate = :public_key.pkix_decode_cert(der, :otp)
    tbs = otp_certificate(certificate, :tbsCertificate)
    public_key_info = otp_tbs_certificate(tbs, :subjectPublicKeyInfo)
    otp_subject_public_key_info(public_key_info, :subjectPublicKey)
  end

  defp valid_ca_extensions?(der) do
    extensions = certificate_extensions(der)

    extension_value(extensions, @basic_constraints_oid) ==
      basic_constraints(cA: true) and
      extension_value(extensions, @key_usage_oid) == [:keyCertSign, :cRLSign]
  end

  defp valid_controller_extensions?(der, controller_uri) do
    extensions = certificate_extensions(der)

    extension_value(extensions, @basic_constraints_oid) ==
      basic_constraints(cA: false) and
      extension_value(extensions, @key_usage_oid) == [:digitalSignature] and
      extension_value(extensions, @extended_key_usage_oid) == [@client_auth_oid] and
      extension_value(extensions, @subject_alt_name_oid) ==
        [uniformResourceIdentifier: String.to_charlist(controller_uri)]
  end

  defp certificate_extensions(der) do
    certificate = :public_key.pkix_decode_cert(der, :otp)
    tbs = otp_certificate(certificate, :tbsCertificate)
    otp_tbs_certificate(tbs, :extensions)
  end

  defp extension_value(extensions, oid) do
    Enum.find_value(extensions, fn entry ->
      if extension(entry, :extnID) == oid, do: extension(entry, :extnValue)
    end)
  end

  defp fingerprint(bytes) do
    digest = :crypto.hash(:sha256, bytes)
    "sha256-" <> Base.url_encode64(digest, padding: false)
  end

  defp serial_number do
    <<serial::unsigned-big-integer-size(128)>> = :crypto.strong_rand_bytes(16)
    max(serial, 1)
  end

  defp controller_uri(cluster_id, controller_id) do
    "urn:orchard:cluster:#{cluster_id}:controller:#{controller_id}"
  end
end
