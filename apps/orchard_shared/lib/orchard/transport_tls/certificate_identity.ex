defmodule Orchard.TransportTLS.CertificateIdentity do
  @moduledoc """
  Exact identity extracted from an X.509 leaf certificate.
  """

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
    :otp_subject_public_key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :public_key_algorithm,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :certificate,
    :Certificate,
    Record.extract(:Certificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :tbs_certificate,
    :TBSCertificate,
    Record.extract(:TBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecord(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/public_key.hrl")
  )

  @subject_alt_name_oid {2, 5, 29, 17}
  @extended_key_usage_oid {2, 5, 29, 37}
  @server_auth_oid {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @client_auth_oid {1, 3, 6, 1, 5, 5, 7, 3, 2}

  @enforce_keys [:serial, :fingerprint, :uri_sans, :extended_key_usages]
  defstruct [:serial, :fingerprint, :uri_sans, :extended_key_usages]

  @type t :: %__MODULE__{
          serial: String.t(),
          fingerprint: String.t(),
          uri_sans: [String.t()],
          extended_key_usages: [atom() | tuple()]
        }

  @spec from_pem(String.t()) :: {:ok, t()} | {:error, :invalid_certificate_identity}
  def from_pem(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted}] -> from_der(der)
      _other -> {:error, :invalid_certificate_identity}
    end
  rescue
    _error -> {:error, :invalid_certificate_identity}
  catch
    _kind, _reason -> {:error, :invalid_certificate_identity}
  end

  @spec from_der(binary()) :: {:ok, t()} | {:error, :invalid_certificate_identity}
  def from_der(der) when is_binary(der) do
    certificate = :public_key.pkix_decode_cert(der, :otp)
    identity(certificate, der)
  rescue
    _error -> {:error, :invalid_certificate_identity}
  catch
    _kind, _reason -> {:error, :invalid_certificate_identity}
  end

  @spec from_otp(tuple()) :: {:ok, t()} | {:error, :invalid_certificate_identity}
  def from_otp(certificate) when is_tuple(certificate) do
    der = :public_key.pkix_encode(:OTPCertificate, certificate, :otp)
    identity(certificate, der)
  rescue
    _error -> {:error, :invalid_certificate_identity}
  catch
    _kind, _reason -> {:error, :invalid_certificate_identity}
  end

  @spec spki_fingerprint_from_pem(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_certificate_identity}
  def spki_fingerprint_from_pem(pem) when is_binary(pem) do
    der = decode_certificate!(pem)
    decoded = :public_key.der_decode(:Certificate, der)
    tbs = certificate(decoded, :tbsCertificate)
    public_key_info = tbs_certificate(tbs, :subjectPublicKeyInfo)
    {:ok, fingerprint(:public_key.der_encode(:SubjectPublicKeyInfo, public_key_info))}
  rescue
    _error -> {:error, :invalid_certificate_identity}
  catch
    _kind, _reason -> {:error, :invalid_certificate_identity}
  end

  @spec signed_by?(String.t(), String.t()) :: boolean()
  def signed_by?(leaf_pem, ca_pem) when is_binary(leaf_pem) and is_binary(ca_pem) do
    leaf_der = decode_certificate!(leaf_pem)
    ca_der = decode_certificate!(ca_pem)
    :public_key.pkix_verify(leaf_der, certificate_public_key(ca_der))
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  @spec private_key_matches_certificate?(String.t(), String.t()) :: boolean()
  def private_key_matches_certificate?(private_key_pem, certificate_pem)
      when is_binary(private_key_pem) and is_binary(certificate_pem) do
    private_key = decode_private_key!(private_key_pem)
    certificate_der = decode_certificate!(certificate_pem)
    private_key_public_point(private_key) == certificate_public_point(certificate_der)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp identity(certificate, der) do
    tbs = otp_certificate(certificate, :tbsCertificate)
    serial = otp_tbs_certificate(tbs, :serialNumber)
    extensions = otp_tbs_certificate(tbs, :extensions)

    with true <- is_integer(serial) and serial > 0,
         {:ok, uri_sans} <- uri_sans(extensions),
         {:ok, extended_key_usages} <- extended_key_usages(extensions) do
      {:ok,
       %__MODULE__{
         serial: Integer.to_string(serial),
         fingerprint: fingerprint(der),
         uri_sans: uri_sans,
         extended_key_usages: extended_key_usages
       }}
    else
      _other -> {:error, :invalid_certificate_identity}
    end
  end

  defp uri_sans(extensions) when is_list(extensions) do
    case Enum.find(extensions, &(extension(&1, :extnID) == @subject_alt_name_oid)) do
      nil ->
        {:ok, []}

      san_extension ->
        san_extension
        |> extension(:extnValue)
        |> normalize_uri_sans()
    end
  end

  defp uri_sans(_extensions), do: {:error, :invalid_certificate_identity}

  defp extended_key_usages(extensions) when is_list(extensions) do
    usages =
      case Enum.find(extensions, &(extension(&1, :extnID) == @extended_key_usage_oid)) do
        nil -> []
        usage_extension -> extension(usage_extension, :extnValue)
      end

    if is_list(usages) do
      {:ok, Enum.map(usages, &normalize_extended_key_usage/1)}
    else
      {:error, :invalid_certificate_identity}
    end
  end

  defp normalize_extended_key_usage(@server_auth_oid), do: :server_auth
  defp normalize_extended_key_usage(@client_auth_oid), do: :client_auth
  defp normalize_extended_key_usage(oid), do: oid

  defp normalize_uri_sans(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      {:uniformResourceIdentifier, uri}, {:ok, acc} when is_list(uri) ->
        {:cont, {:ok, [List.to_string(uri) | acc]}}

      {:uniformResourceIdentifier, uri}, {:ok, acc} when is_binary(uri) ->
        {:cont, {:ok, [uri | acc]}}

      {_other_name, _value}, {:ok, acc} ->
        {:cont, {:ok, acc}}

      _entry, _acc ->
        {:halt, {:error, :invalid_certificate_identity}}
    end)
    |> case do
      {:ok, uris} -> {:ok, Enum.reverse(uris)}
      error -> error
    end
  end

  defp normalize_uri_sans(_entries), do: {:error, :invalid_certificate_identity}

  defp certificate_public_key(der) do
    certificate = :public_key.pkix_decode_cert(der, :otp)
    tbs = otp_certificate(certificate, :tbsCertificate)
    public_key_info = otp_tbs_certificate(tbs, :subjectPublicKeyInfo)
    algorithm = otp_subject_public_key_info(public_key_info, :algorithm)
    parameters = public_key_algorithm(algorithm, :parameters)

    case otp_subject_public_key_info(public_key_info, :subjectPublicKey) do
      {:ECPoint, point} -> {{:ECPoint, point}, parameters}
      point when is_binary(point) -> {{:ECPoint, point}, parameters}
    end
  end

  defp certificate_public_point(der) do
    {{:ECPoint, point}, _parameters} = certificate_public_key(der)
    point
  end

  defp private_key_public_point(
         {:ECPrivateKey, _version, _private, _parameters, point, _attributes}
       ),
       do: point

  defp decode_certificate!(pem) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    der
  end

  defp decode_private_key!(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end

  defp fingerprint(bytes) do
    digest = :crypto.hash(:sha256, bytes)
    "sha256-" <> Base.url_encode64(digest, padding: false)
  end
end
