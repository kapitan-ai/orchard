defmodule Orchard.Requests do
  @moduledoc """
  Persistence context for durable request rows and lifecycle events.
  """

  import Ecto.Query

  alias Orchard.ClusterManagement.SchedulerExplanation
  alias Orchard.Repo
  alias Orchard.Requests.{CapturePolicy, Request, RequestEvent, RequestStepEvent}

  @spec create_request(map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def create_request(attrs) do
    %Request{}
    |> Request.create_changeset(capture_create_attrs(attrs))
    |> Repo.insert()
  end

  defp capture_create_attrs(attrs) do
    mode = Map.get(attrs, :payload_capture_mode) || Map.get(attrs, "payload_capture_mode")

    case CapturePolicy.normalize_mode(mode) do
      {:ok, normalized_mode} -> CapturePolicy.create_attrs(normalized_mode, attrs)
      :error -> CapturePolicy.create_attrs(CapturePolicy.strictest_mode(), attrs)
    end
  end

  @spec get_request!(Ecto.UUID.t()) :: struct()
  def get_request!(id), do: Repo.get!(Request, id)

  @spec get_request_by_public_id(String.t()) :: struct() | nil
  def get_request_by_public_id(public_id) do
    Request
    |> where([r], r.public_id == ^public_id)
    |> preload([:retry_of_request, :tenant, :api_key])
    |> Repo.one()
  end

  @spec get_request_by_tenant_and_idempotency_key(Ecto.UUID.t(), String.t()) :: struct() | nil
  def get_request_by_tenant_and_idempotency_key(tenant_id, idempotency_key) do
    Request
    |> where([r], r.tenant_id == ^tenant_id and r.idempotency_key == ^idempotency_key)
    |> Repo.one()
  end

  @spec list_request_events(struct() | Ecto.UUID.t()) :: [struct()]
  def list_request_events(%Request{id: request_id}), do: list_request_events(request_id)

  def list_request_events(request_id) do
    RequestEvent
    |> where([event], event.request_id == ^request_id)
    |> order_by([event], asc: event.seq)
    |> Repo.all()
  end

  @spec list_request_step_events(struct() | Ecto.UUID.t()) :: [RequestStepEvent.t()]
  def list_request_step_events(%Request{id: request_id}), do: list_request_step_events(request_id)

  def list_request_step_events(request_id) do
    step_event_types = RequestStepEvent.step_event_types()

    RequestEvent
    |> where(
      [event],
      event.request_id == ^request_id and event.event_type in ^step_event_types
    )
    |> order_by([event], asc: event.seq)
    |> Repo.all()
    |> Enum.flat_map(&readable_step_event/1)
  end

  defp readable_step_event(request_event) do
    case RequestStepEvent.from_request_event(request_event) do
      {:ok, step_event} -> [step_event]
      {:error, _reason} -> []
    end
  end

  @doc """
  Classifies the persisted missing-finish-reason fingerprint for one inference turn.

  This candidate signal is bounded to the current dispatcher and orchestrator
  persistence invariants and to the retention lifetime of `request_events`.
  It is not general conformance evidence for `SPEC.md` section 7.5.5.
  Missing, malformed, ambiguous, or state-inconsistent evidence is inconclusive.
  """
  @spec classify_missing_terminal_candidate(Request.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, :missing_finish_reason_candidate | :not_candidate}
          | {:error, {:inconclusive, atom()}}
  def classify_missing_terminal_candidate(request_or_id, opts \\ [])

  def classify_missing_terminal_candidate(request_or_id, opts) when is_list(opts) do
    with {:ok, selector} <- missing_terminal_selector(opts),
         {:ok, request} <- fetch_detector_request(request_or_id),
         :ok <- require_terminal_request(request),
         {:ok, terminal_step} <- fetch_terminal_inference_turn(request.id, selector),
         :ok <- validate_terminal_step_state(request.state, terminal_step.event_type) do
      classify_terminal_step(terminal_step)
    end
  end

  def classify_missing_terminal_candidate(_request_or_id, _opts),
    do: inconclusive(:invalid_selector)

  defp missing_terminal_selector(opts) do
    if Keyword.keyword?(opts) do
      build_missing_terminal_selector(opts)
    else
      inconclusive(:invalid_selector)
    end
  end

  defp build_missing_terminal_selector(opts) do
    turn_index = Keyword.get(opts, :turn_index, 1)
    attempt = Keyword.get(opts, :attempt, 1)

    if Keyword.keys(opts) -- [:turn_index, :attempt] == [] and
         is_integer(turn_index) and turn_index > 0 and
         is_integer(attempt) and attempt > 0 do
      {:ok, %{step_id: RequestStepEvent.inference_turn_step_id(turn_index, attempt)}}
    else
      inconclusive(:invalid_selector)
    end
  end

  defp fetch_detector_request(%Request{id: request_id}), do: fetch_detector_request(request_id)

  defp fetch_detector_request(request_id) do
    case Ecto.UUID.cast(request_id) do
      {:ok, request_uuid} ->
        case Repo.get(Request, request_uuid) do
          %Request{} = request -> {:ok, request}
          nil -> inconclusive(:request_not_found)
        end

      :error ->
        inconclusive(:request_not_found)
    end
  end

  defp require_terminal_request(%Request{state: state}) do
    if state in Request.terminal_states() do
      :ok
    else
      inconclusive(:request_not_terminal)
    end
  end

  defp fetch_terminal_inference_turn(request_id, %{step_id: step_id}) do
    request_id
    |> terminal_inference_turn_events()
    |> Enum.filter(&(step_event_payload(&1)["step_id"] == step_id))
    |> classify_terminal_rows()
  end

  defp terminal_inference_turn_events(request_id) do
    event_types = RequestStepEvent.terminal_step_event_types()

    RequestEvent
    |> where(
      [event],
      event.request_id == ^request_id and event.event_type in ^event_types and
        fragment("?->>? = ?", event.payload, "step_type", "inference_turn")
    )
    |> order_by([event], asc: event.seq)
    |> Repo.all()
  end

  defp step_event_payload(%RequestEvent{payload: payload}) when is_map(payload), do: payload
  defp step_event_payload(%RequestEvent{}), do: %{}

  defp classify_terminal_rows([]), do: inconclusive(:terminal_step_not_found)

  defp classify_terminal_rows([event]) do
    case RequestStepEvent.from_request_event(event) do
      {:ok, step_event} -> {:ok, step_event}
      {:error, _reason} -> inconclusive(:invalid_terminal_step)
    end
  end

  defp classify_terminal_rows(_events), do: inconclusive(:ambiguous_terminal_steps)

  defp validate_terminal_step_state(request_state, event_type) do
    case RequestStepEvent.fetch_terminal_step_event_type(request_state) do
      {:ok, expected_event_type} ->
        compare_terminal_step_event_type(event_type, expected_event_type)

      :error ->
        inconclusive(:terminal_state_mismatch)
    end
  end

  defp compare_terminal_step_event_type(event_type, event_type), do: :ok

  defp compare_terminal_step_event_type(_event_type, _expected),
    do: inconclusive(:terminal_state_mismatch)

  defp classify_terminal_step(%RequestStepEvent{event_type: "request_step.completed"} = step) do
    case Map.fetch(step.result, "result_invalid") do
      {:ok, _invalid_marker} -> inconclusive(:invalid_terminal_step)
      :error -> classify_finish_reason_evidence(step.result)
    end
  end

  defp classify_terminal_step(%RequestStepEvent{}), do: {:ok, :not_candidate}

  defp classify_finish_reason_evidence(result) do
    case Map.fetch(result, "finish_reason_invalid") do
      {:ok, true} ->
        inconclusive(:invalid_finish_reason)

      {:ok, _invalid_marker} ->
        inconclusive(:invalid_finish_reason_marker)

      :error ->
        classify_completed_finish_reason(result)
    end
  end

  defp classify_completed_finish_reason(result) do
    case Map.fetch(result, "finish_reason") do
      :error ->
        {:ok, :missing_finish_reason_candidate}

      {:ok, finish_reason} when finish_reason in ["stop", "length", "tool_calls"] ->
        {:ok, :not_candidate}

      {:ok, _invalid} ->
        inconclusive(:invalid_finish_reason)
    end
  end

  defp inconclusive(reason), do: {:error, {:inconclusive, reason}}

  @spec append_request_event(struct() | Ecto.UUID.t(), map()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | :request_not_found}
  def append_request_event(%Request{id: request_id}, attrs),
    do: append_request_event(request_id, attrs)

  def append_request_event(request_id, attrs) do
    Repo.transaction(fn ->
      case lock_request(request_id) do
        {:ok, request} ->
          insert_event_and_sync_state(request, request_id, attrs)

        {:error, :request_not_found} ->
          Repo.rollback(:request_not_found)
      end
    end)
    |> unwrap_transaction_result()
  end

  @spec append_request_step_events(struct() | Ecto.UUID.t(), [RequestStepEvent.t() | map()]) ::
          {:ok, [RequestStepEvent.t()]}
          | {:error,
             Ecto.Changeset.t()
             | :request_not_found
             | {:invalid_step_event, pos_integer(), String.t()}}
  def append_request_step_events(%Request{id: request_id}, step_events),
    do: append_request_step_events(request_id, step_events)

  def append_request_step_events(request_id, step_events) when is_list(step_events) do
    case normalize_request_step_events(step_events) do
      {:ok, normalized_step_events} ->
        append_normalized_request_step_events(request_id, normalized_step_events)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec append_attempt_two_dispatch_transition(struct() | Ecto.UUID.t()) ::
          {:ok, struct()}
          | {:error,
             Ecto.Changeset.t()
             | :request_not_found
             | :request_not_running
             | :attempt_two_boundary_missing
             | :attempt_two_dispatch_already_started}
  def append_attempt_two_dispatch_transition(%Request{id: request_id}),
    do: append_attempt_two_dispatch_transition(request_id)

  def append_attempt_two_dispatch_transition(request_id) do
    Repo.transaction(fn ->
      with {:ok, request} <- lock_request(request_id),
           :ok <- authorize_attempt_two_source_state(request.state),
           :ok <- authorize_attempt_two_dispatch(request_id) do
        insert_event_and_sync_state(request, request_id, %{
          event_type: "state_transition",
          state: :dispatching,
          payload: %{
            source: "automatic_attempt_retry",
            attempt: 2,
            to_state: "dispatching"
          }
        })
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  defp insert_event_and_sync_state(request, request_id, attrs) do
    event_attrs =
      attrs
      |> normalize_request_event_attrs()
      |> then(&CapturePolicy.event_attrs(request.payload_capture_mode, &1))
      |> Map.put("request_id", request_id)
      |> Map.put("seq", next_request_event_seq(request_id))
      |> default_occurred_at()

    # Atomically advance requests.state when the event carries a
    # state value. This keeps the row in sync with events for
    # active-state queries and index correctness (P1 review fix).
    sync_request_state(request, event_attrs, attrs)

    %RequestEvent{}
    |> RequestEvent.changeset(event_attrs)
    |> Repo.insert()
  end

  defp insert_request_step_events(request, step_events) do
    step_events
    |> Enum.with_index(next_request_event_seq(request.id))
    |> Enum.reduce_while([], fn {step_event, seq}, acc ->
      event_attrs =
        step_event
        |> RequestStepEvent.to_request_event_attrs!()
        |> then(&CapturePolicy.event_attrs(request.payload_capture_mode, &1))
        |> Map.put("request_id", request.id)
        |> Map.put("seq", seq)
        |> default_occurred_at()

      case %RequestEvent{} |> RequestEvent.changeset(event_attrs) |> Repo.insert() do
        {:ok, request_event} ->
          persisted_step_event = RequestStepEvent.from_request_event!(request_event)

          {:cont, [persisted_step_event | acc]}

        {:error, changeset} ->
          Repo.rollback({:request_event_changeset, changeset})
      end
    end)
    |> Enum.reverse()
    |> then(&{:ok, &1})
  end

  defp append_normalized_request_step_events(request_id, normalized_step_events) do
    Repo.transaction(fn ->
      case lock_request(request_id) do
        {:ok, request} ->
          insert_request_step_events(request, normalized_step_events)

        {:error, :request_not_found} ->
          Repo.rollback(:request_not_found)
      end
    end)
    |> unwrap_transaction_result()
  end

  defp authorize_attempt_two_source_state(state) when state in [:running, :dispatching], do: :ok
  defp authorize_attempt_two_source_state(_state), do: {:error, :request_not_running}

  defp authorize_attempt_two_dispatch(request_id) do
    events =
      RequestEvent
      |> where([event], event.request_id == ^request_id)
      |> order_by([event], asc: event.seq)
      |> Repo.all()

    cond do
      Enum.any?(events, &automatic_attempt_two_dispatch?/1) ->
        {:error, :attempt_two_dispatch_already_started}

      valid_attempt_two_boundary?(events) ->
        :ok

      true ->
        {:error, :attempt_two_boundary_missing}
    end
  end

  defp automatic_attempt_two_dispatch?(%RequestEvent{
         event_type: "state_transition",
         state: :dispatching,
         payload: payload
       }) do
    payload["source"] == "automatic_attempt_retry" and payload["attempt"] == 2 and
      payload["to_state"] == "dispatching"
  end

  defp automatic_attempt_two_dispatch?(%RequestEvent{}), do: false

  defp valid_attempt_two_boundary?(events) do
    step_events =
      Enum.flat_map(events, fn event ->
        case RequestStepEvent.from_request_event(event) do
          {:ok, step_event} -> [step_event]
          {:error, _reason} -> []
        end
      end)

    attempt_one_terminals =
      Enum.filter(step_events, fn step ->
        step.attempt == 1 and
          step.event_type in RequestStepEvent.terminal_step_event_types() and
          step.result["retry_decision"] == "retried" and
          step.result["output_committed"] == false
      end)

    attempt_two_starts =
      Enum.filter(step_events, fn step ->
        step.attempt == 2 and step.event_type == "request_step.started"
      end)

    case {attempt_one_terminals, attempt_two_starts} do
      {[%RequestStepEvent{seq: terminal_seq}], [%RequestStepEvent{seq: started_seq}]} ->
        started_seq == terminal_seq + 1

      _other ->
        false
    end
  end

  defp sync_request_state(request, event_attrs, raw_attrs) do
    new_state = Map.get(event_attrs, "state") || Map.get(raw_attrs, :state)

    if new_state && new_state != request.state do
      request
      |> Ecto.Changeset.change(state: new_state)
      |> Repo.update!()
    end
  end

  @spec mark_terminal(struct(), map()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | :already_terminal | :request_not_found}
  def mark_terminal(%Request{id: request_id}, attrs) do
    Repo.transaction(fn ->
      case lock_request(request_id) do
        {:ok, current_request} ->
          apply_terminal_update(current_request, attrs)

        {:error, :request_not_found} ->
          Repo.rollback(:request_not_found)
      end
    end)
    |> unwrap_transaction_result()
  end

  @spec mark_terminal_with_step_events(
          struct() | Ecto.UUID.t(),
          map(),
          [RequestStepEvent.t() | map()]
        ) ::
          {:ok, struct()}
          | {:error,
             Ecto.Changeset.t()
             | :already_terminal
             | :request_not_found
             | {:invalid_step_event, pos_integer(), String.t()}}
  def mark_terminal_with_step_events(%Request{id: request_id}, attrs, step_events),
    do: mark_terminal_with_step_events(request_id, attrs, step_events)

  def mark_terminal_with_step_events(request_id, attrs, step_events) when is_list(step_events) do
    with {:ok, normalized_step_events} <- normalize_request_step_events(step_events) do
      Repo.transaction(fn ->
        mark_terminal_transaction(request_id, attrs, normalized_step_events)
      end)
      |> unwrap_transaction_result()
    end
  end

  defp mark_terminal_transaction(request_id, attrs, normalized_step_events) do
    case lock_request(request_id) do
      {:ok, current_request} ->
        mark_locked_terminal_request(current_request, attrs, normalized_step_events)

      {:error, :request_not_found} ->
        Repo.rollback(:request_not_found)
    end
  end

  defp mark_locked_terminal_request(current_request, attrs, normalized_step_events) do
    case terminal_step_insert_mode(current_request, attrs) do
      :append ->
        append_steps_and_apply_terminal_update(current_request, attrs, normalized_step_events)

      :skip ->
        apply_terminal_update(current_request, attrs)

      :already_terminal ->
        Repo.rollback(:already_terminal)
    end
  end

  defp append_steps_and_apply_terminal_update(current_request, attrs, normalized_step_events) do
    {:ok, _step_events} = insert_request_step_events(current_request, normalized_step_events)

    case apply_terminal_update(current_request, attrs) do
      {:ok, updated_request} -> {:ok, updated_request}
      {:error, changeset} -> Repo.rollback({:request_changeset, changeset})
    end
  end

  defp apply_terminal_update(%Request{} = request, attrs) do
    attrs = CapturePolicy.terminal_attrs(request.payload_capture_mode, attrs)

    # Allow idempotent terminal updates: if the row is already in a terminal
    # state (set by append_request_event's atomic state sync), still apply
    # the terminal metadata (usage, timestamps, error fields). Only reject
    # if this would overwrite a *different* terminal state.
    target_state = Map.get(attrs, :state) || Map.get(attrs, "state")

    cond do
      request.state not in Request.terminal_states() ->
        request |> Request.terminal_changeset(attrs) |> Repo.update()

      target_state != nil and request.state == target_state ->
        # Same terminal state — apply metadata update idempotently
        request |> Request.terminal_changeset(attrs) |> Repo.update()

      true ->
        Repo.rollback(:already_terminal)
    end
  end

  defp terminal_step_insert_mode(%Request{} = request, attrs) do
    target_state = Map.get(attrs, :state) || Map.get(attrs, "state")

    cond do
      request.state not in Request.terminal_states() -> :append
      target_state != nil and request.state == target_state -> :skip
      true -> :already_terminal
    end
  end

  @doc """
  Returns recent completed request node IDs with matching cache-affinity metadata.
  """
  @spec recent_cache_affinity_nodes(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: [Ecto.UUID.t()]
  def recent_cache_affinity_nodes(tenant_id, model_id, version, affinity_key, opts \\ []) do
    max_age_ms = bounded_non_negative_integer(Keyword.get(opts, :max_age_ms, 300_000), 300_000)

    max_recent_requests =
      bounded_positive_integer(Keyword.get(opts, :max_recent_requests, 32), 32)

    now = Keyword.get(opts, :now, utc_now())
    cutoff = DateTime.add(now, -max_age_ms, :millisecond)
    requested_model = "#{model_id}@#{version}"

    Request
    |> where([request], request.tenant_id == ^tenant_id)
    |> where([request], request.requested_model == ^requested_model)
    |> where([request], request.state == :completed)
    |> where([request], not is_nil(request.node_id) and not is_nil(request.completed_at))
    |> where([request], request.completed_at >= ^cutoff)
    |> where(
      [request],
      fragment("?->>? = ?", request.scheduler_decision, "cache_affinity_key", ^affinity_key)
    )
    |> order_by([request], desc: request.completed_at)
    |> limit(^max_recent_requests)
    |> select([request], request.node_id)
    |> Repo.all()
    |> Enum.uniq()
  end

  @doc """
  Persists the scheduler decision onto the request row.

  Sets `scheduler_decision` (normalized to JSON-safe map) and optionally
  sets `node_id` when the schedule contains a non-nil UUID.

  When the schedule carries scheduler-explanation candidate keys
  (`scored_candidates`, `rejected_candidates`, or `skipped_candidates`), they
  are validated against the shared `SchedulerExplanation` contract before
  persistence; an invalid explanation returns
  `{:error, {:invalid_scheduler_explanation, reason}}` and persists nothing.
  """
  @spec record_schedule(struct() | Ecto.UUID.t(), map()) ::
          {:ok, struct()}
          | {:error,
             Ecto.Changeset.t()
             | :request_not_found
             | :already_terminal
             | {:invalid_scheduler_explanation, term()}}
  def record_schedule(%Request{id: request_id}, schedule),
    do: record_schedule(request_id, schedule)

  def record_schedule(request_id, schedule) do
    Repo.transaction(fn ->
      with {:ok, request} <- lock_request(request_id),
           {:ok, normalized_schedule} <- normalize_schedule(schedule) do
        persist_schedule(request, schedule, normalized_schedule)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  defp persist_schedule(request, schedule, normalized_schedule) do
    attrs =
      %{
        scheduler_decision:
          CapturePolicy.schedule_attrs(request.payload_capture_mode, normalized_schedule, %{
            requested_model: request.requested_model
          })
      }
      |> maybe_put_schedule_node_id(schedule)

    request
    |> Request.schedule_changeset(attrs)
    |> Repo.update()
  end

  defp maybe_put_schedule_node_id(attrs, schedule) do
    node_id = Map.get(schedule, :node_id, Map.get(schedule, "node_id"))

    case Ecto.UUID.cast(node_id) do
      {:ok, uuid} -> Map.put(attrs, :node_id, uuid)
      :error -> attrs
    end
  end

  @doc """
  Assigns a runtime-discovered node UUID to the request row.

  Overwrites any existing `node_id` (including scheduler-attributed values)
  because the runtime-discovered identity is authoritative.
  """
  @spec assign_node(struct() | Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | :request_not_found}
  def assign_node(%Request{id: request_id}, node_id),
    do: assign_node(request_id, node_id)

  def assign_node(request_id, node_id) do
    Repo.transaction(fn ->
      case lock_request(request_id) do
        {:ok, request} ->
          request
          |> Request.node_assignment_changeset(%{node_id: node_id})
          |> Repo.update()

        {:error, :request_not_found} ->
          Repo.rollback(:request_not_found)
      end
    end)
    |> unwrap_transaction_result()
  end

  defp bounded_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp bounded_non_negative_integer(_value, default), do: default

  defp bounded_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp bounded_positive_integer(_value, default), do: default

  defp normalize_schedule(schedule) when is_map(schedule) do
    normalized = normalize_schedule_value(schedule)

    case validate_scheduler_explanation(normalized) do
      :ok -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_scheduler_explanation, reason}}
    end
  end

  defp validate_scheduler_explanation(schedule) do
    if scheduler_explanation?(schedule) do
      SchedulerExplanation.validate_map(schedule)
    else
      :ok
    end
  end

  defp scheduler_explanation?(schedule) do
    Enum.any?(
      ~w(scored_candidates rejected_candidates skipped_candidates),
      &Map.has_key?(schedule, &1)
    )
  end

  defp normalize_schedule_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {normalize_schedule_key(key), normalize_schedule_value(nested_value)}
    end)
  end

  defp normalize_schedule_value(value) when is_list(value) do
    if value != [] and Keyword.keyword?(value) do
      Map.new(value, fn {key, nested_value} ->
        {normalize_schedule_key(key), normalize_schedule_value(nested_value)}
      end)
    else
      Enum.map(value, &normalize_schedule_value/1)
    end
  end

  defp normalize_schedule_value(nil), do: nil
  defp normalize_schedule_value(value) when is_boolean(value), do: value
  defp normalize_schedule_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_schedule_value(value), do: value

  defp normalize_schedule_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_schedule_key(key), do: key

  defp lock_request(request_id) do
    request =
      Request
      |> where([request], request.id == ^request_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case request do
      nil -> {:error, :request_not_found}
      request -> {:ok, request}
    end
  end

  defp normalize_request_event_attrs(attrs) do
    attrs
    |> Map.new()
    |> Map.new(fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp default_occurred_at(%{"occurred_at" => nil} = attrs),
    do: Map.put(attrs, "occurred_at", utc_now())

  defp default_occurred_at(%{"occurred_at" => _occurred_at} = attrs), do: attrs
  defp default_occurred_at(attrs), do: Map.put(attrs, "occurred_at", utc_now())

  defp utc_now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end

  defp next_request_event_seq(request_id) do
    RequestEvent
    |> where([event], event.request_id == ^request_id)
    |> select([event], max(event.seq))
    |> Repo.one()
    |> case do
      nil -> 1
      seq -> seq + 1
    end
  end

  defp normalize_request_step_events(step_events) do
    step_events
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {step_event, index}, {:ok, acc} ->
      case RequestStepEvent.new(step_event) do
        {:ok, normalized_step_event} ->
          {:cont, {:ok, [normalized_step_event | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_step_event, index, reason}}}
      end
    end)
    |> case do
      {:ok, normalized_step_events} -> {:ok, Enum.reverse(normalized_step_events)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns recent requests ordered by insertion time (newest first).

  Ordering is deterministic: `inserted_at DESC`, then `id DESC` for
  tie-breaking. No preloads are applied — this is intended for cheap
  polling by the console requests index page.

  Returns `[]` when no requests exist.
  """
  @spec list_recent_requests(pos_integer()) :: [Request.t()]
  def list_recent_requests(limit \\ 50) do
    limit = if is_integer(limit) and limit > 0, do: limit, else: 50

    Request
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns a summary of request counts grouped by lifecycle state.

  All states from `Request.states/0` are present in `by_state`, zero-filled
  when no rows exist for that state. `active` and `terminal` are derived
  from the canonical state partitions.
  """
  @spec summary() :: %{
          total: non_neg_integer(),
          active: non_neg_integer(),
          terminal: non_neg_integer(),
          by_state: %{required(atom()) => non_neg_integer()}
        }
  def summary do
    counts =
      Request
      |> group_by([r], r.state)
      |> select([r], {r.state, count(r.id)})
      |> Repo.all()
      |> Map.new()

    by_state = zero_fill_states(counts, Request.states())
    total = by_state |> Map.values() |> Enum.sum()
    active = sum_states(by_state, Request.active_states())
    terminal = sum_states(by_state, Request.terminal_states())

    %{total: total, active: active, terminal: terminal, by_state: by_state}
  end

  defp zero_fill_states(counts, states) do
    Map.new(states, fn state -> {state, Map.get(counts, state, 0)} end)
  end

  defp sum_states(by_state, states) do
    Enum.reduce(states, 0, fn state, acc -> acc + Map.get(by_state, state, 0) end)
  end

  @doc """
  Returns aggregate performance metrics over completed requests with valid
  timing data.

  Eligibility: `state == :completed`, both `first_token_at` and `completed_at`
  present, `completed_at > first_token_at`, and `output_tokens > 0`.

  Returns a map with `sample_size` (integer) and average metrics (float or nil
  when no eligible rows exist).
  """
  @spec performance_summary() :: %{
          avg_ttft_ms: float() | nil,
          avg_generation_ms: float() | nil,
          avg_total_latency_ms: float() | nil,
          avg_tokens_per_second: float() | nil,
          sample_size: non_neg_integer()
        }
  def performance_summary do
    Request
    |> where([r], r.state == :completed)
    |> where([r], not is_nil(r.first_token_at) and not is_nil(r.completed_at))
    |> where([r], r.completed_at > r.first_token_at and r.output_tokens > 0)
    |> select([r], %{
      sample_size: count(r.id),
      avg_ttft_ms:
        avg(
          fragment(
            "EXTRACT(EPOCH FROM (? - ?)) * 1000.0",
            r.first_token_at,
            r.inserted_at
          )
        ),
      avg_generation_ms:
        avg(
          fragment(
            "EXTRACT(EPOCH FROM (? - ?)) * 1000.0",
            r.completed_at,
            r.first_token_at
          )
        ),
      avg_total_latency_ms:
        avg(
          fragment(
            "EXTRACT(EPOCH FROM (? - ?)) * 1000.0",
            r.completed_at,
            r.inserted_at
          )
        ),
      avg_tokens_per_second:
        avg(
          fragment(
            "?::float / NULLIF(EXTRACT(EPOCH FROM (? - ?)), 0)",
            r.output_tokens,
            r.completed_at,
            r.first_token_at
          )
        )
    })
    |> Repo.one()
    |> normalize_performance_summary()
  end

  defp normalize_performance_summary(row) do
    %{
      sample_size: row.sample_size || 0,
      avg_ttft_ms: to_float(row.avg_ttft_ms),
      avg_generation_ms: to_float(row.avg_generation_ms),
      avg_total_latency_ms: to_float(row.avg_total_latency_ms),
      avg_tokens_per_second: to_float(row.avg_tokens_per_second)
    }
  end

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(f) when is_float(f), do: f
  defp to_float(i) when is_integer(i), do: i * 1.0

  defp unwrap_transaction_result({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_transaction_result({:ok, {:error, changeset}}), do: {:error, changeset}
  defp unwrap_transaction_result({:error, :request_not_found}), do: {:error, :request_not_found}
  defp unwrap_transaction_result({:error, :already_terminal}), do: {:error, :already_terminal}

  defp unwrap_transaction_result({:error, {:invalid_scheduler_explanation, reason}}),
    do: {:error, {:invalid_scheduler_explanation, reason}}

  defp unwrap_transaction_result({:error, {:request_event_changeset, changeset}}),
    do: {:error, changeset}

  defp unwrap_transaction_result({:error, {:request_changeset, changeset}}),
    do: {:error, changeset}

  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}
end
