defmodule Orchard.Node.SentryTelemetryBridge do
  @moduledoc """
  Whitelist-only node telemetry to Sentry breadcrumb bridge.

  Telemetry handlers run in the process that emits the event. Most node telemetry
  comes from long-lived workers or managers, so runtime breadcrumb attachment is
  request-context gated to avoid carrying stale breadcrumbs into unrelated
  crashes. The mapping function remains deterministic and testable for the
  whitelisted event surface.
  """

  require Logger

  alias Orchard.SentryContext

  @handler_id "orchard-node-sentry-telemetry-bridge"
  @redacted "[redacted]"
  @max_identifier_chars 96

  @events [
    [:orchard, :node, :model_manager, :load, :start],
    [:orchard, :node, :model_manager, :load, :stop],
    [:orchard, :node, :model_manager, :load, :exception],
    [:orchard, :node, :eviction, :start],
    [:orchard, :node, :eviction, :stop],
    [:orchard, :node, :eviction, :exception],
    [:orchard, :node, :model_acquisition, :start],
    [:orchard, :node, :model_acquisition, :stop],
    [:orchard, :node, :model_acquisition, :exception],
    [:orchard, :node, :worker_runtime, :load, :start],
    [:orchard, :node, :worker_runtime, :load, :stop],
    [:orchard, :node, :worker_runtime, :load, :exception],
    [:orchard, :node, :worker_runtime, :unload, :start],
    [:orchard, :node, :worker_runtime, :unload, :stop],
    [:orchard, :node, :worker_runtime, :unload, :exception]
  ]

  @safe_metadata_keys [
    :model_id,
    :version,
    :backend,
    :adapter,
    :outcome,
    :source_scheme,
    :preload,
    :worker_started,
    :waiter_count,
    :replied_waiter_count,
    :incoming_model_id,
    :incoming_version,
    :victim_model_id,
    :victim_version,
    :max_loaded_models,
    :reserved_model_count_before,
    :cancel_reason,
    :rpc_result,
    :stop_result,
    :skip_rpc
  ]

  @identifier_keys MapSet.new([
                     :model_id,
                     :version,
                     :incoming_model_id,
                     :incoming_version,
                     :victim_model_id,
                     :victim_version
                   ])
  @result_keys MapSet.new([:rpc_result, :stop_result])

  @known_reasons MapSet.new([
                   :capacity_exhausted,
                   :deadline_exceeded,
                   :leader_deadline_exceeded,
                   :model_capacity_exhausted,
                   :worker_unavailable
                 ])
  @known_reason_strings MapSet.new(Enum.map(@known_reasons, &Atom.to_string/1))
  @known_cancel_reasons MapSet.new([
                          :leader_deadline_exceeded,
                          :reset,
                          :runtime_worker_exited,
                          :runtime_worker_unavailable,
                          :unload_request
                        ])
  @known_cancel_reason_strings MapSet.new(Enum.map(@known_cancel_reasons, &Atom.to_string/1))

  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok ->
        :ok

      {:error, :already_exists} ->
        :ok
    end
  end

  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event(event_name, measurements, metadata, _config) do
    if SentryContext.node_agent_enabled?() and SentryContext.telemetry_breadcrumbs_enabled?() do
      case breadcrumb_for_event(event_name, measurements, metadata) do
        {:ok, breadcrumb} -> maybe_add_breadcrumb(breadcrumb)
        :ignore -> :ok
      end
    end
  rescue
    exception ->
      Logger.warning("Sentry telemetry bridge ignored event after error: #{inspect(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("Sentry telemetry bridge ignored event after #{kind}: #{inspect(reason)}")
      :ok
  end

  @spec breadcrumb_for_event([atom()], map(), map()) :: {:ok, keyword()} | :ignore
  def breadcrumb_for_event(event_name, measurements, metadata) when event_name in @events do
    action = List.last(event_name)

    {:ok,
     [
       category: category(event_name),
       message: message(event_name),
       level: level(action, metadata),
       data: breadcrumb_data(measurements, metadata)
     ]}
  end

  def breadcrumb_for_event(_event_name, _measurements, _metadata), do: :ignore

  defp category([:orchard, :node, :model_manager, :load, _action]),
    do: "orchard.node.model_manager.load"

  defp category([:orchard, :node, :eviction, _action]), do: "orchard.node.eviction"

  defp category([:orchard, :node, :model_acquisition, _action]),
    do: "orchard.node.model_acquisition"

  defp category([:orchard, :node, :worker_runtime, :load, _action]),
    do: "orchard.node.worker_runtime.load"

  defp category([:orchard, :node, :worker_runtime, :unload, _action]),
    do: "orchard.node.worker_runtime.unload"

  defp message(event_name) do
    event_name
    |> Enum.drop(2)
    |> Enum.map_join(".", &Atom.to_string/1)
  end

  defp level(:exception, metadata) do
    case sanitized_reason(Map.get(metadata, :reason)) do
      reason
      when reason in ["capacity_exhausted", "model_capacity_exhausted", "deadline_exceeded"] ->
        :warning

      "worker_unavailable" ->
        :warning

      _other ->
        :error
    end
  end

  defp level(_action, _metadata), do: :info

  defp breadcrumb_data(measurements, metadata) do
    measurements
    |> Map.take([:duration_ms])
    |> Map.merge(Map.take(metadata, @safe_metadata_keys))
    |> maybe_put_reason(metadata)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {breadcrumb_key(key), normalize_value(key, value)} end)
  end

  defp breadcrumb_key(:version), do: :model_version
  defp breadcrumb_key(key), do: key

  defp maybe_add_breadcrumb(breadcrumb) do
    if SentryContext.breadcrumb_context_present?() do
      SentryContext.add_breadcrumb(breadcrumb)
    else
      :ok
    end
  end

  defp maybe_put_reason(data, metadata) do
    case sanitized_reason(Map.get(metadata, :reason)) do
      nil -> data
      reason -> Map.put(data, :reason, reason)
    end
  end

  defp sanitized_reason(nil), do: nil

  defp sanitized_reason(reason) when is_atom(reason) do
    if MapSet.member?(@known_reasons, reason) do
      Atom.to_string(reason)
    else
      "unexpected_error"
    end
  end

  defp sanitized_reason(reason) when is_binary(reason) do
    reason
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> then(fn value ->
      if value != "" and MapSet.member?(@known_reason_strings, value) do
        value
      else
        "unexpected_error"
      end
    end)
  end

  defp sanitized_reason(_reason), do: "unexpected_error"

  defp normalize_value(key, value) do
    cond do
      MapSet.member?(@result_keys, key) ->
        normalize_result(value)

      key == :cancel_reason ->
        normalize_cancel_reason(value)

      MapSet.member?(@identifier_keys, key) ->
        value
        |> normalize_primitive()
        |> truncate_identifier()

      true ->
        normalize_primitive(value)
    end
  end

  defp normalize_result(:ok), do: "ok"
  defp normalize_result(:skipped), do: "skipped"
  defp normalize_result({:error, _reason}), do: "error"

  defp normalize_result(value) when is_binary(value),
    do: normalize_string_enum(value, ["ok", "skipped"])

  defp normalize_result(_value), do: @redacted

  defp normalize_cancel_reason(nil), do: nil

  defp normalize_cancel_reason(reason) when is_atom(reason) do
    if MapSet.member?(@known_cancel_reasons, reason) do
      Atom.to_string(reason)
    else
      "unexpected_cancel"
    end
  end

  defp normalize_cancel_reason(reason) when is_binary(reason),
    do:
      normalize_string_enum(
        reason,
        MapSet.to_list(@known_cancel_reason_strings),
        "unexpected_cancel"
      )

  defp normalize_cancel_reason(_reason), do: "unexpected_cancel"

  defp normalize_string_enum(value, allowed, fallback \\ @redacted) do
    normalized =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")

    if normalized in allowed, do: normalized, else: fallback
  end

  defp normalize_primitive(value)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: value

  defp normalize_primitive(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_primitive(_value), do: @redacted

  defp truncate_identifier(value) when is_binary(value) do
    case SentryContext.hash_id(value) do
      nil ->
        if String.length(value) > @max_identifier_chars do
          String.slice(value, 0, @max_identifier_chars) <> "..."
        else
          value
        end

      hashed ->
        hashed
    end
  end

  defp truncate_identifier(value), do: value
end
