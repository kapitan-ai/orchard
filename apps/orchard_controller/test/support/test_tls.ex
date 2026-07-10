defmodule Orchard.TestTLS do
  @moduledoc false

  require Record

  alias Orchard.NodeTrust.PKI

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

  @curve_oid {1, 2, 840, 10_045, 3, 1, 7}
  @ec_public_key_oid {1, 2, 840, 10_045, 2, 1}
  @ecdsa_sha256_oid {1, 2, 840, 10_045, 4, 3, 2}
  @common_name_oid {2, 5, 4, 3}
  @basic_constraints_oid {2, 5, 29, 19}
  @key_usage_oid {2, 5, 29, 15}
  @extended_key_usage_oid {2, 5, 29, 37}
  @subject_alt_name_oid {2, 5, 29, 17}
  @server_auth_oid {1, 3, 6, 1, 5, 5, 7, 3, 1}

  @spec write_server_identity!(String.t()) :: map()
  def write_server_identity!(root) do
    now = DateTime.utc_now()

    {:ok, ca} =
      PKI.generate(
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        now
      )

    server_key = :public_key.generate_key({:namedCurve, @curve_oid})
    server_der = server_certificate(server_key, ca, now)

    ca_path = Path.join(root, "ca.crt")
    cert_path = Path.join(root, "https-server-chain.pem")
    key_path = Path.join(root, "https-server-key.pem")

    File.mkdir_p!(root)
    File.write!(ca_path, ca.ca_certificate_pem)
    File.write!(cert_path, certificate_pem(server_der))
    File.write!(key_path, private_key_pem(server_key))

    for path <- [ca_path, cert_path, key_path], do: File.chmod!(path, 0o600)

    %{
      ca_path: ca_path,
      cert_path: cert_path,
      key_path: key_path,
      ca_spki_fingerprint: ca.ca_spki_fingerprint
    }
  end

  defp server_certificate(server_key, ca, now) do
    ca_key = decode_private_key(ca.ca_private_key_pem)
    ca_der = decode_certificate(ca.ca_certificate_pem)
    ca_certificate = :public_key.pkix_decode_cert(ca_der, :otp)
    ca_tbs = otp_certificate(ca_certificate, :tbsCertificate)
    issuer = otp_tbs_certificate(ca_tbs, :subject)

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
        extnValue: [@server_auth_oid]
      ),
      extension(
        extnID: @subject_alt_name_oid,
        critical: false,
        extnValue: [
          dNSName: ~c"localhost",
          iPAddress: <<127, 0, 0, 1>>
        ]
      )
    ]

    otp_tbs_certificate(
      version: :v3,
      serialNumber: serial_number(),
      signature: signature_algorithm(algorithm: @ecdsa_sha256_oid, parameters: :asn1_NOVALUE),
      issuer: issuer,
      validity:
        validity(
          notBefore: general_time(DateTime.add(now, -60, :second)),
          notAfter: general_time(DateTime.add(now, 86_400, :second))
        ),
      subject: distinguished_name("Orchard Test HTTPS"),
      subjectPublicKeyInfo: public_key_info(server_key),
      extensions: extensions
    )
    |> :public_key.pkix_sign(ca_key)
  end

  defp public_key_info({:ECPrivateKey, _version, _private, parameters, point, _attributes}) do
    otp_subject_public_key_info(
      algorithm: public_key_algorithm(algorithm: @ec_public_key_oid, parameters: parameters),
      subjectPublicKey: {:ECPoint, point}
    )
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

  defp general_time(datetime) do
    {:generalTime, String.to_charlist(Calendar.strftime(datetime, "%Y%m%d%H%M%SZ"))}
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

  defp serial_number do
    <<serial::unsigned-big-integer-size(128)>> = :crypto.strong_rand_bytes(16)
    max(serial, 1)
  end
end
