defmodule Orchard.PKI.CertificateValidity do
  @moduledoc false

  require Record

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

  @spec current?(tuple(), DateTime.t()) :: boolean()
  def current?(tbs, now) do
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
end
