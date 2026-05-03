defmodule Orchard.API.SafeTokenizationLifecycleTest do
  @moduledoc """
  Phase 4 Slice 5b — full-lifecycle canonical JSON parity smoke.

  Drives `POST /v1/chat/completions` twice for the same benign request:
  once with `tokenizer_safe_mode: :off` as the baseline, once with `:on`.
  The cells assert that persisted canonical request maps omit
  `"prompt_token_ids"`, stay term-equivalent after normalizing only
  request-scoped identifiers and admission queue wait, and retain the
  expected top-level canonical shape.

  This is the negative lifecycle assertion: prompt token IDs reach the worker
  in memory via the populated safe-mode path, but must not persist into
  `canonical_request`. Cross-reference:

    * `apps/orchard_controller/lib/orchard/inference/canonical_request_serializer.ex:9-30`
      for the structural omission;
    * `apps/orchard_controller/test/orchard/inference/canonical_request_serializer_test.exs:96`
      for the unit-level companion assertion;
    * `apps/orchard_controller/test/orchard/inference/request_orchestrator_test.exs:2336-2355`
      for the positive proof that prompt token IDs reach execution;
    * `apps/orchard_controller/test/orchard/api/chat_completions_controller_test.exs:1085-1158`
      for the HTTP-to-DB persistence path under the default safe-mode-off path.

  The smoke uses `tokenizer_mode: :port`, a manifest-bearing staged bundle,
  and a contract-v3 segmented helper response containing prompt IDs under
  `result`. The persisted JSONB map must remain free of those IDs.
  """

  use Orchard.ConnCase, async: false

  import Ecto.Query

  alias Orchard.API.Router
  alias Orchard.ArtifactBundle
  alias Orchard.Governance
  alias Orchard.Inference.QueueManager
  alias Orchard.InferenceEvent
  alias Orchard.Node
  alias Orchard.Node.ModelManager
  alias Orchard.Requests

  @moduletag :db
  @moduletag :safe_tokenization_smoke

  @stream_model_id "safe-tok-lifecycle-stream-model"
  @nonstream_model_id "safe-tok-lifecycle-nonstream-model"
  @rendered_prompt "user hello\nassistant"
  @input_token_count 3
  @prompt_token_ids [101, 102, 103]

  defmodule RuntimeAdapter do
    @moduledoc false
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef
    alias Orchard.InferenceEvent

    @impl true
    def get_status(adapter_state, _opts) do
      {:ok,
       %{
         ready: true,
         health_code: "",
         health_message: "",
         model_ref: Map.get(adapter_state, :model_ref),
         supports_prompt_token_ids: true
       }}
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts), do: {:ok, %{model_ref: model_ref}}

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(adapter_state, %ExecuteInferenceRequest{} = request, opts) do
      owner = Keyword.fetch!(opts, :owner)
      generation_ref = make_ref()

      if capture_pid =
           Application.get_env(:orchard_controller, :safe_tokenization_lifecycle_capture_pid) do
        send(
          capture_pid,
          {:captured_execute_request, request.request_id, request.prompt_token_ids}
        )
      end

      send(owner, {:runtime_adapter_event, generation_ref, completed_event(request)})
      send(owner, {:runtime_adapter_done, generation_ref})
      {:ok, generation_ref, adapter_state}
    end

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state

    defp completed_event(request) do
      InferenceEvent.completed(
        :finish_reason_stop,
        %InferenceEvent.Usage{
          input_tokens: request.input_tokens,
          output_tokens: 0,
          total_tokens: request.input_tokens
        }
      )
    end
  end

  setup do
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)
    previous_orchestrator = Application.get_env(:orchard_controller, :api_chat_orchestrator_impl)
    previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    Application.delete_env(:orchard_controller, :api_chat_orchestrator_impl)
    Application.put_env(:orchard_controller, :safe_tokenization_lifecycle_capture_pid, self())

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(previous_runtime, runtime_adapter_impl: __MODULE__.RuntimeAdapter)
    )

    ModelManager.reset()
    QueueManager.reset()

    on_exit(fn ->
      restore_orchestrator(previous_orchestrator)
      Application.delete_env(:orchard_controller, :safe_tokenization_lifecycle_capture_pid)
      Application.put_env(:orchard_controller, :inference, previous_inference)
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
      QueueManager.reset()
      ModelManager.reset()
      File.rm_rf(Path.join(Node.models_root(), ".staging"))
    end)

    :ok
  end

  test "streaming lifecycle persists canonical_request without prompt_token_ids and stays term-equivalent across :off/:on" do
    %{token: token} = create_api_key_with_token!("safe-tok-lifecycle-stream")
    bundle = stage_safe_lifecycle_bundle!(@stream_model_id)
    create_active_model!(bundle, @stream_model_id)
    capture_file = command_capture_file!()
    tokenizer_executable = write_lifecycle_tokenizer_executable!(capture_file)

    request_params = %{
      "model" => "#{@stream_model_id}@v1",
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "stream" => true
    }

    baseline = run_lifecycle_baseline!(request_params, token, tokenizer_executable)
    assert_stream_completed_successfully(baseline)
    baseline_public_id = baseline.request.public_id
    assert_receive {:captured_execute_request, ^baseline_public_id, []}

    safe_mode =
      run_lifecycle_safe_mode!(request_params, token, tokenizer_executable, baseline.request.id)

    assert_stream_completed_successfully(safe_mode)
    safe_mode_public_id = safe_mode.request.public_id
    assert_receive {:captured_execute_request, ^safe_mode_public_id, @prompt_token_ids}

    assert observed_tokenizer_commands(capture_file) == [
             "render_and_count",
             "render_and_count_segmented"
           ]

    assert_persisted_canonical_parity!(baseline.request, safe_mode.request)
  end

  test "non-streaming lifecycle persists canonical_request without prompt_token_ids and stays term-equivalent across :off/:on" do
    %{token: token} = create_api_key_with_token!("safe-tok-lifecycle-nonstream")
    bundle = stage_safe_lifecycle_bundle!(@nonstream_model_id)
    create_active_model!(bundle, @nonstream_model_id)
    capture_file = command_capture_file!()
    tokenizer_executable = write_lifecycle_tokenizer_executable!(capture_file)

    request_params = %{
      "model" => "#{@nonstream_model_id}@v1",
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "stream" => false
    }

    baseline = run_lifecycle_baseline!(request_params, token, tokenizer_executable)
    assert_non_stream_completed_successfully(baseline)
    baseline_public_id = baseline.request.public_id
    assert_receive {:captured_execute_request, ^baseline_public_id, []}

    safe_mode =
      run_lifecycle_safe_mode!(request_params, token, tokenizer_executable, baseline.request.id)

    assert_non_stream_completed_successfully(safe_mode)
    safe_mode_public_id = safe_mode.request.public_id
    assert_receive {:captured_execute_request, ^safe_mode_public_id, @prompt_token_ids}

    assert observed_tokenizer_commands(capture_file) == [
             "render_and_count",
             "render_and_count_segmented"
           ]

    assert_persisted_canonical_parity!(baseline.request, safe_mode.request)
  end

  defp post_chat(params, token) do
    build_conn(:post, "/v1/chat/completions")
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
    |> Router.call(Router.init([]))
  end

  defp create_api_key_with_token!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, %{api_key: api_key, token: token}} =
      Governance.create_api_key(tenant.id, %{name: "Primary"})

    %{tenant: tenant, api_key: api_key, token: token}
  end

  defp stage_safe_lifecycle_bundle!(model_id) do
    cache_path = Path.join([Node.models_root(), model_id, "v1"])
    File.rm_rf(cache_path)
    File.mkdir_p!(cache_path)
    remember_path(cache_path)

    File.write!(Path.join(cache_path, "config.json"), Jason.encode!(%{"model_type" => "test"}))
    control_tokens = ["<|safe_tokenization_lifecycle|>"]

    File.write!(
      Path.join(cache_path, "tokenizer.json"),
      Jason.encode!(%{
        "version" => "1.0",
        "added_tokens" => [
          %{
            "id" => 101,
            "content" => List.first(control_tokens),
            "single_word" => false,
            "lstrip" => false,
            "rstrip" => false,
            "normalized" => false,
            "special" => true
          }
        ]
      })
    )

    File.write!(Path.join(cache_path, "tokenizer_config.json"), Jason.encode!(%{}))

    chat_template = "{{ messages | length }}"
    File.write!(Path.join(cache_path, "chat_template.jinja"), chat_template)

    weights_dir = Path.join(cache_path, "weights")
    File.mkdir_p!(weights_dir)
    File.write!(Path.join(weights_dir, "model.safetensors"), "safe-tokenization-lifecycle")

    manifest = %{
      "model_id" => model_id,
      "version" => "v1",
      "format" => "mlx",
      "artifact_layout" => "safetensors",
      "entrypoint" => "config.json",
      "sha256" => String.duplicate("0", 64),
      "size_bytes" => 1024,
      "resident_memory_bytes" => 2048,
      "kv_cache_bytes_per_token" => 128,
      "prefill_workspace_bytes_per_token" => 64,
      "max_context_tokens" => 131_072,
      "capabilities" => ["chat"],
      "tokenizer" => %{
        "kind" => "huggingface_tokenizer_json",
        "path" => "tokenizer.json",
        "config_path" => "tokenizer_config.json"
      },
      "chat_template" => %{
        "path" => "chat_template.jinja",
        "sha256" => sha256_hex(chat_template)
      },
      "safe_tokenization" => %{
        "control_tokens" => control_tokens,
        "catalog_sha256" => catalog_sha256(control_tokens),
        "catalog_source" => %{
          "added_tokens_count" => 1,
          "config_singletons_count" => 0,
          "additional_special_tokens_count" => 0,
          "chat_template_literals_count" => 0,
          "wrapper_tool_markers_count" => 0,
          "extra_count" => 0
        },
        "compatible" => true,
        "template_compatible" => true
      },
      "runtime_requirements" => %{
        "adapter" => "mlx",
        "min_agent_capability" => "m1"
      }
    }

    File.write!(Path.join(cache_path, "manifest.json"), Jason.encode!(manifest))
    {:ok, hash} = ArtifactBundle.tree_sha256(cache_path)
    %{hash: hash, cache_path: cache_path}
  end

  defp create_active_model!(bundle, model_id) do
    {:ok, model} =
      Orchard.Models.create_model(%{
        model_id: model_id,
        version: "v1",
        display_name: model_id,
        artifact_uri: "file://#{bundle.cache_path}",
        artifact_sha256: bundle.hash,
        artifact_source_uri: "file://#{bundle.cache_path}",
        state: :active,
        format: "mlx",
        backend: "mlx",
        capabilities: ["chat"],
        artifact_size_bytes: 1024,
        resident_memory_bytes: 2048,
        kv_cache_bytes_per_token: 128,
        prefill_workspace_bytes_per_token: 64,
        max_context_tokens: 131_072
      })

    model
  end

  defp command_capture_file! do
    capture_file =
      Path.join(
        System.tmp_dir!(),
        "safe-tokenization-lifecycle-#{System.unique_integer([:positive])}.commands"
      )

    remember_path(capture_file)
    capture_file
  end

  defp write_lifecycle_tokenizer_executable!(capture_file) do
    executable =
      Path.join(
        System.tmp_dir!(),
        "safe-tokenization-lifecycle-tokenizer-#{System.unique_integer([:positive])}.sh"
      )

    legacy_response =
      Jason.encode!(%{
        contract_version: 2,
        ok: true,
        result: %{
          rendered_prompt: @rendered_prompt,
          input_token_count: @input_token_count
        }
      })

    segmented_response =
      Jason.encode!(%{
        contract_version: 3,
        ok: true,
        result: %{
          rendered_prompt: @rendered_prompt,
          input_token_count: @input_token_count,
          prompt_token_ids: @prompt_token_ids,
          compatible: true,
          template_compatible: true,
          incompatibility_reason: nil
        }
      })

    File.write!(
      executable,
      """
      #!/bin/sh
      set -eu
      request_json=$(cat)

      case "$request_json" in
        *'"command":"render_and_count_segmented"'*)
          printf '%s\n' 'render_and_count_segmented' >> '#{capture_file}'
          printf '%s\n' '#{segmented_response}'
          ;;
        *'"command":"render_and_count"'*)
          printf '%s\n' 'render_and_count' >> '#{capture_file}'
          printf '%s\n' '#{legacy_response}'
          ;;
        *)
          printf '%s\n' 'unexpected' >> '#{capture_file}'
          exit 42
          ;;
      esac
      """
    )

    File.chmod!(executable, 0o755)
    remember_path(executable)
    executable
  end

  defp run_lifecycle_baseline!(request_params, token, tokenizer_executable) do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :off,
        tokenizer_executable: tokenizer_executable
      ],
      fn ->
        conn = post_chat(request_params, token)
        assert conn.status == 200
        %{conn: conn, request: only_request_for_model!(request_params["model"])}
      end
    )
  end

  defp run_lifecycle_safe_mode!(request_params, token, tokenizer_executable, baseline_request_id) do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: tokenizer_executable
      ],
      fn ->
        conn = post_chat(request_params, token)
        assert conn.status == 200

        %{
          conn: conn,
          request: request_after_baseline!(request_params["model"], baseline_request_id)
        }
      end
    )
  end

  defp with_inference_overrides(overrides, fun) when is_function(fun, 0) do
    previous = Application.fetch_env!(:orchard_controller, :inference)
    Application.put_env(:orchard_controller, :inference, Keyword.merge(previous, overrides))

    try do
      fun.()
    after
      Application.put_env(:orchard_controller, :inference, previous)
    end
  end

  defp only_request_for_model!(model_ref) do
    assert [request] = requests_for_model(model_ref)
    request
  end

  defp request_after_baseline!(model_ref, baseline_request_id) do
    requests = requests_for_model(model_ref)
    assert length(requests) == 2
    assert [request] = Enum.reject(requests, &(&1.id == baseline_request_id))
    request
  end

  defp requests_for_model(model_ref) do
    Requests.Request
    |> where([request], request.requested_model == ^model_ref)
    |> order_by([request], asc: request.inserted_at, asc: request.id)
    |> Orchard.Repo.all()
  end

  defp assert_stream_completed_successfully(%{conn: conn, request: request}) do
    events = parse_sse_body(conn.resp_body)
    assert Enum.any?(events, &match?({:done, nil}, &1))
    refute Enum.any?(events, &match?({:error, _payload}, &1))
    refute conn.resp_body =~ "\nevent: error"
    refute String.starts_with?(conn.resp_body, "event: error")
    refute request.state in [:failed, :cancelled, :timed_out]
  end

  defp assert_non_stream_completed_successfully(%{conn: conn, request: request}) do
    body = Jason.decode!(conn.resp_body)
    assert body["object"] == "chat.completion"
    refute Map.has_key?(body, "error")
    refute request.state in [:failed, :cancelled, :timed_out]
  end

  defp parse_sse_body(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_sse_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_sse_line("data: [DONE]"), do: {:done, nil}

  defp parse_sse_line("data: " <> json) do
    decoded = Jason.decode!(json)

    if Map.has_key?(decoded, "error") do
      {:error, decoded}
    else
      {:data, decoded}
    end
  end

  defp parse_sse_line(_line), do: nil

  defp observed_tokenizer_commands(capture_file) do
    capture_file
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp assert_persisted_canonical_parity!(baseline_request, safe_mode_request) do
    baseline_canonical = baseline_request.canonical_request
    safe_mode_canonical = safe_mode_request.canonical_request

    refute Map.has_key?(safe_mode_canonical, "prompt_token_ids")
    assert MapSet.new(Map.keys(safe_mode_canonical)) == expected_canonical_keys()

    assert normalize_for_parity(baseline_canonical) == normalize_for_parity(safe_mode_canonical)
  end

  defp expected_canonical_keys do
    MapSet.new([
      "internal_id",
      "public_id",
      "endpoint",
      "tenant_id",
      "principal_id",
      "api_key_id",
      "model_ref",
      "input_items",
      "rendered_prompt",
      "input_token_count",
      "stream",
      "stream_include_usage",
      "sampling",
      "response_format",
      "tooling",
      "metadata",
      "admission",
      "resolved_policy"
    ])
  end

  defp normalize_for_parity(canonical) when is_map(canonical) do
    canonical
    |> Map.drop(["internal_id", "public_id"])
    |> Map.update("admission", %{}, &normalize_request_scoped_admission/1)
  end

  defp normalize_request_scoped_admission(admission) when is_map(admission) do
    Map.put(admission, "queue_wait_ms", nil)
  end

  defp normalize_request_scoped_admission(other), do: other

  defp catalog_sha256(control_tokens) do
    control_tokens
    |> Enum.intersperse(<<0>>)
    |> IO.iodata_to_binary()
    |> sha256_hex()
  end

  defp sha256_hex(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp remember_path(path) do
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp restore_orchestrator(nil),
    do: Application.delete_env(:orchard_controller, :api_chat_orchestrator_impl)

  defp restore_orchestrator(module) do
    Application.put_env(:orchard_controller, :api_chat_orchestrator_impl, module)
  end
end
