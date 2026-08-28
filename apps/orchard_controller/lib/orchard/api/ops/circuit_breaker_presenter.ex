defmodule Orchard.API.Ops.CircuitBreakerPresenter do
  @moduledoc """
  Bounded Operator API projection for durable circuit-breaker state.
  """

  alias Orchard.CircuitBreakers.Decision

  @spec breaker(Decision.t()) :: map()
  def breaker(%Decision{} = decision) do
    %{
      object: "circuit_breaker",
      kind: Atom.to_string(decision.kind),
      node_id: decision.node_id,
      model_id: decision.model_id,
      state: Atom.to_string(decision.state),
      contribution_count: decision.contribution_count,
      opened_at: decision.opened_at,
      suppressed_until: decision.suppressed_until,
      last_cleared_at: decision.last_cleared_at,
      generation: decision.generation
    }
  end

  @spec clear_result(Decision.t()) :: map()
  def clear_result(%Decision{} = decision) do
    %{
      result: if(decision.changed_state?, do: "cleared", else: "already_cleared"),
      changed: decision.changed_state?,
      breaker: breaker(decision)
    }
  end
end
