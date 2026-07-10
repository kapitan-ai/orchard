defmodule OrchardCLI.CertificatePin do
  @moduledoc false

  require Record

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

  @spec from_pem_file(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_certificate | File.posix()}
  def from_pem_file(path) do
    with {:ok, pem} <- File.read(path),
         {:ok, der} <- decode_pem(pem) do
      from_der(der)
    end
  end

  @spec decode_pem(String.t()) :: {:ok, binary()} | {:error, :invalid_certificate}
  def decode_pem(pem) when is_binary(pem) do
    certificate_der(pem)
  end

  @spec from_der(binary() | tuple()) :: {:ok, String.t()} | {:error, :invalid_certificate}
  def from_der({:OTPCertificate, _tbs, _algorithm, _signature} = certificate) do
    :OTPCertificate
    |> :public_key.pkix_encode(certificate, :otp)
    |> from_der()
  rescue
    _error in [ArgumentError, FunctionClauseError, MatchError] ->
      {:error, :invalid_certificate}
  end

  def from_der(der) when is_binary(der) do
    with {:ok, spki_der} <- subject_public_key_info_der(der) do
      digest = :crypto.hash(:sha256, spki_der)
      {:ok, "sha256-" <> Base.url_encode64(digest, padding: false)}
    end
  end

  defp certificate_der(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted}] -> {:ok, der}
      _entries -> {:error, :invalid_certificate}
    end
  rescue
    _error in [ArgumentError, FunctionClauseError, MatchError] ->
      {:error, :invalid_certificate}
  end

  defp subject_public_key_info_der(der) do
    decoded = :public_key.der_decode(:Certificate, der)
    tbs = certificate(decoded, :tbsCertificate)
    subject_public_key_info = tbs_certificate(tbs, :subjectPublicKeyInfo)
    {:ok, :public_key.der_encode(:SubjectPublicKeyInfo, subject_public_key_info)}
  rescue
    _error in [ArgumentError, FunctionClauseError, MatchError] ->
      {:error, :invalid_certificate}
  end
end
