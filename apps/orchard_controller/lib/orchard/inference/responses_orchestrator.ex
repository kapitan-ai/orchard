defmodule Orchard.Inference.ResponsesOrchestrator do
  @moduledoc false

  alias Orchard.CanonicalRequest

  alias Orchard.Inference.{
    RequestOrchestrator,
    RequestPreparation,
    ResponsesRequestNormalizer,
    ResponsesRequestValidator,
    ResponsesSerializer
  }

  alias Orchard.InferenceEvent

  @type orchestrate_result ::
          {:ok, CanonicalRequest.t(), [InferenceEvent.t()]}
          | {:replay, struct()}
          | {:error, term()}

  @spec prepare(map(), keyword()) :: {:ok, CanonicalRequest.t(), map()} | {:error, term()}
  def prepare(params, caller_context \\ []) do
    RequestPreparation.prepare(params, caller_context,
      validator: ResponsesRequestValidator,
      normalizer: ResponsesRequestNormalizer
    )
  end

  @spec execute(CanonicalRequest.t(), map(), keyword()) :: orchestrate_result()
  def execute(canonical, model, opts \\ []) do
    response_created_at = Keyword.get(opts, :response_created_at, System.system_time(:second))

    RequestOrchestrator.execute(
      canonical,
      model,
      Keyword.put_new(opts, :success_persistence, fn canonical_request, events ->
        ResponsesSerializer.success_persistence_attrs(
          canonical_request,
          events,
          response_created_at
        )
      end)
    )
  end
end
