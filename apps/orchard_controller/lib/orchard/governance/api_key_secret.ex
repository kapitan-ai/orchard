defmodule Orchard.Governance.ApiKeySecret do
  @moduledoc """
  Helpers for governance API-key token generation and verification.

  New tokens use the canonical `orchard_sk_<public>_<secret>` format.
  Legacy `orch_<public>.<secret>` tokens remain valid for authentication.
  Only the display-safe token prefix and a deterministic secret hash are
  persisted.
  """

  import Bitwise

  @canonical_token_namespace "orchard_sk"
  @canonical_prefix_namespace "orchard_kp"
  @legacy_namespace "orch"
  @hash_version "sha256"
  @canonical_token_pattern ~r/\Aorchard_sk_([A-Za-z0-9_-]{16})_([A-Za-z0-9_-]{43})\z/
  @legacy_token_pattern ~r/^orch_([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/
  @public_part_bytes 12
  @secret_part_bytes 32

  @type generated_secret :: %{
          token: String.t(),
          token_prefix: String.t(),
          secret_hash: String.t()
        }

  @spec generate() :: generated_secret()
  def generate do
    public_part = random_part(@public_part_bytes)
    secret_part = random_part(@secret_part_bytes)
    token_prefix = canonical_prefix_from_public_part(public_part)
    token = @canonical_token_namespace <> "_" <> public_part <> "_" <> secret_part

    %{
      token: token,
      token_prefix: token_prefix,
      secret_hash: encode_hash(secret_part)
    }
  end

  @spec canonical_token_prefix(String.t()) :: {:ok, String.t()} | :error
  def canonical_token_prefix(token) when is_binary(token) do
    case parse_canonical(token) do
      {:ok, %{token_prefix: token_prefix}} -> {:ok, token_prefix}
      :error -> :error
    end
  end

  def canonical_token_prefix(_token), do: :error

  @spec token_prefix(String.t()) :: {:ok, String.t()} | :error
  def token_prefix(token) when is_binary(token) do
    case parse(token) do
      {:ok, %{token_prefix: token_prefix}} -> {:ok, token_prefix}
      :error -> :error
    end
  end

  def token_prefix(_token), do: :error

  @spec hash(String.t()) :: String.t()
  def hash(token) when is_binary(token) do
    case parse(token) do
      {:ok, %{hash_input: hash_input}} -> encode_hash(hash_input)
      :error -> encode_hash(token)
    end
  end

  @spec verify(String.t(), String.t()) :: boolean()
  def verify(token, stored_hash) when is_binary(token) and is_binary(stored_hash) do
    with {:ok, %{hash_input: hash_input}} <- parse(token),
         {:ok, stored_digest} <- decode_hash(stored_hash) do
      hash_input
      |> then(&:crypto.hash(:sha256, &1))
      |> secure_compare(stored_digest)
    else
      _ -> false
    end
  end

  def verify(_token, _stored_hash), do: false

  defp decode_hash(stored_hash) do
    case String.split(stored_hash, "$", parts: 2) do
      [@hash_version, digest] -> Base.url_decode64(digest, padding: false)
      _ -> :error
    end
  end

  defp encode_hash(hash_input) do
    digest = :crypto.hash(:sha256, hash_input)
    @hash_version <> "$" <> Base.url_encode64(digest, padding: false)
  end

  defp parse(token) do
    case parse_canonical(token) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> parse_legacy(token)
    end
  end

  defp parse_canonical(token) do
    case Regex.run(@canonical_token_pattern, token) do
      [_, public_part, secret_part] ->
        with :ok <- validate_part(public_part, @public_part_bytes),
             :ok <- validate_part(secret_part, @secret_part_bytes) do
          {:ok,
           %{
             token_prefix: canonical_prefix_from_public_part(public_part),
             hash_input: secret_part
           }}
        end

      _ ->
        :error
    end
  end

  defp parse_legacy(token) do
    case Regex.run(@legacy_token_pattern, token) do
      [_, public_part, _secret_part] when public_part != "" ->
        {:ok,
         %{
           token_prefix: @legacy_namespace <> "_" <> public_part,
           hash_input: token
         }}

      _ ->
        :error
    end
  end

  defp validate_part(encoded, expected_bytes) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, decoded} when byte_size(decoded) == expected_bytes ->
        if Base.url_encode64(decoded, padding: false) == encoded, do: :ok, else: :error

      _ ->
        :error
    end
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    left
    |> :crypto.exor(right)
    |> :binary.bin_to_list()
    |> Enum.reduce(0, fn byte, acc -> acc ||| byte end)
    |> Kernel.==(0)
  end

  defp secure_compare(_left, _right), do: false

  defp random_part(byte_count) do
    byte_count
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp canonical_prefix_from_public_part(public_part) do
    @canonical_prefix_namespace <> "_" <> public_part
  end
end
