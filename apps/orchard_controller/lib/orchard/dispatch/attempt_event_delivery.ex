defmodule Orchard.Dispatch.AttemptEventDelivery do
  @moduledoc """
  Immutable attempt-local event retention and public delivery coordination.
  """

  alias Orchard.Inference.OutputCommitment
  alias Orchard.InferenceEvent

  @enforce_keys [
    :request_id,
    :event_handler,
    :events_rev,
    :pending_rev,
    :commitment,
    :delivery_state,
    :delivered_event_count,
    :failure_reason
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          request_id: String.t(),
          event_handler: (String.t(), InferenceEvent.t() -> term()) | nil,
          events_rev: [InferenceEvent.t()],
          pending_rev: [InferenceEvent.t()],
          commitment: OutputCommitment.t(),
          delivery_state: :pending | :selected | :discarded | :failed,
          delivered_event_count: non_neg_integer(),
          failure_reason: atom() | nil
        }

  @spec new(String.t(), (String.t(), InferenceEvent.t() -> term()) | nil) :: t()
  def new(request_id, event_handler)
      when is_binary(request_id) and (is_nil(event_handler) or is_function(event_handler, 2)) do
    %__MODULE__{
      request_id: request_id,
      event_handler: event_handler,
      events_rev: [],
      pending_rev: [],
      commitment: OutputCommitment.new(),
      delivery_state: :pending,
      delivered_event_count: 0,
      failure_reason: nil
    }
  end

  @spec record(t(), InferenceEvent.t()) :: t()
  def record(%__MODULE__{delivery_state: :failed} = delivery, %InferenceEvent{} = event),
    do: retain(delivery, event)

  def record(%__MODULE__{delivery_state: :selected} = delivery, %InferenceEvent{} = event) do
    delivery
    |> observe_and_retain(event)
    |> deliver_event(event)
  end

  def record(%__MODULE__{delivery_state: :pending} = delivery, %InferenceEvent{} = event) do
    updated =
      delivery
      |> observe_and_retain(event)
      |> Map.update!(:pending_rev, &[event | &1])

    if OutputCommitment.committed?(updated.commitment),
      do: deliver_pending(updated),
      else: updated
  end

  def record(%__MODULE__{} = delivery, %InferenceEvent{} = event),
    do: observe_and_retain(delivery, event)

  @spec select(t()) :: t()
  def select(%__MODULE__{delivery_state: :pending} = delivery), do: deliver_pending(delivery)
  def select(%__MODULE__{} = delivery), do: delivery

  @spec discard(t()) :: {:ok, t()} | {:error, :output_committed | :already_selected}
  def discard(%__MODULE__{} = delivery) do
    cond do
      output_committed?(delivery) ->
        {:error, :output_committed}

      delivery.delivery_state == :pending ->
        {:ok, %{delivery | delivery_state: :discarded, pending_rev: []}}

      true ->
        {:error, :already_selected}
    end
  end

  @spec events(t()) :: [InferenceEvent.t()]
  def events(%__MODULE__{events_rev: events_rev}), do: Enum.reverse(events_rev)

  @spec output_committed?(t()) :: boolean()
  def output_committed?(%__MODULE__{commitment: commitment}),
    do: OutputCommitment.committed?(commitment)

  @spec commitment_kind(t()) :: OutputCommitment.kind() | nil
  def commitment_kind(%__MODULE__{commitment: commitment}), do: OutputCommitment.kind(commitment)

  @spec delivery_state(t()) :: :pending | :selected | :discarded | :failed
  def delivery_state(%__MODULE__{delivery_state: delivery_state}), do: delivery_state

  @spec delivered_event_count(t()) :: non_neg_integer()
  def delivered_event_count(%__MODULE__{delivered_event_count: count}), do: count

  @spec failure_reason(t()) :: :cancel | :serializer_failed | :event_handler_failed | nil
  def failure_reason(%__MODULE__{failure_reason: failure_reason}), do: failure_reason

  defp observe_and_retain(delivery, event) do
    %{
      delivery
      | events_rev: [event | delivery.events_rev],
        commitment: OutputCommitment.observe(delivery.commitment, event)
    }
  end

  defp retain(delivery, event), do: %{delivery | events_rev: [event | delivery.events_rev]}

  defp deliver_pending(delivery) do
    delivery.pending_rev
    |> Enum.reverse()
    |> Enum.reduce_while(%{delivery | delivery_state: :selected, pending_rev: []}, fn event,
                                                                                      state ->
      case deliver_event(state, event) do
        %__MODULE__{delivery_state: :failed} = failed -> {:halt, failed}
        %__MODULE__{} = delivered -> {:cont, delivered}
      end
    end)
  end

  defp deliver_event(delivery, event) do
    case invoke_handler(delivery.event_handler, delivery.request_id, event) do
      :ok ->
        %{delivery | delivered_event_count: delivery.delivered_event_count + 1}

      failure_reason ->
        %{delivery | delivery_state: :failed, failure_reason: failure_reason}
    end
  end

  defp invoke_handler(nil, _request_id, _event), do: :ok

  defp invoke_handler(handler, request_id, event) do
    case handler.(request_id, event) do
      :ok -> :ok
      :cancel -> :cancel
      {:error, :serializer_failed} -> :serializer_failed
      _invalid -> :event_handler_failed
    end
  rescue
    _error -> :event_handler_failed
  catch
    _kind, _reason -> :event_handler_failed
  end
end
