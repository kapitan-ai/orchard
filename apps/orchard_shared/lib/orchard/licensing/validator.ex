defmodule Orchard.Licensing.Validator do
  @moduledoc false

  @type bundle_pair :: %{
          license_certificate: String.t(),
          machine_certificate: String.t()
        }

  @type normalized_claims :: %{
          license_id: String.t(),
          machine_id: String.t(),
          fingerprint: String.t(),
          licensee: String.t() | nil,
          max_machines: pos_integer() | nil,
          not_before: DateTime.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @type validation_state ::
          :config_error
          | :invalid_license_signature
          | :invalid_machine_signature
          | :malformed_bundle
          | :malformed_license_certificate
          | :malformed_machine_certificate

  @doc false
  @spec validate_pair(bundle_pair(), String.t()) ::
          {:ok, normalized_claims()} | {:error, {validation_state(), String.t()}}
  def validate_pair(%{license_certificate: license, machine_certificate: machine}, public_key_hex)
      when is_binary(license) and is_binary(machine) do
    with {:ok, public_key} <- decode_public_key(public_key_hex),
         {:ok, license_claims} <- decode_certificate(license, :license, public_key),
         {:ok, machine_claims} <- decode_certificate(machine, :machine, public_key) do
      normalize_pair(license_claims, machine_claims)
    end
  end

  def validate_pair(_pair, _public_key_hex) do
    {:error,
     {:malformed_bundle,
      "licensing bundle must include string license_certificate and machine_certificate fields"}}
  end

  defp decode_public_key(public_key_hex)
       when is_binary(public_key_hex) and public_key_hex != "" do
    case Base.decode16(public_key_hex, case: :mixed) do
      {:ok, <<_::binary-32>> = key} ->
        {:ok, key}

      {:ok, _other} ->
        {:error, {:config_error, "configured Keygen public key must decode to 32 bytes"}}

      :error ->
        {:error, {:config_error, "configured Keygen public key must be hexadecimal"}}
    end
  end

  defp decode_public_key(_other) do
    {:error, {:config_error, "configured Keygen public key is missing"}}
  end

  defp decode_certificate(certificate, kind, public_key) do
    malformed_state = malformed_state(kind)
    invalid_signature_state = invalid_signature_state(kind)

    with {:ok, payload_json, signing_input, signature} <- extract_signed_payload(certificate, kind),
         true <-
           verify_signature(signing_input, signature, public_key) ||
             {:error, invalid_signature_state},
         {:ok, payload} <- decode_payload_json(payload_json, malformed_state),
         {:ok, claims} <- normalize_certificate_payload(payload, kind) do
      {:ok, claims}
    else
      {:error, ^invalid_signature_state} ->
        {:error, {invalid_signature_state, invalid_signature_message(kind)}}

      {:error, {^malformed_state, _message} = error} ->
        {:error, error}
    end
  end

  defp extract_signed_payload(certificate, kind) do
    malformed_state = malformed_state(kind)
    {begin_line, end_line} = certificate_delimiters(kind)

    normalized =
      certificate
      |> String.replace("\r\n", "\n")
      |> String.trim()

    pattern =
      ~r/\A#{Regex.escape(begin_line)}\n(?<body>[A-Za-z0-9+\/=\n]+)\n#{Regex.escape(end_line)}\z/

    case Regex.named_captures(pattern, normalized) do
      %{"body" => body} ->
        decode_signed_envelope(String.replace(body, "\n", ""), kind, malformed_state)

      nil ->
        {:error, {malformed_state, "certificate delimiters are invalid"}}
    end
  end

  defp decode_signed_envelope(encoded_body, kind, malformed_state) do
    with {:ok, body} <- decode_base64_field(encoded_body, malformed_state, "certificate body"),
         {:ok, envelope} <- decode_json_object(body, malformed_state, "certificate envelope"),
         {:ok, payload_json, signing_input} <- extract_payload_and_signing_input(envelope, kind, malformed_state),
         {:ok, signature} <- decode_signature_field(envelope, malformed_state) do
      {:ok, payload_json, signing_input, signature}
    end
  end

  # Extract payload and determine signing input bytes based on envelope format
  defp extract_payload_and_signing_input(envelope, kind, malformed_state) do
    cond do
      # Orchard canonical format: payload field, sign over decoded bytes
      Map.has_key?(envelope, "payload") and envelope["alg"] == "ed25519" and
          envelope["enc"] == "base64" ->
        with {:ok, payload_json} <- decode_base64_field(envelope["payload"], malformed_state, "payload") do
          # Sign over decoded payload JSON bytes
          {:ok, payload_json, payload_json}
        end

      # Keygen checkout format: enc field, sign over "<kind>/<enc>" bytes
      envelope["alg"] == "base64+ed25519" and Map.has_key?(envelope, "enc") ->
        with {:ok, payload_json} <- decode_base64_field(envelope["enc"], malformed_state, "payload") do
          # Sign over "<kind>/<base64_payload>" (e.g., "license/eyJ...")
          signing_input = "#{kind}/#{envelope["enc"]}"
          {:ok, payload_json, signing_input}
        end

      # Unknown format
      true ->
        {:error, {malformed_state, "certificate envelope format is invalid"}}
    end
  end

  defp decode_signature_field(%{"sig" => signature}, malformed_state) when is_binary(signature) do
    decode_base64_field(signature, malformed_state, "signature")
  end

  defp decode_signature_field(_envelope, malformed_state) do
    {:error, {malformed_state, "certificate signature is missing"}}
  end



  defp verify_signature(payload_json, signature, public_key) do
    :crypto.verify(:eddsa, :none, payload_json, signature, [public_key, :ed25519])
  end

  defp decode_payload_json(payload_json, malformed_state) do
    decode_json(payload_json, malformed_state)
  end

  defp decode_json_object(payload_json, malformed_state, field_name) do
    case decode_json(payload_json, malformed_state) do
      {:ok, %{} = decoded} ->
        {:ok, decoded}

      {:ok, _other} ->
        {:error, {malformed_state, "#{field_name} must be a JSON object"}}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_json(payload_json, malformed_state) do
    case Jason.decode(payload_json) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {malformed_state, Exception.message(error)}}
    end
  end

  defp decode_base64_field(value, malformed_state, field_name) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} ->
        {:ok, decoded}

      :error ->
        {:error, {malformed_state, "#{field_name} is not valid base64"}}
    end
  end

  defp decode_base64_field(_value, malformed_state, field_name) do
    {:error, {malformed_state, "#{field_name} must be a string"}}
  end

  defp normalize_certificate_payload(%{"data" => %{} = data}, :license) do
    with :ok <- expect_type(data, "licenses", :license),
         {:ok, license_id} <- fetch_required_string(data, "id", :license),
         {:ok, attributes} <- fetch_required_map(data, "attributes", :license),
         {:ok, not_before} <-
           parse_optional_datetime(attributes["notBefore"], :license, "notBefore"),
         {:ok, expires_at} <- parse_optional_datetime(attributes["expiry"], :license, "expiry"),
         {:ok, max_machines} <-
           parse_optional_pos_integer(attributes["maxMachines"], :license, "maxMachines"),
         {:ok, licensee} <- parse_optional_string(attributes["licensee"], :license, "licensee") do
      {:ok,
       %{
         license_id: license_id,
         licensee: licensee,
         max_machines: max_machines,
         not_before: not_before,
         expires_at: expires_at
       }}
    end
  end

  defp normalize_certificate_payload(%{"data" => %{} = data}, :machine) do
    with :ok <- expect_type(data, "machines", :machine),
         {:ok, machine_id} <- fetch_required_string(data, "id", :machine),
         {:ok, attributes} <- fetch_required_map(data, "attributes", :machine),
         {:ok, fingerprint} <- fetch_required_string(attributes, "fingerprint", :machine),
         {:ok, not_before} <-
           parse_optional_datetime(attributes["notBefore"], :machine, "notBefore"),
         {:ok, expires_at} <- parse_optional_datetime(attributes["expiry"], :machine, "expiry"),
         {:ok, relationships} <- fetch_required_map(data, "relationships", :machine),
         {:ok, license_relationship} <- fetch_required_map(relationships, "license", :machine),
         {:ok, license_data} <- fetch_required_map(license_relationship, "data", :machine),
         :ok <- expect_type(license_data, "licenses", :machine),
         {:ok, license_id} <- fetch_required_string(license_data, "id", :machine) do
      {:ok,
       %{
         machine_id: machine_id,
         fingerprint: fingerprint,
         bound_license_id: license_id,
         not_before: not_before,
         expires_at: expires_at
       }}
    end
  end

  defp normalize_certificate_payload(_payload, kind) do
    {:error, {malformed_state(kind), "#{kind} certificate payload is malformed"}}
  end

  defp normalize_pair(license_claims, machine_claims) do
    if machine_claims.bound_license_id == license_claims.license_id do
      {:ok,
       %{
         license_id: license_claims.license_id,
         machine_id: machine_claims.machine_id,
         fingerprint: machine_claims.fingerprint,
         licensee: license_claims.licensee,
         max_machines: license_claims.max_machines,
         not_before: latest_datetime(license_claims.not_before, machine_claims.not_before),
         expires_at: earliest_datetime(license_claims.expires_at, machine_claims.expires_at)
       }}
    else
      {:error,
       {:malformed_bundle,
        "license and machine certificates must reference the same license identifier"}}
    end
  end

  defp fetch_required_string(map, key, kind) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        {:error, {malformed_state(kind), "#{kind} certificate #{key} is missing"}}
    end
  end

  defp fetch_required_map(map, key, kind) do
    case Map.get(map, key) do
      value when is_map(value) ->
        {:ok, value}

      _other ->
        {:error, {malformed_state(kind), "#{kind} certificate #{key} is missing"}}
    end
  end

  defp parse_optional_string(nil, _kind, _key), do: {:ok, nil}

  defp parse_optional_string(value, _kind, _key) when is_binary(value) and value != "",
    do: {:ok, value}

  defp parse_optional_string(_value, kind, key) do
    {:error, {malformed_state(kind), "#{kind} certificate #{key} must be a non-empty string"}}
  end

  defp parse_optional_pos_integer(nil, _kind, _key), do: {:ok, nil}

  defp parse_optional_pos_integer(value, _kind, _key) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp parse_optional_pos_integer(_value, kind, key) do
    {:error, {malformed_state(kind), "#{kind} certificate #{key} must be a positive integer"}}
  end

  defp parse_optional_datetime(nil, _kind, _key), do: {:ok, nil}

  defp parse_optional_datetime(value, kind, key) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        {:error, {malformed_state(kind), "#{kind} certificate #{key} must be ISO8601"}}
    end
  end

  defp parse_optional_datetime(_value, kind, key) do
    {:error, {malformed_state(kind), "#{kind} certificate #{key} must be ISO8601"}}
  end

  defp expect_type(%{"type" => expected}, expected, _kind), do: :ok

  defp expect_type(_data, expected, kind) do
    {:error, {malformed_state(kind), "#{kind} certificate type must be #{expected}"}}
  end

  defp certificate_delimiters(:license),
    do: {"-----BEGIN LICENSE FILE-----", "-----END LICENSE FILE-----"}

  defp certificate_delimiters(:machine),
    do: {"-----BEGIN MACHINE FILE-----", "-----END MACHINE FILE-----"}

  defp malformed_state(:license), do: :malformed_license_certificate
  defp malformed_state(:machine), do: :malformed_machine_certificate

  defp invalid_signature_state(:license), do: :invalid_license_signature
  defp invalid_signature_state(:machine), do: :invalid_machine_signature

  defp invalid_signature_message(:license), do: "License certificate signature is invalid."
  defp invalid_signature_message(:machine), do: "Machine certificate signature is invalid."

  defp latest_datetime(nil, nil), do: nil
  defp latest_datetime(%DateTime{} = left, nil), do: left
  defp latest_datetime(nil, %DateTime{} = right), do: right

  defp latest_datetime(%DateTime{} = left, %DateTime{} = right) do
    case DateTime.compare(left, right) do
      :lt -> right
      _other -> left
    end
  end

  defp earliest_datetime(nil, nil), do: nil
  defp earliest_datetime(%DateTime{} = left, nil), do: left
  defp earliest_datetime(nil, %DateTime{} = right), do: right

  defp earliest_datetime(%DateTime{} = left, %DateTime{} = right) do
    case DateTime.compare(left, right) do
      :gt -> right
      _other -> left
    end
  end
end
