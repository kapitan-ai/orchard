defmodule Orchard.Governance.PortalPassword do
  @moduledoc """
  Slow password hashing for named Portal User credentials.

  Production parameters are fixed: Argon2id, 64 MiB, three iterations,
  parallelism one, 16-byte salt, 32-byte hash.
  """

  @hash_opts [
    t_cost: 3,
    m_cost: 16,
    parallelism: 1,
    hashlen: 32,
    argon2_type: 2,
    salt_len: 16
  ]

  @min_code_points 16
  @max_bytes 1024

  @type hash_error :: :password_too_short | :password_too_long
  @type verify_error :: :invalid_password

  @spec hash(String.t()) :: {:ok, String.t()} | {:error, hash_error()}
  def hash(password) when is_binary(password) do
    cond do
      String.length(password) < @min_code_points ->
        {:error, :password_too_short}

      byte_size(password) > @max_bytes ->
        {:error, :password_too_long}

      true ->
        {:ok, Argon2.hash_pwd_salt(password, @hash_opts)}
    end
  end

  @spec verify(String.t(), String.t()) :: :ok | {:error, verify_error()}
  def verify(password, encoded_hash)
      when is_binary(password) and is_binary(encoded_hash) do
    if Argon2.verify_pass(password, encoded_hash) do
      :ok
    else
      {:error, :invalid_password}
    end
  end

  @spec dummy_verify(String.t()) :: {:error, verify_error()}
  def dummy_verify(password) when is_binary(password) do
    Argon2.no_user_verify(@hash_opts)
    {:error, :invalid_password}
  end

  @spec hash_opts() :: keyword()
  def hash_opts, do: @hash_opts
end
