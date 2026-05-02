defmodule Orchard.Tokenizer.CatalogDriftTest do
  use ExUnit.Case, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.ModelManifest
  alias Orchard.ModelManifest.{ChatTemplate, RuntimeRequirements, SafeTokenization, Tokenizer}
  alias Orchard.Tokenizer.Client

  defmodule AddedDriftDetector do
    def partial_catalog(_tokenizer_path) do
      {:ok, ["<|im_start|>", "<|im_end|>", "<|drift_token|>"], []}
    end

    def detect(_catalog, _caller_strings), do: []
  end

  defmodule NoDriftDetector do
    def partial_catalog(_tokenizer_path) do
      {:ok, ["<|im_start|>", "<|im_end|>"], []}
    end

    def detect(_catalog, _caller_strings), do: []
  end

  defmodule ManyDriftDetector do
    def partial_catalog(_tokenizer_path) do
      drift_tokens = Enum.map(1..64, fn index -> "<|drift_#{index}|>" end)
      {:ok, ["<|im_start|>" | drift_tokens], []}
    end

    def detect(_catalog, _caller_strings), do: []
  end

  defmodule RealDetector do
    defdelegate partial_catalog(tokenizer_path), to: Orchard.Tokenizer.ControlTokenDetector
    def detect(_catalog, _caller_strings), do: []
  end

  @event [:orchard, :tokenizer, :catalog_drift]
  @bundle_sha256 String.duplicate("c", 64)

  setup do
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)
    executable = write_response_executable!()
    bundle_root = create_bundle_root!()

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(previous_inference,
        tokenizer_mode: :port,
        tokenizer_safe_mode: :off,
        tokenizer_executable: executable
      )
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, previous_inference)
      File.rm(executable)
      File.rm_rf!(bundle_root)
    end)

    %{bundle_root: bundle_root}
  end

  test "emits catalog_drift when live partial catalog has tokens absent from manifest", %{
    bundle_root: bundle_root
  } do
    attach_ref = attach_telemetry(@event)

    assert {:ok, %{rendered_prompt: "ok", input_token_count: 1}} =
             Client.tokenize(canonical_request(),
               manifest: safe_manifest(),
               bundle_root: bundle_root,
               bundle_sha256: @bundle_sha256,
               control_token_detector: AddedDriftDetector
             )

    assert_receive {^attach_ref, @event, %{count: 1}, metadata}

    assert metadata.request_id == "req_catalog_drift"
    assert metadata.model_id == "test/model"
    assert metadata.version == "v1"
    assert metadata.endpoint == :chat_completions
    assert metadata.bundle_id == safe_manifest().sha256
    assert metadata.bundle_sha256 == @bundle_sha256
    assert metadata.catalog_sha256 == safe_manifest().safe_tokenization.catalog_sha256
    assert metadata.added_count == 1
    assert metadata.partial_detection == true

    assert metadata.covered_catalog_sources == [
             :tokenizer_special_added_tokens,
             :tokenizer_config_singletons,
             :additional_special_tokens
           ]

    assert metadata.missing_catalog_sources == [
             :tokenizer_non_special_added_tokens,
             :chat_template_literals,
             :wrapper_tool_markers
           ]

    assert metadata.drift_direction == :added_only

    assert [%{value: "<|drift_token|>", byte_size: 15, family: :angle_pipe, truncated: false}] =
             metadata.added

    assert metadata.added_truncated == false
    assert metadata.added_metadata_max_count == 16
    assert metadata.added_metadata_max_bytes == 64
    refute Map.has_key?(metadata, :removed)
  end

  test "does not emit catalog_drift when live partial catalog is covered by manifest", %{
    bundle_root: bundle_root
  } do
    attach_ref = attach_telemetry(@event)

    assert {:ok, %{rendered_prompt: "ok", input_token_count: 1}} =
             Client.tokenize(canonical_request(),
               manifest: safe_manifest(),
               bundle_root: bundle_root,
               bundle_sha256: @bundle_sha256,
               control_token_detector: NoDriftDetector
             )

    refute_receive {^attach_ref, @event, _, _}, 200
  end

  test "does not emit catalog_drift when manifest has no safe tokenization catalog", %{
    bundle_root: bundle_root
  } do
    attach_ref = attach_telemetry(@event)

    assert {:ok, %{rendered_prompt: "ok", input_token_count: 1}} =
             Client.tokenize(canonical_request(),
               manifest: unsafe_manifest(),
               bundle_root: bundle_root,
               bundle_sha256: @bundle_sha256,
               control_token_detector: AddedDriftDetector
             )

    refute_receive {^attach_ref, @event, _, _}, 200
  end

  test "caps added metadata while retaining full added_count", %{bundle_root: bundle_root} do
    attach_ref = attach_telemetry(@event)

    assert {:ok, %{rendered_prompt: "ok", input_token_count: 1}} =
             Client.tokenize(canonical_request(),
               manifest: safe_manifest(),
               bundle_root: bundle_root,
               bundle_sha256: @bundle_sha256,
               control_token_detector: ManyDriftDetector
             )

    assert_receive {^attach_ref, @event, %{count: 1}, metadata}

    assert metadata.added_count == 64
    assert length(metadata.added) == 16
    assert metadata.added_truncated == true
    assert Enum.all?(metadata.added, &String.valid?(&1.value))
    assert Enum.all?(metadata.added, &(byte_size(&1.value) <= 64))
  end

  test "real detector emits drift for special added token absent from manifest" do
    bundle_root =
      create_bundle_root!(%{
        "added_tokens" => [%{"content" => "<|new_special|>", "special" => true}]
      })

    attach_ref = attach_telemetry(@event)

    on_exit(fn -> File.rm_rf!(bundle_root) end)

    assert {:ok, %{rendered_prompt: "ok", input_token_count: 1}} =
             Client.tokenize(canonical_request(),
               manifest: safe_manifest(),
               bundle_root: bundle_root,
               bundle_sha256: @bundle_sha256,
               control_token_detector: RealDetector
             )

    assert_receive {^attach_ref, @event, %{count: 1}, metadata}
    assert metadata.added_count == 1
    assert [%{value: "<|new_special|>"}] = metadata.added
  end

  test "real detector emits drift for tokenizer_json tokenizer kind" do
    bundle_root =
      create_bundle_root!(%{
        "added_tokens" => [%{"content" => "<|new_special|>", "special" => true}]
      })

    attach_ref = attach_telemetry(@event)

    on_exit(fn -> File.rm_rf!(bundle_root) end)

    assert {:ok, %{rendered_prompt: "ok", input_token_count: 1}} =
             Client.tokenize(canonical_request(),
               manifest: safe_manifest_with_tokenizer_kind("tokenizer_json"),
               bundle_root: bundle_root,
               bundle_sha256: @bundle_sha256,
               control_token_detector: RealDetector
             )

    assert_receive {^attach_ref, @event, %{count: 1}, metadata}
    assert metadata.added_count == 1
    assert [%{value: "<|new_special|>"}] = metadata.added
  end

  test "real detector ignores non-special added token for catalog drift" do
    bundle_root =
      create_bundle_root!(%{
        "added_tokens" => [%{"content" => "<|ordinary_added|>", "special" => false}]
      })

    attach_ref = attach_telemetry(@event)

    on_exit(fn -> File.rm_rf!(bundle_root) end)

    assert {:ok, %{rendered_prompt: "ok", input_token_count: 1}} =
             Client.tokenize(canonical_request(),
               manifest: safe_manifest(),
               bundle_root: bundle_root,
               bundle_sha256: @bundle_sha256,
               control_token_detector: RealDetector
             )

    refute_receive {^attach_ref, @event, _, _}, 200
  end

  defp canonical_request do
    CanonicalRequest.new(%{
      internal_id: "req_internal_catalog_drift",
      public_id: "req_catalog_drift",
      endpoint: :chat_completions,
      tenant_id: "tenant_test",
      model_ref: %ModelRef{model_id: "test/model", version: "v1"},
      input_items: [%{role: "user", content: "hello"}]
    })
  end

  defp safe_manifest do
    %ModelManifest{unsafe_manifest() | safe_tokenization: safe_tokenization()}
  end

  defp safe_manifest_with_tokenizer_kind(kind) do
    %ModelManifest{tokenizer: %Tokenizer{} = tokenizer} = manifest = safe_manifest()
    %ModelManifest{manifest | tokenizer: %Tokenizer{tokenizer | kind: kind}}
  end

  defp unsafe_manifest do
    ModelManifest.new(%{
      model_id: "test/model",
      version: "v1",
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

  defp create_bundle_root!(tokenizer_json \\ %{"added_tokens" => []}) do
    bundle_root =
      Path.join(System.tmp_dir!(), "orchard-catalog-drift-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bundle_root)
    File.write!(Path.join(bundle_root, "tokenizer.json"), Jason.encode!(tokenizer_json))
    File.write!(Path.join(bundle_root, "chat_template.jinja"), "{{ messages }}")
    bundle_root
  end

  defp write_response_executable! do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-catalog-drift-#{System.unique_integer([:positive])}.sh"
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
