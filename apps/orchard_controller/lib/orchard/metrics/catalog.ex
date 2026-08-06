defmodule Orchard.Metrics.Catalog do
  @moduledoc """
  Compile-time Controller metrics catalog required by SPEC.md §9.1.
  """

  import Telemetry.Metrics

  @http_buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
  @request_buckets [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120]
  @decode_buckets [1, 2, 5, 10, 20, 40, 80, 120]
  @scheduler_buckets [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.15, 0.25, 0.5, 1]

  @descriptors [
    %{
      family: :http_requests,
      name: "orchard_http_requests_total",
      type: :counter,
      labels: [:endpoint, :method, :status],
      ceiling: 280
    },
    %{
      family: :http_request_duration,
      name: "orchard_http_request_duration_seconds",
      type: :histogram,
      labels: [:endpoint, :status],
      ceiling: 40,
      buckets: @http_buckets
    },
    %{
      family: :inference_requests,
      name: "orchard_inference_requests_total",
      type: :counter,
      labels: [:endpoint, :tenant, :model, :status],
      ceiling: 160
    },
    %{
      family: :inference_request_duration,
      name: "orchard_inference_request_duration_seconds",
      type: :histogram,
      labels: [:tenant, :model, :status],
      ceiling: 80,
      buckets: @request_buckets
    },
    %{
      family: :input_tokens,
      name: "orchard_input_tokens_total",
      type: :counter,
      labels: [:tenant, :model],
      ceiling: 16
    },
    %{
      family: :output_tokens,
      name: "orchard_output_tokens_total",
      type: :counter,
      labels: [:tenant, :model],
      ceiling: 16
    },
    %{
      family: :decode_tokens_per_second,
      name: "orchard_decode_tokens_per_second",
      type: :histogram,
      labels: [:model, :node],
      ceiling: 16,
      buckets: @decode_buckets
    },
    %{
      family: :scheduler_decisions,
      name: "orchard_scheduler_decisions_total",
      type: :counter,
      labels: [:result, :tier],
      ceiling: 6
    },
    %{
      family: :scheduler_duration,
      name: "orchard_scheduler_duration_seconds",
      type: :histogram,
      labels: [],
      ceiling: 1,
      buckets: @scheduler_buckets
    },
    %{
      family: :scheduler_queue_depth,
      name: "orchard_scheduler_queue_depth",
      type: :gauge,
      labels: [:tenant],
      ceiling: 4
    },
    %{
      family: :scheduler_rejections,
      name: "orchard_scheduler_rejections_total",
      type: :counter,
      labels: [:reason],
      ceiling: 7
    },
    %{
      family: :node_heartbeat_lag,
      name: "orchard_node_heartbeat_lag_seconds",
      type: :gauge,
      labels: [:node],
      ceiling: 4
    },
    %{
      family: :node_available_memory,
      name: "orchard_node_available_memory_bytes",
      type: :gauge,
      labels: [:node],
      ceiling: 4
    },
    %{
      family: :node_swap_used,
      name: "orchard_node_swap_used_bytes",
      type: :gauge,
      labels: [:node],
      ceiling: 4
    },
    %{
      family: :active_requests,
      name: "orchard_active_requests",
      type: :gauge,
      labels: [:node, :model],
      ceiling: 16
    },
    %{
      family: :model_load_duration,
      name: "orchard_model_load_duration_seconds",
      type: :histogram,
      labels: [:node, :model],
      ceiling: 16,
      buckets: @request_buckets
    },
    %{
      family: :model_resident,
      name: "orchard_model_resident",
      type: :gauge,
      labels: [:node, :model],
      ceiling: 16
    },
    %{
      family: :worker_crashes,
      name: "orchard_worker_crashes_total",
      type: :counter,
      labels: [:node, :model],
      ceiling: 16
    },
    %{
      family: :quota_rejections,
      name: "orchard_quota_rejections_total",
      type: :counter,
      labels: [:tenant, :reason],
      ceiling: 16
    },
    %{
      family: :api_key_auth_failures,
      name: "orchard_api_key_auth_failures_total",
      type: :counter,
      labels: [],
      ceiling: 1
    },
    %{
      family: :audit_events,
      name: "orchard_audit_events_total",
      type: :counter,
      labels: [:action, :outcome],
      ceiling: 24
    }
  ]

  @worksheet_total 2_588
  @series_ceiling 5_000

  @spec descriptors() :: [map()]
  def descriptors, do: @descriptors

  @spec descriptor(atom()) :: {:ok, map()} | :error
  def descriptor(family) do
    case Enum.find(@descriptors, &(&1.family == family)) do
      nil -> :error
      descriptor -> {:ok, descriptor}
    end
  end

  @spec worksheet_total() :: 2_588
  def worksheet_total, do: @worksheet_total

  @spec series_ceiling() :: 5_000
  def series_ceiling, do: @series_ceiling

  @spec reporter_metrics() :: [Telemetry.Metrics.t()]
  def reporter_metrics do
    @descriptors
    |> Enum.reject(&(&1.type == :gauge))
    |> Enum.map(&reporter_metric/1)
  end

  defp reporter_metric(%{family: family} = descriptor)
       when family in [:input_tokens, :output_tokens, :worker_crashes] do
    sum(descriptor.name,
      event_name: event_name(descriptor.family),
      measurement: :value,
      tags: descriptor.labels
    )
  end

  defp reporter_metric(%{type: :counter} = descriptor) do
    counter(descriptor.name,
      event_name: event_name(descriptor.family),
      measurement: :value,
      tags: descriptor.labels
    )
  end

  defp reporter_metric(%{type: :histogram} = descriptor) do
    distribution(descriptor.name,
      event_name: event_name(descriptor.family),
      measurement: :value,
      tags: descriptor.labels,
      reporter_options: [buckets: descriptor.buckets]
    )
  end

  @spec event_name(atom()) :: [atom()]
  def event_name(family), do: [:orchard, :metrics, family]
end
