defmodule Orchard.Node.TensorFoldPreparationTest do
  use ExUnit.Case, async: false

  alias Orchard.Cluster.V1.{ExecuteInferenceRequest, ModelRef}
  alias Orchard.Node.{ModelManager, RuntimeServer, WorkerProcess}

  defmodule BindingAdapter do
    def prepare_request(%{observer: observer}, request, []) do
      send(observer, {:prepared, request})

      case request.tensorfold_history_projection_json do
        "reject" -> {:error, :tensorfold_projection_rejected}
        _ -> {:ok, %{request | tensorfold_history_projection_json: "bound-incarnation"}}
      end
    end

    def get_status(_state, _opts), do: {:ok, %{ready: true, max_concurrency: 1}}

    def start_generation(state, request, _opts) do
      send(state.observer, {:started, request})
      {:ok, make_ref(), state}
    end

    def unload_model(_state, _opts), do: :ok
  end

  setup do
    old = Application.get_env(:orchard_node_agent, :tensorfold_experiment_profile)

    Application.put_env(:orchard_node_agent, :tensorfold_experiment_profile, %{
      "model_id" => "qwen",
      "version" => "v1"
    })

    on_exit(fn ->
      Application.put_env(:orchard_node_agent, :tensorfold_experiment_profile, old)
    end)

    worker =
      start_supervised!(
        {WorkerProcess, model_ref: %ModelRef{model_id: "qwen", version: "v1"}, manager: self()}
      )

    observer = self()

    :sys.replace_state(worker, fn state ->
      %{state | loaded?: true, adapter: BindingAdapter, adapter_state: %{observer: observer}}
    end)

    state = %{
      active_requests: %{},
      subscriber_refs: %{},
      workers: %{
        {"qwen", "v1"} => %{
          pid: worker,
          placement_state: :PLACEMENT_STATE_LOADED,
          request_limit: 1
        }
      }
    }

    request = %ExecuteInferenceRequest{
      request_id: "resp_test",
      model_id: "qwen",
      version: "v1",
      tensorfold_history_projection_json: "unbound"
    }

    %{state: state, request: request, worker: worker}
  end

  test "SPEC preparation retains bound bytes until start and preserves capacity ownership", ctx do
    assert {:reply, :ok, prepared} =
             ModelManager.handle_call({:prepare_request, ctx.request, self()}, nil, ctx.state)

    assert_receive {:prepared, original}
    assert original == ctx.request
    assert prepared.active_requests[ctx.request.request_id].phase == :prepared

    assert {:reply, {:error, :model_busy}, ^prepared} =
             ModelManager.handle_call(
               {:prepare_request, %{ctx.request | request_id: "other"}, self()},
               nil,
               prepared
             )

    assert {:reply, :ok, running} =
             ModelManager.handle_call({:start_request, ctx.request}, nil, prepared)

    assert_receive {:started, bound}
    assert bound.tensorfold_history_projection_json == "bound-incarnation"
    assert bound.request_id == ctx.request.request_id
    assert running.active_requests[ctx.request.request_id].phase == :running
  end

  test "rejected preparation and cancelled prepared slot leave no subscriber or capacity claim",
       ctx do
    bad = %{ctx.request | tensorfold_history_projection_json: "reject"}

    assert {:reply, {:error, :tensorfold_projection_rejected}, state} =
             ModelManager.handle_call({:prepare_request, bad, self()}, nil, ctx.state)

    assert state.active_requests == %{}
    assert state.subscriber_refs == %{}

    assert {:reply, :ok, prepared} =
             ModelManager.handle_call({:prepare_request, ctx.request, self()}, nil, state)

    assert {:reply, %{ok: true}, cancelled} =
             ModelManager.handle_call(
               {:cancel_request, ctx.request.request_id, ""},
               nil,
               prepared
             )

    assert cancelled.active_requests == %{}
    assert cancelled.subscriber_refs == %{}
    refute_receive {:started, _}
  end

  test "redemption cannot mutate the originally prepared request and releases its slot", ctx do
    assert {:reply, :ok, prepared} =
             ModelManager.handle_call({:prepare_request, ctx.request, self()}, nil, ctx.state)

    altered = %{ctx.request | rendered_prompt_utf8: "changed"}

    assert {:reply, {:error, :request_not_prepared}, state} =
             ModelManager.handle_call({:start_request, altered}, nil, prepared)

    assert state.active_requests == %{}
    assert state.subscriber_refs == %{}
    refute_receive {:started, _}
  end

  test "default off rejects internal projection and selected route refuses absent projection",
       ctx do
    assert RuntimeServer.safe_failure_reason_code(:tensorfold_projection_rejected) ==
             "tensorfold_projection_rejected"

    assert {:error, :tensorfold_projection_rejected} =
             WorkerProcess.prepare_request(ctx.worker, %{
               ctx.request
               | tensorfold_history_projection_json: ""
             })

    Application.delete_env(:orchard_node_agent, :tensorfold_experiment_profile)

    assert {:error, :tensorfold_projection_rejected} =
             WorkerProcess.prepare_request(ctx.worker, ctx.request)

    baseline = %{ctx.request | tensorfold_history_projection_json: ""}
    assert {:ok, ^baseline} = WorkerProcess.prepare_request(ctx.worker, baseline)
  end
end
