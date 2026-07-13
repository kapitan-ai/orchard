defmodule Orchard.BeamPeerGrants.Secret do
  @moduledoc """
  Derives an exact-pair BEAM secret from immutable grant scope.

  Encoding version 1 uses the fixed field order in this module and represents
  every value as a four-byte length followed by canonical UTF-8 bytes.
  Timestamps use Unix microseconds and a nil cutover uses an empty value.
  """

  @encoding_version 1
  @minimum_root_bytes 32
  @scope_fields [
    :contract_version,
    :purpose,
    :cluster_id,
    :controller_id,
    :controller_beam_name,
    :controller_certificate_identifier,
    :controller_certificate_fingerprint_sha256,
    :beam_authorization_root_id,
    :node_id,
    :node_beam_name,
    :node_certificate_identifier,
    :node_certificate_fingerprint_sha256,
    :id,
    :generation,
    :issued_at,
    :not_before_at,
    :cutover_at,
    :expires_at
  ]

  @type derived :: %{required(:encoded_secret) => String.t(), required(:secret_hash) => binary()}

  @spec derive(map(), binary()) :: {:ok, derived()} | {:error, :beam_peer_grant_scope_invalid}
  def derive(scope, root) when is_map(scope) and byte_size(root) >= @minimum_root_bytes do
    with {:ok, canonical_values} <- canonical_values(scope) do
      encoded_scope = encode(canonical_values)

      encoded_secret =
        :hmac
        |> :crypto.mac(:sha256, root, encoded_scope)
        |> Base.url_encode64(padding: false)

      {:ok,
       %{
         encoded_secret: encoded_secret,
         secret_hash: :crypto.hash(:sha256, encoded_secret)
       }}
    end
  end

  def derive(_scope, _root), do: {:error, :beam_peer_grant_scope_invalid}

  defp canonical_values(scope) do
    Enum.reduce_while(@scope_fields, {:ok, []}, fn field, {:ok, values} ->
      with {:ok, value} <- Map.fetch(scope, field),
           {:ok, canonical} <- canonical_value(field, value) do
        {:cont, {:ok, [canonical | values]}}
      else
        _other -> {:halt, {:error, :beam_peer_grant_scope_invalid}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp canonical_value(field, value) when field in [:contract_version, :generation] do
    if is_integer(value) and value > 0 do
      {:ok, Integer.to_string(value)}
    else
      {:error, :beam_peer_grant_scope_invalid}
    end
  end

  defp canonical_value(field, %DateTime{} = value)
       when field in [:issued_at, :not_before_at, :cutover_at, :expires_at] do
    {:ok, value |> DateTime.to_unix(:microsecond) |> Integer.to_string()}
  end

  defp canonical_value(:cutover_at, nil), do: {:ok, ""}

  defp canonical_value(_field, value) when is_binary(value) and value != "", do: {:ok, value}
  defp canonical_value(_field, _value), do: {:error, :beam_peer_grant_scope_invalid}

  defp encode(values) do
    values
    |> Enum.reduce(<<@encoding_version::16>>, fn value, encoded ->
      <<encoded::binary, byte_size(value)::32, value::binary>>
    end)
  end
end
