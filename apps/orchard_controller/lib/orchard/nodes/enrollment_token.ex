defmodule Orchard.Nodes.EnrollmentToken do
  @moduledoc """
  Generates high-entropy Bootstrap Tokens and their persistence-safe representations.
  """

  @namespace "orch_enr"
  @public_part_bytes 12
  @secret_part_bytes 32

  @type generated :: %{
          bootstrap_token: String.t(),
          token_hash: String.t(),
          token_prefix: String.t()
        }

  @spec generate() :: generated()
  def generate do
    public_part = random_part(@public_part_bytes)
    secret_part = random_part(@secret_part_bytes)
    token_prefix = @namespace <> "_" <> public_part
    bootstrap_token = token_prefix <> "." <> secret_part

    %{
      bootstrap_token: bootstrap_token,
      token_prefix: token_prefix,
      token_hash: hash(bootstrap_token)
    }
  end

  @spec verify(String.t(), String.t()) :: boolean()
  def verify(token, expected_hash) when is_binary(token) and is_binary(expected_hash) do
    computed_hash = hash(token)

    byte_size(computed_hash) == byte_size(expected_hash) and
      :crypto.hash_equals(computed_hash, expected_hash)
  end

  def verify(_token, _expected_hash), do: false

  defp hash(token) do
    digest = :crypto.hash(:sha256, token)
    "sha256$" <> Base.url_encode64(digest, padding: false)
  end

  defp random_part(byte_count) do
    byte_count
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
