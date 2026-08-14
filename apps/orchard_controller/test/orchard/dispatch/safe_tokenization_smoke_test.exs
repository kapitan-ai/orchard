defmodule Orchard.Dispatch.SafeTokenizationSmokeTest.StubClient do
  @moduledoc false

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    ExecuteInferenceRequest,
    RuntimeNodeMetadata,
    StatusResponse
  }

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.{Operation, PlacementCapacity}
  alias Orchard.TestSupport.DispatchCapacityFixtures

  def connect(target) do
    key = target_key(target)
    send(capture_pid(), {:connect_target, key})
    {:ok, {:stub_channel, target}}
  end

  def status({:stub_channel, target}, _opts \\ []) do
    key = target_key(target)
    send(capture_pid(), {:status_target, key})

    case Process.get({:safe_smoke_status, key}) do
      nil ->
        {:error, :unavailable}

      response ->
        DispatchCapacityFixtures.record_authenticated_probe_evidence(response)
        {:ok, response}
    end
  end

  def disconnect(_channel), do: :ok
  def cancel_inference(_channel, %Operation.CancelRequest{}, _opts \\ []), do: :ok

  def ensure_model_loaded(
        {:stub_channel, target},
        %Operation.EnsureModelLoadedRequest{} = request,
        _opts \\ []
      ) do
    key = target_key(target)

    response =
      Process.get({:safe_smoke_status, key}) ||
        raise "missing safe smoke status for #{inspect(key)}"

    model = %{model_id: request.model_ref.model_id, version: request.model_ref.version}

    placement = %{
      model_ref: model,
      placement_state: :loaded,
      active_request_count: 0,
      max_concurrency: 4
    }

    Process.put(
      {:safe_smoke_status, key},
      %{
        response
        | loaded_models: [model],
          runtime_model_placements: [placement]
      }
    )

    send(capture_pid(), {:captured_ensure_model_loaded_target, key, request})

    {:ok,
     %Operation.EnsureModelLoadedResult{
       already_loaded: false,
       placement_state: :loaded,
       worker_supports_prompt_token_ids: response.supports_prompt_token_ids,
       placement_capacity:
         PlacementCapacity.new(%{
           model_ref: model,
           active_request_count: 0,
           max_concurrency: 4,
           source: :ensure_model_loaded_result
         }),
       placement_capacity_evidence_state: :valid
     }}
  end

  def execute_inference(
        {:stub_channel, target},
        %Operation.ExecuteRequest{} = request,
        opts \\ []
      ) do
    key = target_key(target)
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()

    send(capture_pid(), {:captured_execute_request, key, request})

    spawn(fn ->
      send(owner, {:runtime_endpoint_event, ref, request.request_id, InferenceEvent.accepted(0)})

      send(
        owner,
        {:runtime_endpoint_event, ref, request.request_id,
         InferenceEvent.completed(:finish_reason_stop, nil)}
      )

      send(owner, {:runtime_endpoint_done, ref, :ok})
    end)

    {:ok, ref}
  end

  defp target_key(%Orchard.RuntimeEndpoint.Target{transport: :grpc_compat, address: address}) do
    target_key(address)
  end

  defp target_key(target) do
    {Keyword.fetch!(target, :host), Keyword.fetch!(target, :port)}
  end

  defp capture_pid do
    Process.get(:safe_smoke_capture_pid) || raise "missing safe smoke capture pid"
  end
end

defmodule Orchard.Dispatch.SafeTokenizationSmokeTest do
  @moduledoc """
  Deterministic Phase 4 safe-tokenization acceptance smoke cells.

  Limitations:
  - Mixed-version legacy worker behavior is simulated via deterministic stubs of
    `EnsureModelLoadedResponse.worker_supports_prompt_token_ids` and
    `StatusResponse.supports_prompt_token_ids`. The current native Python worker
    service hard-codes `supports_prompt_token_ids=True` (see
    `native/orchard_worker_mlx/src/orchard_worker_mlx/service.py:436-448`), so
    `ORCHARD_WORKER_BACKEND=stub` is not a legacy worker for this purpose. A true
    cross-binary mixed-version smoke requires an older worker binary or future
    helper change and is out of scope for this slice.
  - Cells are tagged `@tag :safe_tokenization_smoke` so the wrapper script
    `scripts/smoke-safe-tokenization.sh` can target them with
    `--only safe_tokenization_smoke`. Cells also run as part of the standard
    `mix test` suite; do not exclude the tag in test_helper.
  """

  use Orchard.DataCase, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    ExecuteInferenceRequest,
    RuntimeNodeMetadata,
    StatusResponse
  }

  alias Orchard.Dispatch.{AttemptOutcome, RequestDispatcher}
  alias Orchard.DispatchCapacity.Policy
  alias Orchard.ModelManifest
  alias Orchard.ModelManifest.{ChatTemplate, RuntimeRequirements, SafeTokenization, Tokenizer}
  alias Orchard.Nodes.{AdmissionDecision, Node}
  alias Orchard.RuntimeEndpoint.Operation
  alias Orchard.Scheduler.MultiNode
  alias Orchard.TestSupport.DispatchCapacityFixtures
  alias Orchard.Tokenizer.Client

  @moduletag :safe_tokenization_smoke

  @stub_client Orchard.Dispatch.SafeTokenizationSmokeTest.StubClient
  @prompt_ids [101, 102, 103]
  @model_id "test/model"
  @version "v1"
  @catalog_drift_event [:orchard, :tokenizer, :catalog_drift]
  @bundle_sha256 String.duplicate("c", 64)

  defmodule RealDriftDetector do
    @moduledoc false

    defdelegate partial_catalog(tokenizer_path), to: Orchard.Tokenizer.ControlTokenDetector
    def detect(_catalog, _caller_strings), do: []
  end

  setup do
    previous = Application.fetch_env!(:orchard_controller, :inference)
    Process.put(:safe_smoke_capture_pid, self())

    on_exit(fn -> Application.put_env(:orchard_controller, :inference, previous) end)
    :ok
  end

  test "all-capable scheduler dispatch preserves prompt_token_ids without unsafe or drift telemetry" do
    put_inference(tokenizer_safe_mode: :on, tokenizer_safe_mode_prefer_capable: true)

    dispatched_ref = attach_telemetry([:orchard, :tokenizer, :prompt_token_ids_dispatched])
    unsafe_ref = attach_telemetry([:orchard, :tokenizer, :unsafe_mode_active])
    drift_ref = attach_telemetry([:orchard, :tokenizer, :parity_drift])

    id_a = "00000000-0000-0000-0000-000000000001"
    id_b = "00000000-0000-0000-0000-000000000002"
    capable_a = {"10.0.0.1", 50_061}
    capable_b = {"10.0.0.2", 50_062}

    insert_node!(%{id: id_a, advertise_addr: elem(capable_a, 0), rpc_port: elem(capable_a, 1)})
    insert_node!(%{id: id_b, advertise_addr: elem(capable_b, 0), rpc_port: elem(capable_b, 1)})

    stub_status(capable_a, status_response(id_a, capable_a, supports_prompt_token_ids: true))
    stub_status(capable_b, status_response(id_b, capable_b, supports_prompt_token_ids: true))

    request = canonical_request()
    assert {:ok, schedule} = MultiNode.schedule(request, status_client: @stub_client)
    schedule = Map.put(schedule, :timeout_at, DateTime.add(DateTime.utc_now(), 30, :second))
    assert schedule.node_id in [id_a, id_b]
    selected_target = target_key(schedule.runtime_client_target)
    assert selected_target in [capable_a, capable_b]

    execute_request = execute_request(schedule.request_id)
    assert execute_request.request_id == schedule.request_id

    assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
             RequestDispatcher.dispatch(
               schedule,
               execute_request,
               model_load_request(schedule.node_id),
               client_impl: @stub_client
             )

    assert_receive {^dispatched_ref, [:orchard, :tokenizer, :prompt_token_ids_dispatched],
                    %{token_count: 3}, metadata}

    assert metadata.worker_supports_prompt_token_ids == true
    assert metadata.node_id == schedule.node_id

    assert_receive {:captured_execute_request, ^selected_target,
                    %Operation.ExecuteRequest{prompt_token_ids: @prompt_ids}}

    refute_receive {^unsafe_ref, [:orchard, :tokenizer, :unsafe_mode_active], _, _}, 200
    refute_receive {^drift_ref, [:orchard, :tokenizer, :parity_drift], _, _}, 200
  end

  test "mixed-version scheduler preference dispatches to the capable target" do
    put_inference(tokenizer_safe_mode: :on, tokenizer_safe_mode_prefer_capable: true)

    dispatched_ref = attach_telemetry([:orchard, :tokenizer, :prompt_token_ids_dispatched])
    unsafe_ref = attach_telemetry([:orchard, :tokenizer, :unsafe_mode_active])

    id_legacy = "00000000-0000-0000-0000-000000000001"
    id_capable = "00000000-0000-0000-0000-000000000002"
    legacy_target = {"10.0.0.1", 50_061}
    capable_target = {"10.0.0.2", 50_062}

    insert_node!(%{
      id: id_legacy,
      advertise_addr: elem(legacy_target, 0),
      rpc_port: elem(legacy_target, 1)
    })

    insert_node!(%{
      id: id_capable,
      advertise_addr: elem(capable_target, 0),
      rpc_port: elem(capable_target, 1)
    })

    stub_status(
      legacy_target,
      status_response(id_legacy, legacy_target, supports_prompt_token_ids: false)
    )

    stub_status(
      capable_target,
      status_response(id_capable, capable_target, supports_prompt_token_ids: true)
    )

    request = canonical_request()
    assert {:ok, schedule} = MultiNode.schedule(request, status_client: @stub_client)
    schedule = Map.put(schedule, :timeout_at, DateTime.add(DateTime.utc_now(), 30, :second))
    assert schedule.node_id == id_capable
    assert target_key(schedule.runtime_client_target) == capable_target

    execute_request = execute_request(schedule.request_id)
    assert execute_request.request_id == schedule.request_id

    assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
             RequestDispatcher.dispatch(
               schedule,
               execute_request,
               model_load_request(schedule.node_id),
               client_impl: @stub_client
             )

    assert_receive {^dispatched_ref, [:orchard, :tokenizer, :prompt_token_ids_dispatched], _, _}

    assert_receive {:captured_execute_request, ^capable_target,
                    %Operation.ExecuteRequest{prompt_token_ids: @prompt_ids}}

    refute_received {:captured_execute_request, ^legacy_target, %Operation.ExecuteRequest{}}
    refute_receive {^unsafe_ref, [:orchard, :tokenizer, :unsafe_mode_active], _, _}, 200
  end

  test "legacy-only dispatcher authority strips prompt_token_ids and emits unsafe telemetry" do
    put_inference(tokenizer_safe_mode: :on)

    unsafe_ref = attach_telemetry([:orchard, :tokenizer, :unsafe_mode_active])
    legacy_id = "00000000-0000-0000-0000-000000000099"
    legacy_target = {"127.0.0.1", 59_999}

    stub_status(
      legacy_target,
      status_response(legacy_id, legacy_target, supports_prompt_token_ids: false)
    )

    assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
             RequestDispatcher.dispatch(
               single_node_schedule("req-legacy-only", legacy_target),
               execute_request("req-legacy-only"),
               model_load_request(legacy_id),
               client_impl: @stub_client
             )

    assert_receive {^unsafe_ref, [:orchard, :tokenizer, :unsafe_mode_active], %{count: 1},
                    metadata}

    assert metadata.reason == :legacy_worker_no_capability
    assert metadata.worker_supports_prompt_token_ids == false

    assert_receive {:captured_execute_request, ^legacy_target,
                    %Operation.ExecuteRequest{prompt_token_ids: []}}
  end

  test "manifest drift telemetry fires in safe-mode off fixture coverage" do
    put_inference(tokenizer_safe_mode: :off, tokenizer_mode: :port)

    executable = write_response_executable!()

    put_inference(
      tokenizer_safe_mode: :off,
      tokenizer_mode: :port,
      tokenizer_executable: executable
    )

    bundle_root =
      create_bundle_root!(%{
        "added_tokens" => [%{"content" => "<|new_special|>", "special" => true}]
      })

    on_exit(fn ->
      File.rm(executable)
      File.rm_rf!(bundle_root)
    end)

    attach_ref = attach_telemetry(@catalog_drift_event)

    assert {:ok, %{rendered_prompt: "ok", input_token_count: 1}} =
             Client.tokenize(canonical_request(),
               manifest: safe_manifest(),
               bundle_root: bundle_root,
               bundle_sha256: @bundle_sha256,
               control_token_detector: RealDriftDetector
             )

    assert_receive {^attach_ref, @catalog_drift_event, %{count: 1}, metadata}

    assert metadata.added_count == 1
    assert metadata.drift_direction == :added_only
    assert metadata.partial_detection == true
    assert [%{value: "<|new_special|>"}] = metadata.added
  end

  defp canonical_request do
    CanonicalRequest.new(%{
      internal_id: "int_#{System.unique_integer([:positive])}",
      public_id: "pub_#{System.unique_integer([:positive])}",
      endpoint: :chat_completions,
      tenant_id: Ecto.UUID.generate(),
      model_ref: %ModelRef{model_id: @model_id, version: @version},
      rendered_prompt: "shared system prefix\nhello"
    })
  end

  defp execute_request(request_id) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: "safe-tokenization-smoke",
      model_id: @model_id,
      version: @version,
      rendered_prompt_utf8: "hello orchard",
      input_tokens: 3,
      prompt_token_ids: @prompt_ids
    }
  end

  defp model_load_request(node_id) do
    %EnsureModelLoadedRequest{node_id: node_id, model_id: @model_id, version: @version}
  end

  defp single_node_schedule(request_id, {host, port}) do
    DispatchCapacityFixtures.authorize_unmanaged_schedule(%{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: [host: host, port: port],
      request_timeout_ms: 5_000,
      model_load_timeout_ms: 5_000
    })
  end

  defp status_response(node_id, {host, port}, opts) do
    %StatusResponse{
      node_metadata: %RuntimeNodeMetadata{
        node_id: node_id,
        display_name: "safe-smoke-#{node_id}",
        hostname: "safe-smoke.local",
        agent_version: "0.1.0",
        listen_host: host,
        listen_port: port,
        worker_backend: "mlx"
      },
      active_request_count: 0,
      max_concurrency: 4,
      loaded_models: [],
      runtime_model_placements: [],
      supports_prompt_token_ids: Keyword.fetch!(opts, :supports_prompt_token_ids)
    }
  end

  defp insert_node!(overrides) do
    unique = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          hostname: "safe-smoke-#{unique}.local",
          display_name: "safe-smoke-#{unique}",
          advertise_addr: "10.0.0.#{rem(unique, 255)}",
          rpc_port: 9444,
          state: :active,
          health: :healthy,
          capabilities: %{},
          last_heartbeat_at: DateTime.utc_now()
        },
        overrides
      )

    now = DateTime.utc_now()

    node =
      %Node{}
      |> Node.changeset(attrs)
      |> Repo.insert!()

    decision =
      %AdmissionDecision{}
      |> AdmissionDecision.changeset(%{
        node_id: node.id,
        decision: :admitted,
        actor_type: "system",
        actor_id: "safe-tokenization-smoke",
        observed_identity: %{},
        metadata: %{},
        decided_at: now
      })
      |> Repo.insert!()

    %Policy{}
    |> Policy.approved_explicit_changeset(%{
      node_id: node.id,
      admission_decision_id: decision.id,
      controller_dispatch_ceiling: 4,
      approved_by_actor_type: "system",
      approved_by_actor_id: "safe-tokenization-smoke",
      approved_at: now,
      approval_reason: "safe tokenization capacity fixture"
    })
    |> Repo.insert!()

    node
  end

  defp stub_status({host, port} = key, %StatusResponse{} = response) do
    Process.put({:safe_smoke_status, key}, response)
    put_runtime_targets_from_stubbed_statuses()
    {host, port}
  end

  defp put_runtime_targets_from_stubbed_statuses do
    targets =
      Process.get()
      |> Enum.flat_map(fn
        {{:safe_smoke_status, {host, port}}, _response} -> [[host: host, port: port]]
        _entry -> []
      end)
      |> Enum.sort_by(&{Keyword.fetch!(&1, :host), Keyword.fetch!(&1, :port)})

    put_inference(runtime_client_targets: targets)
  end

  defp target_key(%Orchard.RuntimeEndpoint.Target{transport: :grpc_compat, address: address}) do
    target_key(address)
  end

  defp target_key(target) do
    {Keyword.fetch!(target, :host), Keyword.fetch!(target, :port)}
  end

  defp put_inference(overrides) do
    config = Application.fetch_env!(:orchard_controller, :inference)
    Application.put_env(:orchard_controller, :inference, Keyword.merge(config, overrides))
  end

  defp safe_manifest do
    %ModelManifest{unsafe_manifest() | safe_tokenization: safe_tokenization()}
  end

  defp unsafe_manifest do
    ModelManifest.new(%{
      model_id: @model_id,
      version: @version,
      format: "mlx",
      artifact_layout: "directory",
      entrypoint: "weights/",
      sha256: String.duplicate("a", 64),
      max_context_tokens: 32_768,
      capabilities: ["chat"],
      tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "tokenizer.json"},
      chat_template: %ChatTemplate{path: "chat_template.jinja", sha256: String.duplicate("b", 64)},
      runtime_requirements: %RuntimeRequirements{adapter: "mlx_lm", min_agent_capability: "mlx"}
    })
  end

  defp safe_tokenization do
    tokens = Enum.sort(["<|im_start|>", "<|im_end|>", "<template_only>", "<tool_call>"])

    %SafeTokenization{
      control_tokens: tokens,
      catalog_sha256: catalog_sha256(tokens),
      catalog_source: %SafeTokenization.CatalogSource{
        added_tokens_count: 2,
        config_singletons_count: 0,
        additional_special_tokens_count: 0,
        chat_template_literals_count: 1,
        wrapper_tool_markers_count: 1,
        extra_count: 0
      }
    }
  end

  defp catalog_sha256(tokens) do
    :sha256
    |> :crypto.hash(Enum.join(tokens, <<0>>))
    |> Base.encode16(case: :lower)
  end

  defp create_bundle_root!(tokenizer_json) do
    bundle_root =
      Path.join(
        System.tmp_dir!(),
        "orchard-safe-tokenization-smoke-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(bundle_root)
    File.write!(Path.join(bundle_root, "tokenizer.json"), Jason.encode!(tokenizer_json))
    File.write!(Path.join(bundle_root, "chat_template.jinja"), "{{ messages }}")
    bundle_root
  end

  defp write_response_executable! do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-safe-smoke-#{System.unique_integer([:positive])}.sh"
      )

    response = %{
      contract_version: 2,
      ok: true,
      result: %{rendered_prompt: "ok", input_token_count: 1}
    }

    File.write!(
      script_path,
      "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '#{Jason.encode!(response)}'\n"
    )

    File.chmod!(script_path, 0o755)
    script_path
  end

  defp attach_telemetry(event) do
    parent = self()
    ref = make_ref()

    :telemetry.attach(
      inspect(ref),
      event,
      fn event_name, measurements, metadata, _config ->
        send(parent, {ref, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(inspect(ref)) end)
    ref
  end
end
