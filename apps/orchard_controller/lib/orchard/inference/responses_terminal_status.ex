defmodule Orchard.Inference.ResponsesTerminalStatus do
  @moduledoc """
  Pure `/v1/responses` terminal status projection rules.

  Preserves current inference-era failed/incomplete behavior and stages future
  tool-outcome projection semantics without introducing hosted execution.
  """

  alias Orchard.Inference.{ChatError, ToolExecutionOutcome}
  alias Orchard.InferenceEvent

  @type response_status :: String.t()
  @type failure_status :: String.t()

  @spec inference_failed_status(InferenceEvent.t() | ChatError.t(), keyword()) ::
          response_status()
  def inference_failed_status(event_or_error, opts \\ [])

  def inference_failed_status(%ChatError{} = error, opts) do
    if partial_output_surfaced?(opts) and incomplete_inference_error?(error) do
      "incomplete"
    else
      "failed"
    end
  end

  def inference_failed_status(%InferenceEvent{} = event, opts) do
    event
    |> ChatError.from_failed_event()
    |> inference_failed_status(opts)
  end

  @spec tool_outcome_status(ToolExecutionOutcome.t() | map(), keyword()) ::
          {:ok, failure_status()} | {:error, String.t()}
  def tool_outcome_status(outcome_or_attrs, opts \\ []) do
    with {:ok, %ToolExecutionOutcome{status: status}} <-
           ToolExecutionOutcome.new(outcome_or_attrs) do
      project_tool_outcome_status(status, partial_output_surfaced?(opts))
    end
  end

  @spec tool_outcome_status!(ToolExecutionOutcome.t() | map(), keyword()) :: failure_status()
  def tool_outcome_status!(outcome_or_attrs, opts \\ []) do
    case tool_outcome_status(outcome_or_attrs, opts) do
      {:ok, status} -> status
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec execute_error_status(term(), keyword()) :: response_status()
  def execute_error_status(reason, opts \\ [])

  def execute_error_status({:tool_execution_outcome, outcome_or_attrs}, opts) do
    tool_outcome_status!(outcome_or_attrs, opts)
  end

  def execute_error_status(reason, opts) do
    reason
    |> ChatError.from_execute_error()
    |> inference_failed_status(opts)
  end

  defp incomplete_inference_error?(%ChatError{kind: kind}),
    do: kind in [:request_cancelled, :request_interrupted]

  defp project_tool_outcome_status(:completed, _partial_output_surfaced?),
    do:
      {:error, "completed tool outcomes do not project through failed/incomplete terminal status"}

  defp project_tool_outcome_status(:failed, _partial_output_surfaced?), do: {:ok, "failed"}
  defp project_tool_outcome_status(:timed_out, _partial_output_surfaced?), do: {:ok, "failed"}

  defp project_tool_outcome_status(status, true) when status in [:cancelled, :indeterminate],
    do: {:ok, "incomplete"}

  defp project_tool_outcome_status(status, false) when status in [:cancelled, :indeterminate],
    do: {:ok, "failed"}

  defp partial_output_surfaced?(opts),
    do: Keyword.get(opts, :partial_output_surfaced?, false) == true
end
