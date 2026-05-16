defmodule OrchardTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.API.ErrorJSON
  alias Orchard.API.Readiness
  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.Cluster.V1.ModelRef, as: ProtoModelRef
  alias Orchard.InferenceContract
  alias Orchard.InferenceEvent
  alias Orchard.ModelManifest
  alias Orchard.ModelManifest.{RuntimeRequirements, Tokenizer}
  alias Orchard.Release

  test "controller version is derived from app metadata" do
    vsn = Application.spec(:orchard_controller, :vsn)
    expected = if is_list(vsn), do: List.to_string(vsn), else: to_string(vsn)
    assert Orchard.version() == expected
  end

  test "readiness and release helpers fail closed when repo-backed db checks are disabled" do
    assert {:error, :postgres_reachable, checks} = Readiness.status()
    # Causal priority: postgres_reachable reported first; migrations blocked by DB
    assert checks.postgres_reachable == false
    assert checks.migrations_current == false
    refute Release.migrations_current?()
  end

  test "readiness derives public API HTTPS from transport mode, not legacy degraded shim" do
    previous_mode = Application.get_env(:orchard_controller, :transport_mode)
    previous_degraded = Application.get_env(:orchard_controller, :transport_degraded, false)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :transport_mode, previous_mode)
      Application.put_env(:orchard_controller, :transport_degraded, previous_degraded)
    end)

    Application.put_env(:orchard_controller, :transport_mode, :direct_https)
    Application.put_env(:orchard_controller, :transport_degraded, true)

    assert {:error, :postgres_reachable, direct_checks} = Readiness.status()
    assert direct_checks.public_api_https_enabled == true

    Application.put_env(:orchard_controller, :transport_mode, :reverse_proxy)
    assert {:error, :postgres_reachable, proxy_checks} = Readiness.status()
    assert proxy_checks.public_api_https_enabled == true

    Application.put_env(:orchard_controller, :transport_mode, :plain_http_localhost)
    Application.put_env(:orchard_controller, :transport_degraded, false)

    assert {:error, :postgres_reachable, local_checks} = Readiness.status()
    assert local_checks.public_api_https_enabled == false
  end

  test "readiness reason: public_api_https_enabled is primary when only transport mode is degraded" do
    # Exercise the scenario where DB checks pass but transport is degraded.
    # The Repo is already started by test_helper.exs; enable DB checks and
    # check out a sandbox connection so postgres_reachable returns true,
    # isolating public_api_https_enabled as the sole failure.
    previous_mode = Application.get_env(:orchard_controller, :transport_mode)
    previous_degraded = Application.get_env(:orchard_controller, :transport_degraded, false)
    previous_db_checks = Application.get_env(:orchard_controller, :enable_db_checks, true)
    previous_start_repo = Application.get_env(:orchard_controller, :start_repo, true)

    Application.put_env(:orchard_controller, :transport_mode, :plain_http_localhost)
    Application.put_env(:orchard_controller, :transport_degraded, false)
    Application.put_env(:orchard_controller, :enable_db_checks, true)
    Application.put_env(:orchard_controller, :start_repo, true)

    :ok = Sandbox.checkout(Orchard.Repo)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :transport_mode, previous_mode)
      Application.put_env(:orchard_controller, :transport_degraded, previous_degraded)
      Application.put_env(:orchard_controller, :enable_db_checks, previous_db_checks)
      Application.put_env(:orchard_controller, :start_repo, previous_start_repo)
    end)

    assert {:error, :public_api_https_enabled, checks} = Readiness.status()
    assert checks.postgres_reachable == true
    assert checks.migrations_current == true
    assert checks.public_api_https_enabled == false
  end

  test "error json renders standard status messages" do
    assert ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "controller references the shared request, event, and manifest shapes" do
    request =
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"}
      })

    event = InferenceEvent.output_text_delta("hello")

    manifest =
      ModelManifest.new(%{
        model_id: "mlx-community/phi-3",
        version: "main",
        format: "mlx",
        artifact_layout: "directory",
        entrypoint: "weights/",
        sha256: "abc123",
        max_context_tokens: 32_768,
        capabilities: ["chat"],
        tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "tokenizer.json"},
        runtime_requirements: %RuntimeRequirements{adapter: "mlx_lm", min_agent_capability: "mlx"}
      })

    assert InferenceContract.request_model_ref(request).model_id == "mlx-community/phi-3"
    assert InferenceContract.event_kind(event) == :output_text_delta
    assert %ProtoModelRef{} = InferenceContract.manifest_proto_model_ref(manifest)
  end
end
