defmodule Orchard.Governance.PortalLoginThrottle do
  @moduledoc """
  Per-Organization and per-source failed-login backoff state.

  Fingerprints are HMAC-SHA-256 digests. Raw slugs and IPs are never stored.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  @type t :: %__MODULE__{}

  schema "portal_login_throttles" do
    field(:organization_fingerprint, :binary, primary_key: true)
    field(:source_fingerprint, :binary, primary_key: true)
    field(:failure_count, :integer, default: 0)
    field(:blocked_until, :utc_datetime_usec)
    field(:last_failed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(throttle, attrs) do
    throttle
    |> cast(attrs, [
      :organization_fingerprint,
      :source_fingerprint,
      :failure_count,
      :blocked_until,
      :last_failed_at
    ])
    |> validate_required([:organization_fingerprint, :source_fingerprint, :failure_count])
    |> validate_number(:failure_count, greater_than_or_equal_to: 0)
  end
end
