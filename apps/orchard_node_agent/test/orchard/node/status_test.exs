defmodule Orchard.Node.StatusTest do
  use ExUnit.Case, async: false

  alias Orchard.Cluster.V1.Ack
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.EnsureModelLoadedResponse
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.GenerationParams
  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.Cluster.V1.ScorePrefixCacheRequest
  alias Orchard.Cluster.V1.ScorePrefixCacheResponse
  alias Orchard.Cluster.V1.StatusResponse
  alias Orchard.Cluster.V1.UnloadModelRequest
  alias Orchard.Licensing.Gate
  alias Orchard.Licensing.LocalStore
  alias Orchard.Node.RuntimeServer
  alias Orchard.Node.Status

  @fixture_dir Path.expand("../../../../orchard_shared/test/fixtures/licensing", __DIR__)
  @public_key_hex "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
  @local_node_id "11111111-2222-4333-8444-555555555555"

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
    :ok
  end

  setup do
    previous_licensing = Application.get_env(:orchard_shared, :licensing, [])

    tmp_dir =
      Path.join([
        System.tmp_dir!(),
        "orchard-node-status-license-test",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    bundle_path = Path.join([tmp_dir, "config", "licensing", "current.json"])
    node_identity_path = Path.join([tmp_dir, "data", "node-id"])

    Application.put_env(
      :orchard_shared,
      :licensing,
      Keyword.merge(previous_licensing,
        bundle_path: bundle_path,
        node_identity_path: node_identity_path,
        keygen_public_key: @public_key_hex,
        enforcement_mode: :off,
        gate_cache_ttl_seconds: 1
      )
    )

    Gate.refresh()
    File.mkdir_p!(tmp_dir)
    write_node_identity!(node_identity_path, @local_node_id)
    :ok = Status.reset()

    on_exit(fn ->
      :ok = Status.reset()
      Gate.refresh()
      Application.put_env(:orchard_shared, :licensing, previous_licensing)
      File.rm_rf!(tmp_dir)
    end)

    %{bundle_path: bundle_path}
  end

  for mode <- [:off, :warn] do
    test "#{mode} mode does not add license denial to useful operations" do
      put_enforcement_mode(unquote(mode))
      Gate.refresh()

      ensure_response = Status.ensure_model_loaded(invalid_ensure_request())

      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_FAILED} =
               ensure_response

      refute ensure_response.failure_code == "license_invalid"

      assert Status.prepare_request(inference_request("req-#{unquote(mode)}"), self()) ==
               {:error, :model_not_loaded}

      assert Status.start_request(inference_request("req-start-#{unquote(mode)}")) ==
               {:error, :request_not_prepared}
    end
  end

  test "hard mode without a bundle denies useful operations and leaves diagnostics available" do
    put_enforcement_mode(:hard)
    Gate.refresh()

    ensure_response = Status.ensure_model_loaded(invalid_ensure_request())

    assert %EnsureModelLoadedResponse{
             placement_state: :PLACEMENT_STATE_FAILED,
             failure_category: :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL,
             failure_code: "license_invalid",
             failure_message: message
           } = ensure_response

    assert message =~ "Node-agent license invalid:"
    assert message =~ "requires an activated license"
    assert message =~ "orchardctl license activate"

    assert Status.prepare_request(inference_request("req-missing-license"), self()) ==
             {:error, :license_invalid}

    assert Status.start_request(inference_request("req-start-missing-license")) ==
             {:error, :license_invalid}

    assert %StatusResponse{} = Status.current()

    assert %ScorePrefixCacheResponse{status_code: "model_not_loaded"} =
             Status.score_prefix_cache(score_request())

    assert %Ack{ok: true} = Status.cancel_request("missing-request", "controller-session")
    assert %Ack{ok: true, message: "model already absent"} = Status.unload_model(unload_request())
    assert :ok = Status.reset()
  end

  test "hard mode with an expired bundle returns operator guidance for model load", ctx do
    put_enforcement_mode(:hard)
    copy_fixture!("expired", ctx.bundle_path)
    Gate.refresh()

    ensure_response = Status.ensure_model_loaded(invalid_ensure_request())

    assert ensure_response.failure_code == "license_invalid"
    assert ensure_response.failure_message =~ "Node-agent license invalid:"
    assert ensure_response.failure_message =~ "license has expired"
    assert ensure_response.failure_message =~ "Activate a current license"
  end

  test "hard mode with a valid bundle passes through to ModelManager behavior", ctx do
    put_enforcement_mode(:hard)
    copy_fixture!("valid_bound_to_local", ctx.bundle_path)
    Gate.refresh()

    ensure_response = Status.ensure_model_loaded(invalid_ensure_request())

    assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_FAILED} = ensure_response
    assert ensure_response.failure_code == "missing_model_id"

    assert Status.prepare_request(inference_request("req-valid-license"), self()) ==
             {:error, :model_not_loaded}

    assert Status.start_request(inference_request("req-start-valid-license")) ==
             {:error, :request_not_prepared}
  end

  test "runtime server keeps license_invalid as a stable failure reason" do
    assert RuntimeServer.safe_failure_reason_code(:license_invalid) == "license_invalid"
    assert RuntimeServer.safe_failure_reason_code("license-invalid") == "license_invalid"
  end

  test "fixture flip to expired denies next admission while status still succeeds", ctx do
    put_enforcement_mode(:hard)
    copy_fixture!("valid_bound_to_local", ctx.bundle_path)
    Gate.refresh()

    valid_response = Status.ensure_model_loaded(invalid_ensure_request())
    assert valid_response.failure_code == "missing_model_id"
    assert %StatusResponse{} = Status.current()

    replace_bundle_externally!(ctx.bundle_path, "expired")
    Gate.refresh()

    expired_response = Status.ensure_model_loaded(invalid_ensure_request())
    assert expired_response.failure_code == "license_invalid"
    assert expired_response.failure_message =~ "license has expired"

    assert Status.prepare_request(inference_request("req-expired-after-start"), self()) ==
             {:error, :license_invalid}

    assert %StatusResponse{} = Status.current()
  end

  defp put_enforcement_mode(mode) do
    licensing =
      :orchard_shared
      |> Application.get_env(:licensing, [])
      |> Keyword.put(:enforcement_mode, mode)

    Application.put_env(:orchard_shared, :licensing, licensing)
  end

  defp invalid_ensure_request do
    %EnsureModelLoadedRequest{deadline_unix_ms: System.system_time(:millisecond) + 5_000}
  end

  defp inference_request(request_id) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: "controller-session",
      model_id: "mlx-community/phi-3",
      version: "main",
      rendered_prompt_utf8: "hello orchard",
      input_tokens: 2,
      params: %GenerationParams{max_output_tokens: 16},
      deadline_unix_ms: System.system_time(:millisecond) + 5_000,
      metadata_json: ~s({"source":"status-test"})
    }
  end

  defp score_request do
    %ScorePrefixCacheRequest{
      request_id: "score-request",
      controller_session_id: "controller-session",
      model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
      cache_affinity_fingerprint: "hmac-sha256:" <> String.duplicate("a", 64),
      deadline_unix_ms: System.system_time(:millisecond) + 1_000
    }
  end

  defp unload_request do
    %UnloadModelRequest{model_id: "mlx-community/phi-3", version: "main", force: true}
  end

  defp copy_fixture!(name, bundle_path) do
    File.mkdir_p!(Path.dirname(bundle_path))
    File.cp!(fixture_path(name), bundle_path)
  end

  defp replace_bundle_externally!(bundle_path, fixture_name) do
    assert :ok = LocalStore.write(bundle_path, load_fixture_bundle!(fixture_name))
  end

  defp load_fixture_bundle!(name) do
    fixture_path(name)
    |> File.read!()
    |> Jason.decode!()
    |> then(fn %{
                 "license_certificate" => license_certificate,
                 "machine_certificate" => machine_certificate
               } ->
      %{license_certificate: license_certificate, machine_certificate: machine_certificate}
    end)
  end

  defp fixture_path(name), do: Path.join(@fixture_dir, "#{name}.json")

  defp write_node_identity!(node_identity_path, node_id) do
    File.mkdir_p!(Path.dirname(node_identity_path))
    File.write!(node_identity_path, node_id <> "\n")
  end
end
