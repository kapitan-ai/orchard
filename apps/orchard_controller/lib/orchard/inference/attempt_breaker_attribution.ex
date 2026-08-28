defmodule Orchard.Inference.AttemptBreakerAttribution do
  @moduledoc """
  Attributes one typed inference-attempt failure to its producing breaker target.

  The failure identity is deterministic for one logical Request and attempt so
  defensive redelivery remains idempotent at the durable breaker boundary.
  """

  alias Orchard.CircuitBreakers
  alias Orchard.CircuitBreakers.Decision
  alias Orchard.Dispatch.AttemptOutcome

  @node_failure_classes ~w(pre_acceptance_unavailable worker_or_node_loss)
  @placement_failure_classes ~w(model_load_failure)

  @type record_error ::
          :invalid_attempt_identity
          | CircuitBreakers.error()
          | Ecto.Changeset.t()

  @spec record(Ecto.UUID.t(), 1 | 2, Ecto.UUID.t(), AttemptOutcome.t()) ::
          {:ok, :not_eligible | Decision.t()} | {:error, record_error()}
  def record(
        request_id,
        attempt,
        model_id,
        %AttemptOutcome{failure: %{"failure_class" => failure_class}} = outcome
      ) do
    case failure_target(failure_class, model_id) do
      :not_eligible ->
        {:ok, :not_eligible}

      {:eligible, _target_model_id} when is_nil(outcome.node_id) ->
        {:ok, :not_eligible}

      {:eligible, target_model_id} ->
        with {:ok, failure_id} <- failure_id(request_id, attempt) do
          CircuitBreakers.record_failure(%{
            failure_id: failure_id,
            node_id: outcome.node_id,
            model_id: target_model_id,
            failure_class: failure_class,
            occurred_at: outcome.ended_at
          })
        end
    end
  end

  def record(_request_id, _attempt, _model_id, %AttemptOutcome{}),
    do: {:ok, :not_eligible}

  defp failure_target(failure_class, _model_id) when failure_class in @node_failure_classes,
    do: {:eligible, nil}

  defp failure_target(failure_class, model_id)
       when failure_class in @placement_failure_classes,
       do: {:eligible, model_id}

  defp failure_target(_failure_class, _model_id), do: :not_eligible

  defp failure_id(request_id, attempt) when attempt in [1, 2] do
    case Ecto.UUID.cast(request_id) do
      {:ok, request_id} ->
        digest =
          :crypto.hash(
            :sha256,
            "orchard:attempt-breaker-failure:v1:#{request_id}:#{attempt}"
          )
          |> Base.encode16(case: :lower)

        <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
          e::binary-size(12), _rest::binary>> = digest

        {:ok, Enum.join([a, b, c, d, e], "-")}

      :error ->
        {:error, :invalid_attempt_identity}
    end
  end

  defp failure_id(_request_id, _attempt), do: {:error, :invalid_attempt_identity}
end
