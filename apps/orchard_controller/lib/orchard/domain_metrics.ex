defmodule Orchard.DomainMetrics do
  @moduledoc false

  alias Orchard.Metrics.SeriesAdmission

  @scheduler_results [:no_active_nodes, :cluster_busy, :model_busy]
  @scheduler_rejections [
    :no_active_nodes,
    :cluster_busy,
    :model_busy,
    :queue_full,
    :queue_timeout,
    :request_caller_disconnect,
    :internal
  ]

  @spec input_accounted(String.t(), String.t(), non_neg_integer()) :: :ok
  def input_accounted(tenant_id, model_id, tokens) do
    emit(:input_tokens, tokens, %{tenant: tenant_id, model: model_id})
  end

  @spec inference_terminal(atom(), String.t(), String.t(), atom(), number(), non_neg_integer()) ::
          :ok
  def inference_terminal(endpoint, tenant_id, model_id, status, duration_seconds, output_tokens) do
    emit(:inference_requests, 1, %{
      endpoint: endpoint,
      tenant: tenant_id,
      model: model_id,
      status: status
    })

    emit(:inference_request_duration, duration_seconds, %{
      tenant: tenant_id,
      model: model_id,
      status: status
    })

    emit(:output_tokens, output_tokens, %{tenant: tenant_id, model: model_id})
  end

  @spec scheduler_decision(term(), number()) :: :ok
  def scheduler_decision(result, duration_seconds) do
    emit(:scheduler_duration, duration_seconds, %{})

    case scheduler_labels(result) do
      {:ok, labels} ->
        emit(:scheduler_decisions, 1, labels)

      :error ->
        :ok
    end
  end

  @spec scheduler_rejection(atom()) :: :ok
  def scheduler_rejection(reason) when reason in @scheduler_rejections do
    emit(:scheduler_rejections, 1, %{reason: reason})
  end

  def scheduler_rejection(_reason), do: :ok

  @spec worker_crashes(String.t(), String.t(), pos_integer()) :: :ok
  def worker_crashes(node_id, model_id, count)
      when is_binary(node_id) and node_id != "" and is_binary(model_id) and model_id != "" and
             is_integer(count) and count > 0 do
    emit(:worker_crashes, count, %{node: node_id, model: model_id})
  end

  def worker_crashes(_node_id, _model_id, _count), do: :ok

  @spec quota_rejection(String.t(), atom()) :: :ok
  def quota_rejection(tenant_id, reason) do
    emit(:quota_rejections, 1, %{tenant: tenant_id, reason: reason})
  end

  @spec model_load(String.t() | nil, String.t(), non_neg_integer()) :: :ok
  def model_load(node_id, model_id, duration_ms)
      when is_binary(node_id) and node_id != "" and is_integer(duration_ms) and duration_ms >= 0 do
    emit(:model_load_duration, duration_ms / 1_000, %{node: node_id, model: model_id})
  end

  def model_load(_node_id, _model_id, _duration_ms), do: :ok

  @spec decode_throughput(String.t() | nil, String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok
  def decode_throughput(node_id, model_id, output_tokens, duration_ms)
      when is_binary(node_id) and node_id != "" and is_integer(output_tokens) and
             output_tokens > 0 and is_integer(duration_ms) and duration_ms > 0 do
    emit(:decode_tokens_per_second, output_tokens * 1_000 / duration_ms, %{
      node: node_id,
      model: model_id
    })
  end

  def decode_throughput(_node_id, _model_id, _output_tokens, _duration_ms), do: :ok

  defp scheduler_labels({:ok, schedule}) when is_map(schedule) do
    tier = Map.get(schedule, :selected_tier) || Map.get(schedule, :selection_tier)

    if tier in [:loaded, :cached, :cold, "loaded", "cached", "cold"] do
      {:ok, %{result: :selected, tier: tier}}
    else
      :error
    end
  end

  defp scheduler_labels({:error, result, _decision}) when result in @scheduler_results,
    do: {:ok, %{result: result, tier: :none}}

  defp scheduler_labels({:error, result}) when result in @scheduler_results,
    do: {:ok, %{result: result, tier: :none}}

  defp scheduler_labels(_result), do: :error

  defp emit(family, value, labels) do
    _result = SeriesAdmission.emit(family, value, labels)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
