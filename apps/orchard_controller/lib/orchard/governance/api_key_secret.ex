defmodule Orchard.Governance.ApiKeySecret do
  @moduledoc """
  Helpers for governance API-key token generation and verification.

  Tokens use the printable format `orch_<public>.<secret>`. Only the
  token prefix and a deterministic secret hash are persisted.
  """

  import Bitwise

  @namespace "orch"
  @hash_version "sha256"
  @token_pattern ~r/^orch_([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/
  @public_part_bytes 12
  @secret_part_bytes 24

  @type generated_secret :: %{
          token: String.t(),
          token_prefix: String.t(),
          secret_hash: String.t()
        }

  @spec generate() :: generated_secret()
  def generate do
    public_part = random_part(@public_part_bytes)
    secret_part = random_part(@secret_part_bytes)
    token_prefix = token_prefix_from_public_part(public_part)
    token = token_prefix <> "." <> secret_part

    %{
      token: token,
      token_prefix: token_prefix,
      secret_hash: hash(token)
    }
  end

  @spec token_prefix(String.t()) :: {:ok, String.t()} | :error
  def token_prefix(token) when is_binary(token) do
    case Regex.run(@token_pattern, token) do
      [_, public_part, _secret_part] when public_part != "" ->
        {:ok, token_prefix_from_public_part(public_part)}

      _ ->
        :error
    end
  end

  def token_prefix(_token), do: :error

  @spec hash(String.t()) :: String.t()
  def hash(token) when is_binary(token) do
    digest = :crypto.hash(:sha256, token)
    @hash_version <> "$" <> Base.url_encode64(digest, padding: false)
  end

  @spec verify(String.t(), String.t()) :: boolean()
  def verify(token, stored_hash) when is_binary(token) and is_binary(stored_hash) do
    with {:ok, _token_prefix} <- token_prefix(token),
         {:ok, stored_digest} <- decode_hash(stored_hash) do
      token
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

  defp token_prefix_from_public_part(public_part), do: @namespace <> "_" <> public_part
end
