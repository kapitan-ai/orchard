defmodule Orchard.RuntimeEndpoint.Client do
  @moduledoc """
  Controller-facing Runtime Endpoint client behavior.

  Implementations may use gRPC, BEAM Distribution, or another transport.
  Callers exchange transport-independent Runtime Endpoint domain structs.

  Streaming implementations send messages to the process in `:owner`:

    * `{:runtime_endpoint_event, stream_ref, request_id, event}`
    * `{:runtime_endpoint_done, stream_ref, :ok | {:error, reason}}`

  Disconnect is cleanup-only. Callers treat disconnect failures as best-effort
  cleanup and preserve the status, scheduling, or dispatch outcome already
  produced by the Runtime Endpoint operation.
  """

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.{ModelRef, Observation, Operation, Target}

  @type connection :: term()
  @type stream_ref :: reference()

  @callback connect(Target.t() | keyword()) :: {:ok, connection()} | {:error, term()}
  @callback disconnect(connection()) :: :ok
  @callback status(connection(), keyword()) :: {:ok, Observation.t()} | {:error, term()}
  @callback inspect_worker_recovery(connection(), ModelRef.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback recover_worker_placement(connection(), map(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @optional_callbacks inspect_worker_recovery: 3, recover_worker_placement: 3

  @callback ensure_model_loaded(connection(), Operation.EnsureModelLoadedRequest.t(), keyword()) ::
              {:ok, Operation.EnsureModelLoadedResult.t()} | {:error, term()}
  @callback unload_model(connection(), Operation.UnloadModelRequest.t(), keyword()) ::
              {:ok, Operation.Ack.t()} | {:error, term()}
  @callback execute_inference(connection(), Operation.ExecuteRequest.t(), keyword()) ::
              {:ok, stream_ref()}
  @callback cancel_inference(connection(), Operation.CancelRequest.t(), keyword()) ::
              :ok | {:error, term()}
  @callback score_prefix_cache(
              Target.t() | connection(),
              Operation.PrefixCacheScoreRequest.t(),
              keyword()
            ) ::
              {:ok, Operation.PrefixCacheScoreResult.t()} | {:error, term()}

  @type stream_event_message ::
          {:runtime_endpoint_event, stream_ref(), String.t(), InferenceEvent.t()}
  @type stream_done_message :: {:runtime_endpoint_done, stream_ref(), :ok | {:error, term()}}
end
