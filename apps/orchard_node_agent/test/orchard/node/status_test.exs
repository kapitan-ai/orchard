defmodule Orchard.Node.StatusTest do
  use ExUnit.Case, async: false

  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.EnsureModelLoadedResponse
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.GenerationParams
  alias Orchard.Node.Status

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
    :ok
  end

  setup do
    previous_licensing = Application.get_env(:orchard_shared, :licensing)

    legacy_root =
      Path.join(System.tmp_dir!(), "orchard-legacy-license-#{System.unique_integer([:positive])}")

    legacy_bundle_path = Path.join([legacy_root, "config", "licensing", "current.json"])
    legacy_bundle = ~s({"license_certificate":"legacy","machine_certificate":"legacy"})
    File.mkdir_p!(Path.dirname(legacy_bundle_path))
    File.write!(legacy_bundle_path, legacy_bundle)

    Application.put_env(:orchard_shared, :licensing,
      enforcement_mode: :hard,
      bundle_path: legacy_bundle_path
    )

    :ok = Status.reset()

    on_exit(fn ->
      :ok = Status.reset()

      if previous_licensing do
        Application.put_env(:orchard_shared, :licensing, previous_licensing)
      else
        Application.delete_env(:orchard_shared, :licensing)
      end

      File.rm_rf!(legacy_root)
    end)

    %{legacy_bundle: legacy_bundle, legacy_bundle_path: legacy_bundle_path}
  end

  test "legacy licensing configuration and bundle are ignored and left untouched", context do
    ensure_response = Status.ensure_model_loaded(%EnsureModelLoadedRequest{})

    assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_FAILED} = ensure_response
    assert ensure_response.failure_code == "missing_model_id"

    assert Status.prepare_request(inference_request("prepare"), self()) ==
             {:error, :model_not_loaded}

    assert Status.start_request(inference_request("start")) == {:error, :request_not_prepared}

    assert File.read!(context.legacy_bundle_path) == context.legacy_bundle
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
end
