defmodule Orchard.Inference.ChatOrchestratorPortModeTest do
  use Orchard.DataCase, async: false

  alias Orchard.Inference.ChatOrchestrator
  alias Orchard.TestSupport.ModelRequestFixtures

  @fixture_bundle Path.expand("../../fixtures/bundles/test-model-bundle", __DIR__)

  test "prepare/2 succeeds in port tokenizer mode with a real bundle fixture" do
    executable = write_tokenizer_executable!()
    on_exit(fn -> File.rm(executable) end)

    model =
      create_port_mode_model!("file://#{@fixture_bundle}")

    params = %{
      "model" => "#{model.model_id}@#{model.version}",
      "messages" => [%{"role" => "user", "content" => "hello orchard"}],
      "max_tokens" => 16
    }

    with_inference_overrides([tokenizer_mode: :port, tokenizer_executable: executable], fn ->
      assert {:ok, canonical, resolved_model} = ChatOrchestrator.prepare(params, [])
      assert resolved_model.id == model.id
      assert canonical.model_ref.model_id == model.model_id
      assert canonical.model_ref.version == model.version
      assert canonical.sampling.max_output_tokens == 16
      assert canonical.rendered_prompt == "user hello orchard
assistant"
      assert canonical.input_token_count == 3
    end)
  end

  test "prepare/2 returns a sanitized internal tokenization error when manifest parsing fails" do
    invalid_bundle = create_invalid_bundle!()
    on_exit(fn -> File.rm_rf!(invalid_bundle) end)

    model = create_port_mode_model!("file://#{invalid_bundle}")

    params = %{
      "model" => "#{model.model_id}@#{model.version}",
      "messages" => [%{"role" => "user", "content" => "hello orchard"}],
      "max_tokens" => 16
    }

    with_inference_overrides([tokenizer_mode: :port], fn ->
      assert {:error,
              {:tokenization,
               {:internal_error, "model manifest could not be loaded for tokenization"}}} =
               ChatOrchestrator.prepare(params, [])
    end)
  end

  test "prepare/2 returns a sanitized internal tokenization error when manifest is missing" do
    missing_manifest_bundle = create_bundle_without_manifest!()
    on_exit(fn -> File.rm_rf!(missing_manifest_bundle) end)

    model = create_port_mode_model!("file://#{missing_manifest_bundle}")

    params = %{
      "model" => "#{model.model_id}@#{model.version}",
      "messages" => [%{"role" => "user", "content" => "hello orchard"}],
      "max_tokens" => 16
    }

    with_inference_overrides([tokenizer_mode: :port], fn ->
      assert {:error,
              {:tokenization,
               {:internal_error, "model manifest could not be loaded for tokenization"}}} =
               ChatOrchestrator.prepare(params, [])
    end)
  end

  defp with_inference_overrides(overrides, fun) when is_function(fun, 0) do
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(previous_inference, overrides)
    )

    try do
      fun.()
    after
      Application.put_env(:orchard_controller, :inference, previous_inference)
    end
  end

  defp create_port_mode_model!(artifact_uri) do
    ModelRequestFixtures.create_model!(%{
      model_id: "test-org/tiny-llm",
      version: "mlx-q4-v1",
      state: :active,
      artifact_uri: artifact_uri,
      artifact_source_uri: artifact_uri,
      max_context_tokens: 4096
    })
  end

  defp create_invalid_bundle! do
    bundle_dir =
      Path.join(System.tmp_dir!(), "orchard-invalid-bundle-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bundle_dir)
    File.write!(Path.join(bundle_dir, "manifest.json"), "{bad json")
    bundle_dir
  end

  defp create_bundle_without_manifest! do
    bundle_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-missing-manifest-bundle-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(bundle_dir)
    bundle_dir
  end

  defp write_tokenizer_executable! do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-port-test-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(
      script_path,
      "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"contract_version\":1,\"ok\":true,\"result\":{\"rendered_prompt\":\"user hello orchard\\nassistant\",\"input_token_count\":3}}'\n"
    )

    File.chmod!(script_path, 0o755)
    script_path
  end
end
