defmodule Orchard.DomainMetricsTest do
  use ExUnit.Case, async: false

  alias Orchard.DomainMetrics
  alias Orchard.Metrics.Catalog

  setup do
    restart_metrics_generation()
    handler_id = "domain-metrics-#{System.unique_integer([:positive])}"

    events =
      [
        :inference_requests,
        :inference_request_duration,
        :input_tokens,
        :output_tokens,
        :decode_tokens_per_second,
        :scheduler_decisions,
        :scheduler_duration,
        :scheduler_rejections,
        :model_load_duration,
        :quota_rejections
      ]
      |> Enum.map(&Catalog.event_name/1)

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:metric, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "SPEC.md §9.1 completed logical request and tokens emit once across attempt timing" do
    DomainMetrics.input_accounted("tenant-1", "model-1", 12)
    DomainMetrics.model_load("node-1", "model-1", 200)
    DomainMetrics.model_load("node-2", "model-1", 300)

    DomainMetrics.inference_terminal(
      :chat_completions,
      "tenant-1",
      "model-1",
      :completed,
      1.25,
      7
    )

    assert_metric(:input_tokens, 12, %{tenant: "tenant-1", model: "model-1"})

    assert_metric(:inference_requests, 1, %{
      endpoint: "chat_completions",
      tenant: "tenant-1",
      model: "model-1",
      status: "completed"
    })

    assert_metric(:inference_request_duration, 1.25, %{
      tenant: "tenant-1",
      model: "model-1",
      status: "completed"
    })

    assert_metric(:output_tokens, 7, %{tenant: "tenant-1", model: "model-1"})
    refute_receive {:metric, [:orchard, :metrics, :inference_requests], _, _}
    refute_receive {:metric, [:orchard, :metrics, :input_tokens], _, _}
    refute_receive {:metric, [:orchard, :metrics, :output_tokens], _, _}
  end

  test "SPEC.md §9.1 failed logical request uses bounded terminal labels and histogram observation" do
    DomainMetrics.inference_terminal(:responses, "tenant-1", "model-1", :failed, 0.5, 0)

    assert_metric(:inference_requests, 1, %{
      endpoint: "responses",
      tenant: "tenant-1",
      model: "model-1",
      status: "failed"
    })

    assert_metric(:inference_request_duration, 0.5, %{
      tenant: "tenant-1",
      model: "model-1",
      status: "failed"
    })

    assert_metric(:output_tokens, 0, %{tenant: "tenant-1", model: "model-1"})
  end

  test "SPEC.md §9.1 scheduler decisions, duration, and rejection labels are exact" do
    DomainMetrics.scheduler_decision({:ok, %{selected_tier: :cached}}, 0.012)

    assert_metric(:scheduler_duration, 0.012, %{})
    assert_metric(:scheduler_decisions, 1, %{result: "selected", tier: "cached"})
    refute_receive {:metric, [:orchard, :metrics, :scheduler_rejections], _, _}

    DomainMetrics.scheduler_decision({:error, :cluster_busy}, 0.025)

    assert_metric(:scheduler_duration, 0.025, %{})
    assert_metric(:scheduler_decisions, 1, %{result: "cluster_busy", tier: "none"})
    refute_receive {:metric, [:orchard, :metrics, :scheduler_rejections], _, _}

    DomainMetrics.scheduler_rejection(:cluster_busy)
    assert_metric(:scheduler_rejections, 1, %{reason: "cluster_busy"})
  end

  test "SPEC.md §9.1 implemented tenant concurrency rejection is bounded" do
    DomainMetrics.scheduler_rejection(:queue_timeout)
    DomainMetrics.quota_rejection("tenant-1", :tenant_concurrency)

    assert_metric(:scheduler_rejections, 1, %{reason: "queue_timeout"})

    assert_metric(:quota_rejections, 1, %{
      tenant: "tenant-1",
      reason: "tenant_concurrency"
    })
  end

  test "SPEC.md §9.1 finalized dispatcher timings emit only defensible observations" do
    DomainMetrics.model_load("node-1", "model-1", 250)
    DomainMetrics.decode_throughput("node-1", "model-1", 20, 500)
    DomainMetrics.decode_throughput(nil, "model-1", 20, 500)
    DomainMetrics.decode_throughput("node-1", "model-1", 0, 500)

    assert_metric(:model_load_duration, 0.25, %{node: "node-1", model: "model-1"})
    assert_metric(:decode_tokens_per_second, 40.0, %{node: "node-1", model: "model-1"})
    refute_receive {:metric, [:orchard, :metrics, :decode_tokens_per_second], _, _}
  end

  defp assert_metric(family, value, labels) do
    assert_receive {:metric, [:orchard, :metrics, ^family], %{value: ^value}, ^labels}
  end

  defp restart_metrics_generation do
    case Process.whereis(Orchard.Metrics.Supervisor) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end

    start_supervised!(Orchard.Metrics.Supervisor)
  end
end
