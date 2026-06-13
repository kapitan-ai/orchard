defmodule Orchard.ConsoleSettings.Entry do
  @moduledoc """
  Ecto schema for persisted Console settings entries.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}

  @type t :: %__MODULE__{
          key: String.t() | nil,
          value: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "console_settings" do
    field(:value, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
    |> validate_length(:key, min: 1)
  end
end
