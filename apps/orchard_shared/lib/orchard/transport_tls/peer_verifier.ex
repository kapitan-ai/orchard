defmodule Orchard.TransportTLS.PeerVerifier do
  @moduledoc """
  OTP TLS peer verification that preserves chain failures and enforces an exact
  Orchard URI certificate identity.
  """

  alias Orchard.TransportTLS.CertificateIdentity

  @type state :: %{
          required(:expected_uri) => String.t(),
          optional(:expected_serial) => String.t() | nil,
          optional(:expected_fingerprint) => String.t() | nil
        }

  @spec new(String.t(), keyword()) :: {function(), state()}
  def new(expected_uri, opts \\ []) when is_binary(expected_uri) and expected_uri != "" do
    state = %{
      expected_uri: expected_uri,
      expected_serial: Keyword.get(opts, :serial),
      expected_fingerprint: Keyword.get(opts, :fingerprint)
    }

    {&__MODULE__.verify_fun/3, state}
  end

  @doc false
  @spec verify_fun(tuple(), term(), state()) ::
          {:valid, state()} | {:unknown, state()} | {:fail, term()}
  def verify_fun(_certificate, {:bad_cert, reason}, _state), do: {:fail, reason}
  def verify_fun(_certificate, {:extension, _extension}, state), do: {:unknown, state}
  def verify_fun(_certificate, :valid, state), do: {:valid, state}

  def verify_fun(certificate, :valid_peer, state) do
    with {:ok, identity} <- CertificateIdentity.from_otp(certificate),
         true <- identity.uri_sans == [state.expected_uri],
         true <- matches_optional?(identity.serial, state.expected_serial),
         true <- matches_optional?(identity.fingerprint, state.expected_fingerprint) do
      {:valid, state}
    else
      _other -> {:fail, :orchard_peer_identity_mismatch}
    end
  end

  def verify_fun(_certificate, _event, _state), do: {:fail, :orchard_peer_verification_failed}

  defp matches_optional?(_actual, nil), do: true
  defp matches_optional?(actual, expected), do: actual == expected
end
