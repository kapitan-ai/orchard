defmodule Orchard.Tokenizer.TelemetryCounters do
  @moduledoc """
  Process-local safe-tokenization telemetry counters for Console diagnostics.
  """

  use GenServer

  @handler_id "orchard-tokenizer-telemetry-counters"

  @events %{
    control_token_in_user_content: [:orchard, :tokenizer, :control_token_in_user_content],
    detector_error: [:orchard, :tokenizer, :detector_error],
    prompt_token_ids_dispatched: [:orchard, :tokenizer, :prompt_token_ids_dispatched],
    unsafe_mode_active: [:orchard, :tokenizer, :unsafe_mode_active],
    parity_drift: [:orchard, :tokenizer, :parity_drift],
    catalog_drift: [:orchard, :tokenizer, :catalog_drift],
    degraded_no_manifest_catalog: [
      :orchard,
      :tokenizer,
      :safe_tokenization,
      :degraded_no_manifest_catalog
    ]
  }

  @event_keys Map.new(@events, fn {key, event_name} -> {event_name, key} end)

  @type counter :: %{
          required(:count) => non_neg_integer(),
          required(:last_seen_at) => DateTime.t() | nil
        }
  @type prompt_counter :: %{
          required(:count) => non_neg_integer(),
          required(:token_count) => non_neg_integer(),
          required(:last_seen_at) => DateTime.t() | nil
        }
  @type snapshot :: %{
          required(:started_at) => DateTime.t(),
          required(:control_token_in_user_content) => counter(),
          required(:detector_error) => counter(),
          required(:prompt_token_ids_dispatched) => prompt_counter(),
          required(:unsafe_mode_active) => counter(),
          required(:parity_drift) => counter(),
          required(:catalog_drift) => counter(),
          required(:degraded_no_manifest_catalog) => counter()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec snapshot() :: snapshot()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc """
  Resets process-local counters for deterministic tests.

  The counter process start timestamp is preserved. This is not exposed through the
  Console, HTTP APIs, or operator controls.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc false
  @spec handle_telemetry_event(list(atom()), map(), map(), term()) :: :ok
  def handle_telemetry_event(event_name, measurements, _metadata, _config) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:telemetry_event, event_name, measurements})
      nil -> :ok
    end
  end

  @impl true
  def init(:ok) do
    detach_handler()

    :ok =
      :telemetry.attach_many(
        @handler_id,
        Map.values(@events),
        &__MODULE__.handle_telemetry_event/4,
        nil
      )

    {:ok,
     %{
       started_at: timestamp(),
       counters: zero_counters()
     }}
  end

  @impl true
  def terminate(_reason, _state) do
    detach_handler()
    :ok
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.put(state.counters, :started_at, state.started_at), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | counters: zero_counters()}}
  end

  @impl true
  def handle_cast({:telemetry_event, event_name, measurements}, state) do
    case Map.fetch(@event_keys, event_name) do
      {:ok, key} -> {:noreply, update_counter(state, key, measurements)}
      :error -> {:noreply, state}
    end
  end

  defp update_counter(state, key, measurements) do
    now = timestamp()
    count = normalized_count(measurements)

    counters =
      Map.update!(state.counters, key, &increment_counter(&1, count, key, measurements, now))

    %{state | counters: counters}
  end

  defp increment_counter(counter, count, :prompt_token_ids_dispatched, measurements, now) do
    counter
    |> Map.update!(:count, &(&1 + count))
    |> Map.update!(:token_count, &(&1 + normalized_token_count(measurements)))
    |> Map.put(:last_seen_at, now)
  end

  defp increment_counter(counter, count, _key, _measurements, now) do
    counter
    |> Map.update!(:count, &(&1 + count))
    |> Map.put(:last_seen_at, now)
  end

  defp normalized_count(measurements) when is_map(measurements) do
    case Map.get(measurements, :count) do
      count when is_integer(count) and count > 0 -> count
      _other -> 1
    end
  end

  defp normalized_count(_measurements), do: 1

  defp normalized_token_count(measurements) when is_map(measurements) do
    case Map.get(measurements, :token_count) do
      count when is_integer(count) and count >= 0 -> count
      _other -> 0
    end
  end

  defp normalized_token_count(_measurements), do: 0

  defp zero_counters do
    %{
      control_token_in_user_content: zero_counter(),
      detector_error: zero_counter(),
      prompt_token_ids_dispatched: Map.put(zero_counter(), :token_count, 0),
      unsafe_mode_active: zero_counter(),
      parity_drift: zero_counter(),
      catalog_drift: zero_counter(),
      degraded_no_manifest_catalog: zero_counter()
    }
  end

  defp zero_counter do
    %{count: 0, last_seen_at: nil}
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp detach_handler do
    :telemetry.detach(@handler_id)
    :ok
  end
end
