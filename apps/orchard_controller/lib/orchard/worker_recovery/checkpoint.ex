defmodule Orchard.WorkerRecovery.Checkpoint do
  @moduledoc "Current revision of a Node-owned SPEC §12.2 placement recovery checkpoint."
  use Ecto.Schema

  @primary_key false
  @type t :: %__MODULE__{}

  schema "worker_recovery_checkpoints" do
    field(:node_id, :binary_id, primary_key: true)
    field(:model_id, :binary_id)
    field(:runtime_model_id, :string, primary_key: true)
    field(:version, :string, primary_key: true)
    field(:epoch, :string)
    field(:revision, :integer)
    field(:transition_id, :string)
    field(:fingerprint, :string)
    field(:record, :map)
    timestamps(type: :utc_datetime_usec)
  end
end
