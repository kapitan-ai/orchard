defmodule Orchard.Inference.OutputCommitment do
  @moduledoc """
  Pure monotonic classification of validated externally meaningful inference output.
  """

  alias Orchard.InferenceEvent
  alias Orchard.InferenceEvent.{OutputTextDelta, ToolCallDelta}

  @enforce_keys [:kind]
  defstruct kind: nil

  @type kind :: :text | :tool_call | :structured_output
  @type t :: %__MODULE__{kind: kind() | nil}

  @spec new() :: t()
  def new, do: %__MODULE__{kind: nil}

  @spec observe(t(), InferenceEvent.t()) :: t()
  def observe(%__MODULE__{kind: kind} = commitment, %InferenceEvent{}) when not is_nil(kind),
    do: commitment

  def observe(%__MODULE__{} = commitment, %InferenceEvent{event: %OutputTextDelta{delta: delta}})
      when delta != "",
      do: %__MODULE__{commitment | kind: :text}

  def observe(%__MODULE__{} = commitment, %InferenceEvent{event: %ToolCallDelta{}}),
    do: %__MODULE__{commitment | kind: :tool_call}

  def observe(%__MODULE__{} = commitment, %InferenceEvent{}), do: commitment

  @spec committed?(t()) :: boolean()
  def committed?(%__MODULE__{kind: nil}), do: false
  def committed?(%__MODULE__{}), do: true

  @spec kind(t()) :: kind() | nil
  def kind(%__MODULE__{kind: kind}), do: kind
end
