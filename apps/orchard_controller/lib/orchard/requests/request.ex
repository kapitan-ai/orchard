defmodule Orchard.Requests.Request do
  @moduledoc """
  Ecto schema for durable inference request records.

  ## M1 nullability note

  In M1, rows are inserted at the `:received` state before the model is fully
  resolved — so `model_id` and `canonical_request` may be `nil` on early rows.
  `create_changeset/2` intentionally does not require these fields.
  M2 should tighten this once the orchestration pipeline resolves the model
  before persistence.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.{ApiKey, Tenant}
  alias Orchard.Models.Model
  alias Orchard.Requests.RequestEvent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @endpoints [chat_completions: "chat_completions", responses: "responses"]
  @states [
    :received,
    :validated,
    :admitted,
    :queued,
    :scheduled,
    :dispatching,
    :running,
    :streaming,
    :completed,
    :failed,
    :cancelled,
    :timed_out,
    :interrupted
  ]
  @terminal_states [:completed, :failed, :cancelled, :timed_out, :interrupted]
  @payload_capture_modes [none: "none", metadata: "metadata", full: "full"]

  schema "requests" do
    field(:public_id, :string)
    field(:endpoint, Ecto.Enum, values: @endpoints)
    field(:service_account_id, Ecto.UUID)
    field(:requested_model, :string)
    field(:node_id, Ecto.UUID)
    field(:worker_id, Ecto.UUID)
    field(:idempotency_key, :string)
    field(:body_hash, :binary)
    field(:state, Ecto.Enum, values: @states)
    field(:stream, :boolean, default: false)
    field(:payload_capture_mode, Ecto.Enum, values: @payload_capture_modes)
    field(:canonical_request, :map)
    field(:request_payload, :map)
    field(:response_payload, :map)
    field(:response_preview, :string)
    field(:sampling_params, :map, default: %{})
    field(:response_format, :map, default: %{})
    field(:scheduler_decision, :map)
    field(:input_tokens, :integer, default: 0)
    field(:output_tokens, :integer, default: 0)
    field(:reserved_output_tokens, :integer, default: 0)
    field(:first_token_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:timeout_at, :utc_datetime_usec)
    field(:http_status, :integer)
    field(:error_code, :string)
    field(:error_message, :string)

    belongs_to(:tenant, Tenant)
    belongs_to(:api_key, ApiKey)
    belongs_to(:model, Model)
    belongs_to(:retry_of_request, __MODULE__, foreign_key: :retry_of_request_id)
    has_many(:request_events, RequestEvent)

    timestamps(type: :utc_datetime_usec)
  end

  @spec states() :: [atom()]
  def states, do: @states

  @spec terminal_states() :: [atom()]
  def terminal_states, do: @terminal_states

  @doc "Returns the non-terminal (active) lifecycle states."
  @spec active_states() :: [atom()]
  def active_states, do: @states -- @terminal_states

  @spec create_changeset(struct(), map()) :: Ecto.Changeset.t()
  def create_changeset(request, attrs) do
    request
    |> cast(attrs, [
      :public_id,
      :endpoint,
      :tenant_id,
      :api_key_id,
      :service_account_id,
      :model_id,
      :requested_model,
      :node_id,
      :worker_id,
      :retry_of_request_id,
      :idempotency_key,
      :body_hash,
      :state,
      :stream,
      :payload_capture_mode,
      :canonical_request,
      :request_payload,
      :response_payload,
      :response_preview,
      :sampling_params,
      :response_format,
      :scheduler_decision,
      :input_tokens,
      :output_tokens,
      :reserved_output_tokens,
      :first_token_at,
      :completed_at,
      :timeout_at,
      :http_status,
      :error_code,
      :error_message
    ])
    |> validate_required([
      :public_id,
      :endpoint,
      :tenant_id,
      :requested_model,
      :state,
      :stream,
      :payload_capture_mode
    ])
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:reserved_output_tokens, greater_than_or_equal_to: 0)
    |> unique_constraint(:public_id)
    |> unique_constraint(:idempotency_key, name: :idx_requests_tenant_idempotency)
    |> foreign_key_constraint(:model_id)
    |> foreign_key_constraint(:retry_of_request_id)
  end

  @spec terminal_changeset(struct(), map()) :: Ecto.Changeset.t()
  def terminal_changeset(request, attrs) do
    request
    |> cast(attrs, [
      :state,
      :response_payload,
      :response_preview,
      :input_tokens,
      :output_tokens,
      :reserved_output_tokens,
      :first_token_at,
      :completed_at,
      :http_status,
      :error_code,
      :error_message
    ])
    |> validate_required([:state])
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:reserved_output_tokens, greater_than_or_equal_to: 0)
    |> validate_terminal_state()
    |> put_completed_at()
  end

  @spec schedule_changeset(struct(), map()) :: Ecto.Changeset.t()
  def schedule_changeset(request, attrs) do
    request
    |> cast(attrs, [:scheduler_decision, :node_id])
    |> validate_required([:scheduler_decision])
  end

  @spec node_assignment_changeset(struct(), map()) :: Ecto.Changeset.t()
  def node_assignment_changeset(request, attrs) do
    request
    |> cast(attrs, [:node_id])
    |> validate_required([:node_id])
  end

  defp validate_terminal_state(%Ecto.Changeset{} = changeset) do
    state = get_field(changeset, :state)

    if state in @terminal_states do
      changeset
    else
      add_error(changeset, :state, "must be terminal")
    end
  end

  defp put_completed_at(%Ecto.Changeset{} = changeset) do
    case {get_field(changeset, :state), get_field(changeset, :completed_at)} do
      {state, nil} when state in @terminal_states ->
        put_change(
          changeset,
          :completed_at,
          DateTime.utc_now() |> DateTime.truncate(:microsecond)
        )

      _other ->
        changeset
    end
  end
end
