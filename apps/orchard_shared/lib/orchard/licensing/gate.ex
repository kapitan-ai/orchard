defmodule Orchard.Licensing.Gate do
  @moduledoc """
  Shared product license gate for Orchard value paths.

  `check/1` returns `:ok` when the current shared enforcement mode is `:off`
  or `:warn`. In `:hard`, it reads local license status through
  `Orchard.Licensing.GateCache` and denies non-valid states with centralized
  operator remediation text.
  """

  alias Orchard.Licensing
  alias Orchard.Licensing.GateCache

  @type denial_reason ::
          :missing
          | :expired
          | :not_yet_valid
          | :invalid_signature
          | :malformed
          | :machine_mismatch

  @type denial :: %{
          required(:reason) => denial_reason(),
          required(:code) => String.t(),
          required(:message) => String.t(),
          required(:activation_guidance) => String.t()
        }

  @activation_guidance "Run `orchardctl license activate --key-stdin` or `orchardctl license activate --key-file PATH`; inspect `orchardctl license status`."

  @doc """
  Require a valid local license when shared enforcement is `:hard`.
  """
  @spec check(Keyword.t()) :: :ok | {:error, Licensing.t()}
  def check(opts \\ []) do
    case Licensing.enforcement_mode() do
      :off -> :ok
      :warn -> :ok
      :hard -> check_hard(opts)
    end
  end

  @doc """
  Alias for `check/1` for call sites that read more clearly as a requirement.
  """
  @spec require_valid(Keyword.t()) :: :ok | {:error, Licensing.t()}
  def require_valid(opts \\ []), do: check(opts)

  @doc """
  Clear cached license status after activation or test fixture changes.
  """
  @spec refresh() :: :ok
  def refresh, do: GateCache.refresh()

  @doc """
  Return the stable denial payload for a non-valid license status.
  """
  @spec denial(Licensing.t()) :: denial()
  def denial(%Licensing{} = status) do
    reason = denial_reason(status)

    %{
      reason: reason,
      code: denial_code(reason),
      message: denial_message(reason),
      activation_guidance: activation_guidance(reason)
    }
  end

  @doc """
  Classify a local license status into a stable product-gate denial reason.
  """
  @spec denial_reason(Licensing.t()) :: denial_reason()
  def denial_reason(%Licensing{state: state})
      when state in [:missing_bundle, :identity_missing],
      do: :missing

  def denial_reason(%Licensing{state: :expired}), do: :expired
  def denial_reason(%Licensing{state: :not_yet_valid}), do: :not_yet_valid

  def denial_reason(%Licensing{state: state})
      when state in [:invalid_license_signature, :invalid_machine_signature],
      do: :invalid_signature

  def denial_reason(%Licensing{state: :fingerprint_mismatch}), do: :machine_mismatch

  def denial_reason(%Licensing{state: state})
      when state in [
             :malformed_bundle,
             :malformed_license_certificate,
             :malformed_machine_certificate,
             :config_error,
             :read_error
           ],
      do: :malformed

  defp check_hard(opts) do
    case GateCache.status(opts) do
      %Licensing{state: :valid} -> :ok
      %Licensing{} = status -> {:error, with_denial_message(status)}
    end
  end

  defp with_denial_message(%Licensing{} = status) do
    payload = denial(status)
    %{status | message: payload.message <> " " <> payload.activation_guidance}
  end

  defp denial_code(:missing), do: "license_required"
  defp denial_code(:expired), do: "license_expired"
  defp denial_code(:not_yet_valid), do: "license_not_yet_valid"
  defp denial_code(:invalid_signature), do: "license_invalid_signature"
  defp denial_code(:malformed), do: "license_malformed"
  defp denial_code(:machine_mismatch), do: "license_machine_mismatch"

  defp denial_message(:missing), do: "Orchard requires an activated license before product use."
  defp denial_message(:expired), do: "The Orchard license has expired."
  defp denial_message(:not_yet_valid), do: "The Orchard license is not valid yet."

  defp denial_message(:invalid_signature) do
    "The installed Orchard license bundle failed signature validation."
  end

  defp denial_message(:malformed) do
    "The installed Orchard license bundle is unreadable or malformed."
  end

  defp denial_message(:machine_mismatch) do
    "The installed Orchard license is bound to a different machine."
  end

  defp activation_guidance(:expired) do
    "Activate a current license with `orchardctl license activate --key-stdin` or `orchardctl license activate --key-file PATH`; inspect `orchardctl license status`."
  end

  defp activation_guidance(_reason), do: @activation_guidance
end
