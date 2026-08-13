defmodule Orchard.Inference.AttemptContext do
  @moduledoc """
  Immutable durable identity and start evidence for one inference attempt.
  """

  alias Orchard.Requests.RequestStepEvent

  @enforce_keys [
    :turn_index,
    :attempt,
    :step_id,
    :excluded_node_ids,
    :model_id,
    :model_version
  ]
  defstruct @enforce_keys ++ [:started_at]

  @type t :: %__MODULE__{
          turn_index: 1,
          attempt: 1 | 2,
          step_id: String.t(),
          excluded_node_ids: [Ecto.UUID.t()],
          model_id: String.t(),
          model_version: String.t(),
          started_at: DateTime.t() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    turn_index = value(attrs, :turn_index)
    attempt = value(attrs, :attempt)
    excluded_node_ids = value(attrs, :excluded_node_ids)
    model_id = value(attrs, :model_id)
    model_version = value(attrs, :model_version)

    with :ok <- validate_identity(turn_index, attempt),
         :ok <- validate_exclusions(attempt, excluded_node_ids),
         :ok <- validate_model_identity(model_id, model_version),
         {:ok, started_at} <- optional_datetime(value(attrs, :started_at)) do
      {:ok,
       %__MODULE__{
         turn_index: turn_index,
         attempt: attempt,
         step_id: RequestStepEvent.inference_turn_step_id(turn_index, attempt),
         excluded_node_ids: excluded_node_ids,
         model_id: model_id,
         model_version: model_version,
         started_at: started_at
       }}
    end
  end

  def new(_attrs), do: {:error, "attempt context attrs must be a map"}

  @spec put_started_at(t(), DateTime.t()) :: {:ok, t()} | {:error, String.t()}
  def put_started_at(%__MODULE__{started_at: nil} = context, %DateTime{} = started_at),
    do: {:ok, %{context | started_at: started_at}}

  def put_started_at(%__MODULE__{}, %DateTime{}),
    do: {:error, "started_at is immutable once assigned"}

  def put_started_at(%__MODULE__{}, _started_at), do: {:error, "started_at must be a DateTime"}

  defp validate_identity(1, attempt) when attempt in [1, 2], do: :ok

  defp validate_identity(_turn_index, _attempt),
    do: {:error, "only turn 1 attempts 1 and 2 are supported"}

  defp validate_exclusions(1, []), do: :ok

  defp validate_exclusions(2, [node_id]) do
    case Ecto.UUID.cast(node_id) do
      {:ok, _uuid} -> :ok
      :error -> {:error, "attempt 2 requires one valid excluded Node UUID"}
    end
  end

  defp validate_exclusions(1, _node_ids),
    do: {:error, "attempt 1 requires an empty exclusion list"}

  defp validate_exclusions(2, _node_ids),
    do: {:error, "attempt 2 requires exactly one valid excluded Node UUID"}

  defp validate_model_identity(model_id, model_version)
       when is_binary(model_id) and model_id != "" and is_binary(model_version) and
              model_version != "",
       do: :ok

  defp validate_model_identity(_model_id, _model_version),
    do: {:error, "model_id and model_version must be non-empty strings"}

  defp optional_datetime(nil), do: {:ok, nil}
  defp optional_datetime(%DateTime{} = datetime), do: {:ok, datetime}
  defp optional_datetime(_datetime), do: {:error, "started_at must be a DateTime"}

  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
end
