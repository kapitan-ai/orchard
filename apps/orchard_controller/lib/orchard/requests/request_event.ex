defmodule Orchard.Requests.RequestEvent do
  @moduledoc """
  Ecto schema for append-only request lifecycle events.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Requests.Request

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  @states [
    :received,
    :validated,
    :admitted,
    :queued,
    :scheduled,
    :dispatching,
    :running,
    :streaming,
    :completed,
    :failed,
    :cancelled,
    :timed_out,
    :interrupted
  ]

  schema "request_events" do
    field(:seq, :integer)
    field(:event_type, :string)
    field(:state, Ecto.Enum, values: @states)
    field(:occurred_at, :utc_datetime_usec)
    field(:payload, :map, default: %{})

    belongs_to(:request, Request)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(request_event, attrs) do
    request_event
    |> cast(attrs, [:request_id, :seq, :event_type, :state, :occurred_at, :payload])
    |> validate_required([:request_id, :seq, :event_type])
    |> validate_number(:seq, greater_than: 0)
    |> unique_constraint([:request_id, :seq])
    |> foreign_key_constraint(:request_id)
  end
end
