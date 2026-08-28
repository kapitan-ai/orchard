defmodule Orchard.CircuitBreakers.Decision do
  @moduledoc """
  Durable circuit-breaker decision returned at the Controller domain boundary.
  """

  @enforce_keys [:kind, :node_id, :state, :contribution_count, :generation]
  defstruct [
    :id,
    :kind,
    :node_id,
    :model_id,
    :state,
    :contribution_count,
    :opened_at,
    :suppressed_until,
    :last_cleared_at,
    :decision_at,
    :previous_state,
    :contribution_disposition,
    :transition,
    :generation,
    :delivery,
    changed_state?: false
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          kind: :node | :placement,
          node_id: Ecto.UUID.t(),
          model_id: Ecto.UUID.t() | nil,
          state: :open | :closed,
          contribution_count: non_neg_integer(),
          opened_at: DateTime.t() | nil,
          suppressed_until: DateTime.t() | nil,
          last_cleared_at: DateTime.t() | nil,
          decision_at: DateTime.t() | nil,
          previous_state: :open | :closed | nil,
          contribution_disposition: :contributed | :fenced | nil,
          transition: :opened | :none | nil,
          generation: non_neg_integer(),
          delivery: :recorded | :duplicate | nil,
          changed_state?: boolean()
        }
end
