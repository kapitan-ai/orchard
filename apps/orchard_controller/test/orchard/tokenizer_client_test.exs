defmodule Orchard.Tokenizer.ClientTest do
  use ExUnit.Case, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.ModelManifest
  alias Orchard.ModelManifest.{ChatTemplate, RuntimeRequirements, SafeTokenization, Tokenizer}
  alias Orchard.Tokenizer.{Client, CompatibilityCache}

  defmodule RaisingControlTokenDetector do
    def partial_catalog(_tokenizer_path), do: raise(RuntimeError, "secret /tmp/caller-data")
    def detect(_catalog, _caller_strings), do: []
  end

  defmodule ThrowingControlTokenDetector do
    def partial_catalog(_tokenizer_path), do: throw({:secret, "/tmp/caller-data"})
    def detect(_catalog, _caller_strings), do: []
  end

  defmodule OversizedLiteralControlTokenDetector do
    def partial_catalog(_tokenizer_path), do: {:ok, ["unused"], []}

    def detect(_catalog, _caller_strings) do
      [{"messages[0].content", "<|" <> String.duplicate("x", 100) <> "|>", 0}]
    end
  end

  defmodule BypassingTokenizerClient do
    def tokenize(_request, _opts),
      do: {:ok, %{rendered_prompt: "unexpected", input_token_count: 0}}
  end

  setup do
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)
    CompatibilityCache.clear()

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, previous_inference)
      CompatibilityCache.clear()
    end)

    :ok
  end

  test "fake mode renders a deterministic prompt and token count" do
    request = canonical_request()

    assert {:ok,
            %{
              rendered_prompt: "system orchard\nuser hello orchard\nassistant",
              input_token_count: 6
            }} = Client.tokenize(request)
  end

  test "tokenize rejects unsupported roles before configured tokenizer client dispatch" do
    request =
      canonical_request(%{
        input_items: [
          %{role: "<|im_start|>", content: "hello orchard"}
        ]
      })

    with_inference_overrides([tokenizer_client_impl: BypassingTokenizerClient], fn ->
      assert {:error, {:invalid_input, message}} = Client.tokenize(request)
      assert message =~ "input_items[0].role is unsupported"
    end)
  end

  test "fake mode returns invalid_input for malformed content parts" do
    request =
      CanonicalRequest.new(%{
        internal_id: "req_internal_tokenizer_invalid",
        public_id: "req_tokenizer_invalid",
        endpoint: :chat_completions,
        tenant_id: "tenant_test",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        input_items: [
          %{role: "user", content: ["not-a-map"]}
        ]
      })

    assert {:error, {:invalid_input, message}} = Client.tokenize(request)
    assert message =~ "text parts"
  end

  test "fake mode rejects effective tool-calling requests" do
    assert {:error, {:invalid_input, message}} =
             Client.tokenize(
               canonical_request(tooling: %{tools: [tool("lookup_weather")], tool_choice: "auto"})
             )

    assert message =~ "does not support tool-calling"
  end

  test "port mode returns rendered prompt and exact token count from structured JSON" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        request = canonical_request()

        assert {:ok,
                %{
                  rendered_prompt: "system orchard\nuser hello orchard\nassistant",
                  input_token_count: 6
                }} =
                 Client.tokenize(request,
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )
      end
    )
  end

  test "port mode writes runtime request through private transport directory and cleans it up" do
    tmp_root = unique_tmp_root!("orchard-tokenizer-runtime-transport")
    {transport_executable, probe_file} = write_runtime_transport_asserting_executable!(tmp_root)

    on_exit(fn ->
      File.rm(transport_executable)
      File.rm_rf!(tmp_root)
    end)

    with_system_tmpdir(tmp_root, fn ->
      with_inference_overrides(
        [
          tokenizer_mode: :port,
          tokenizer_executable: transport_executable
        ],
        fn ->
          assert {:ok, %{rendered_prompt: "transport ok", input_token_count: 1}} =
                   Client.tokenize(canonical_request(),
                     manifest: huggingface_manifest(),
                     bundle_root: huggingface_fixture_root(),
                     bundle_sha256: trusted_bundle_sha256()
                   )
        end
      )
    end)

    assert [] = runtime_transport_dirs(tmp_root)
    assert File.read!(probe_file) =~ "ok"
  end

  test "port mode render_and_count request stays on contract v2" do
    {capture_executable, capture_file} = write_capture_request_executable!()

    on_exit(fn ->
      File.rm(capture_executable)
      File.rm(capture_file)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: capture_executable
      ],
      fn ->
        assert {:ok, %{input_token_count: input_token_count}} =
                 Client.tokenize(canonical_request(),
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert input_token_count > 0
        assert {:ok, raw_request} = File.read(capture_file)

        assert %{
                 "contract_version" => 2,
                 "command" => "render_and_count",
                 "assets" => %{},
                 "request" => %{}
               } = Jason.decode!(raw_request)
      end
    )
  end

  test "port mode rejects contract v3 response for render_and_count" do
    response_executable =
      write_response_executable!(%{
        "contract_version" => 3,
        "ok" => true,
        "result" => %{"rendered_prompt" => "x", "input_token_count" => 1}
      })

    on_exit(fn -> File.rm(response_executable) end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: response_executable
      ],
      fn ->
        assert {:error, :invalid_response} =
                 Client.tokenize(canonical_request(),
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )
      end
    )
  end

  test "safe mode on forwards manifest catalog and explicit tokenizer config to segmented helper" do
    fixture_root = fixture_root_with_tokenizer_config!()
    {capture_executable, capture_file} = write_capture_request_executable!(segmented_response())

    on_exit(fn ->
      File.rm(capture_executable)
      File.rm(capture_file)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: capture_executable
      ],
      fn ->
        manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")

        assert {:ok,
                %{
                  rendered_prompt: "segmented",
                  input_token_count: 2,
                  prompt_token_ids: [101, 102]
                }} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert {:ok, raw_request} = File.read(capture_file)
        request = Jason.decode!(raw_request)

        assert request["contract_version"] == 3
        assert request["command"] == "render_and_count_segmented"

        assert request["safe_tokenization"] == %{
                 "control_tokens" => safe_control_tokens(),
                 "catalog_sha256" => catalog_sha256(safe_control_tokens())
               }

        assert request["assets"]["tokenizer_config_path"] ==
                 realpath!(Path.join(fixture_root, "tokenizer_config.json"))

        assert {:compatible, %{template_compatible: true, sentinel_preflight_validated: true}} =
                 CompatibilityCache.get(
                   trusted_bundle_sha256(),
                   manifest.safe_tokenization.catalog_sha256
                 )
      end
    )
  end

  test "safe mode skips sentinel preflight after a compatible pair is cached" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")
    {capture_executable, env_file} = write_env_capture_executable!(segmented_response())

    on_exit(fn ->
      File.rm(capture_executable)
      File.rm(env_file)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: capture_executable
      ],
      fn ->
        assert {:ok, %{prompt_token_ids: [101, 102]}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert {:compatible, %{template_compatible: true, sentinel_preflight_validated: true}} =
                 CompatibilityCache.get(
                   trusted_bundle_sha256(),
                   manifest.safe_tokenization.catalog_sha256
                 )

        assert {:ok, %{prompt_token_ids: [101, 102]}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert ["0", "1"] = env_capture_lines(env_file)
      end
    )
  end

  test "safe mode seeds cache from explicit manifest-compatible preflight verdict" do
    fixture_root = fixture_root_with_tokenizer_config!()

    manifest =
      explicit_preflight_compatible_manifest(config_path: "tokenizer_config.json")
      |> Map.put(:sha256, "pending")

    {capture_executable, env_file} = write_env_capture_executable!(segmented_response())

    on_exit(fn ->
      File.rm(capture_executable)
      File.rm(env_file)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: capture_executable
      ],
      fn ->
        assert :unknown =
                 CompatibilityCache.get(
                   trusted_bundle_sha256(),
                   manifest.safe_tokenization.catalog_sha256
                 )

        assert {:ok, %{prompt_token_ids: [101, 102]}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert ["1"] = env_capture_lines(env_file)

        assert {:compatible, %{template_compatible: true, sentinel_preflight_validated: true}} =
                 CompatibilityCache.get(
                   trusted_bundle_sha256(),
                   manifest.safe_tokenization.catalog_sha256
                 )

        assert :unknown =
                 CompatibilityCache.get("pending", manifest.safe_tokenization.catalog_sha256)
      end
    )
  end

  test "safe mode does not seed declared-positive cache when manifest trust is disabled" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = explicit_preflight_compatible_manifest(config_path: "tokenizer_config.json")
    {capture_executable, env_file} = write_env_capture_executable!(segmented_response())

    on_exit(fn ->
      File.rm(capture_executable)
      File.rm(env_file)
      File.rm_rf!(fixture_root)
    end)

    with_app_env(:trust_manifest_compatibility_declarations, false, fn ->
      with_inference_overrides(
        [
          tokenizer_mode: :port,
          tokenizer_safe_mode: :on,
          tokenizer_executable: capture_executable
        ],
        fn ->
          assert {:ok, %{prompt_token_ids: [101, 102]}} =
                   Client.tokenize(canonical_request(),
                     manifest: manifest,
                     bundle_root: fixture_root,
                     bundle_sha256: trusted_bundle_sha256()
                   )

          assert ["0"] = env_capture_lines(env_file)
        end
      )
    end)
  end

  test "safe mode requires trusted bundle sha256 instead of manifest sha256" do
    fixture_root = fixture_root_with_tokenizer_config!()

    manifest =
      explicit_preflight_compatible_manifest(config_path: "tokenizer_config.json")
      |> Map.put(:sha256, "pending")

    {capture_executable, _capture_file} = write_capture_request_executable!(segmented_response())

    on_exit(fn ->
      File.rm(capture_executable)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: capture_executable
      ],
      fn ->
        assert {:error, {:invalid_input, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root
                 )

        assert message =~ "trusted :bundle_sha256"

        assert {:error, {:invalid_input, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: "pending"
                 )

        assert message =~ "64-character lowercase hex"

        assert :unknown =
                 CompatibilityCache.get("pending", manifest.safe_tokenization.catalog_sha256)
      end
    )
  end

  test "safe mode does not seed declared-positive cache before segmented assets resolve" do
    manifest = explicit_preflight_compatible_manifest()

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: "/missing/orchard-tokenizer"
      ],
      fn ->
        assert {:error, {:missing_assets, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "tokenizer.config_path"

        assert :unknown =
                 CompatibilityCache.get(
                   trusted_bundle_sha256(),
                   manifest.safe_tokenization.catalog_sha256
                 )
      end
    )
  end

  test "safe mode does not seed cache from partial positive manifest verdict" do
    fixture_root = fixture_root_with_tokenizer_config!()

    manifest =
      safe_huggingface_manifest(config_path: "tokenizer_config.json")
      |> put_safe_tokenization(%{template_compatible: true})

    {capture_executable, env_file} = write_env_capture_executable!(segmented_response())

    on_exit(fn ->
      File.rm(capture_executable)
      File.rm(env_file)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: capture_executable
      ],
      fn ->
        assert {:ok, %{prompt_token_ids: [101, 102]}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert ["0"] = env_capture_lines(env_file)
      end
    )
  end

  test "safe mode manifest-compatible seed preserves cached incompatibility" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = explicit_preflight_compatible_manifest()

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    assert :ok =
             CompatibilityCache.put_incompatible(
               trusted_bundle_sha256(),
               manifest.safe_tokenization.catalog_sha256,
               %{"category" => "dual_render_mismatch"}
             )

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: "/missing/orchard-tokenizer"
      ],
      fn ->
        assert {:error, {:safe_tokenization_incompatible_template, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "cached safe-tokenization incompatibility"

        assert {:incompatible, %{"category" => "dual_render_mismatch"}} =
                 CompatibilityCache.get(
                   trusted_bundle_sha256(),
                   manifest.safe_tokenization.catalog_sha256
                 )
      end
    )
  end

  test "safe mode manifest-declared negative verdict fails closed before helper dispatch" do
    manifest = manifest_declared_incompatible()

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: "/missing/orchard-tokenizer"
      ],
      fn ->
        assert {:error, {:safe_tokenization_incompatible_tokenizer, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "manifest safe_tokenization marks this bundle incompatible"

        assert :unknown =
                 CompatibilityCache.get(
                   trusted_bundle_sha256(),
                   manifest.safe_tokenization.catalog_sha256
                 )
      end
    )
  end

  test "safe mode ignores ambient sentinel skip env before compatibility is cached" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")
    {capture_executable, env_file} = write_env_capture_executable!(segmented_response())
    previous_skip_env = System.get_env("ORCHARD_TOKENIZER_SKIP_SENTINEL_PREFLIGHT")

    System.put_env("ORCHARD_TOKENIZER_SKIP_SENTINEL_PREFLIGHT", "1")

    on_exit(fn ->
      restore_skip_sentinel_preflight_env(previous_skip_env)
      File.rm(capture_executable)
      File.rm(env_file)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: capture_executable
      ],
      fn ->
        assert {:ok, %{prompt_token_ids: [101, 102]}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert {:ok, %{prompt_token_ids: [101, 102]}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert ["0", "1"] = env_capture_lines(env_file)
      end
    )
  end

  test "safe mode cached compatible verdict without sentinel metadata does not skip preflight" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")
    {capture_executable, env_file} = write_env_capture_executable!(segmented_response())

    assert :ok =
             CompatibilityCache.put_compatible(
               trusted_bundle_sha256(),
               manifest.safe_tokenization.catalog_sha256,
               %{template_compatible: true}
             )

    on_exit(fn ->
      File.rm(capture_executable)
      File.rm(env_file)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :reject,
        tokenizer_executable: capture_executable
      ],
      fn ->
        assert {:ok, %{prompt_token_ids: [101, 102]}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert ["0"] = env_capture_lines(env_file)

        assert {:compatible, %{template_compatible: true, sentinel_preflight_validated: true}} =
                 CompatibilityCache.get(
                   trusted_bundle_sha256(),
                   manifest.safe_tokenization.catalog_sha256
                 )
      end
    )
  end

  test "safe mode on falls back to legacy v2 and emits telemetry when manifest has no catalog" do
    {capture_executable, capture_file} = write_capture_request_executable!()

    on_exit(fn ->
      File.rm(capture_executable)
      File.rm(capture_file)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: capture_executable
      ],
      fn ->
        event_ref =
          attach_telemetry([
            :orchard,
            :tokenizer,
            :safe_tokenization,
            :degraded_no_manifest_catalog
          ])

        assert {:ok, %{rendered_prompt: "captured", input_token_count: 1}} =
                 Client.tokenize(canonical_request(),
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert {:ok, raw_request} = File.read(capture_file)

        assert %{"contract_version" => 2, "command" => "render_and_count"} =
                 Jason.decode!(raw_request)

        assert_receive {^event_ref, _event, %{count: 1}, metadata}
        assert metadata.degraded_reason == :no_manifest_catalog
        assert metadata.tokenizer_safe_mode == :on
      end
    )
  end

  test "safe mode reject fails closed when manifest has no catalog" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :reject,
        tokenizer_executable: "/missing/orchard-tokenizer"
      ],
      fn ->
        assert {:error, {:invalid_input, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "requires a manifest safe_tokenization catalog"
      end
    )
  end

  test "safe mode reject succeeds through segmented helper for compatible manifest" do
    fixture_root = fixture_root_with_tokenizer_config!()
    {capture_executable, capture_file} = write_capture_request_executable!(segmented_response())

    on_exit(fn ->
      File.rm(capture_executable)
      File.rm(capture_file)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :reject,
        tokenizer_executable: capture_executable
      ],
      fn ->
        assert {:ok, %{prompt_token_ids: [101, 102]}} =
                 Client.tokenize(canonical_request(),
                   manifest: safe_huggingface_manifest(config_path: "tokenizer_config.json"),
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert {:ok, raw_request} = File.read(capture_file)

        assert %{"contract_version" => 3, "command" => "render_and_count_segmented"} =
                 Jason.decode!(raw_request)
      end
    )
  end

  test "safe mode uses sibling tokenizer_config fallback and fails closed when absent" do
    fixture_root = fixture_root_with_tokenizer_config!()
    {capture_executable, capture_file} = write_capture_request_executable!(segmented_response())

    on_exit(fn ->
      File.rm(capture_executable)
      File.rm(capture_file)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: capture_executable
      ],
      fn ->
        assert {:ok, %{prompt_token_ids: [101, 102]}} =
                 Client.tokenize(canonical_request(),
                   manifest: safe_huggingface_manifest(),
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert {:ok, raw_request} = File.read(capture_file)
        request = Jason.decode!(raw_request)

        assert request["assets"]["tokenizer_config_path"] ==
                 realpath!(Path.join(fixture_root, "tokenizer_config.json"))
      end
    )

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: capture_executable
      ],
      fn ->
        assert {:error, {:missing_assets, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: safe_huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "tokenizer.config_path"
      end
    )
  end

  test "safe mode short-circuits cached incompatibility before helper dispatch" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = safe_huggingface_manifest()

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    assert :ok =
             CompatibilityCache.put_incompatible(
               trusted_bundle_sha256(),
               manifest.safe_tokenization.catalog_sha256,
               %{
                 "category" => "safe_tokenization_incompatible_template"
               }
             )

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: "/missing/orchard-tokenizer"
      ],
      fn ->
        assert {:error, {:safe_tokenization_incompatible_template, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "cached safe-tokenization incompatibility"
      end
    )
  end

  test "safe mode fails closed for cached template_compatible false verdict" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = safe_huggingface_manifest()

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    assert :ok =
             CompatibilityCache.put_compatible(
               trusted_bundle_sha256(),
               manifest.safe_tokenization.catalog_sha256,
               %{template_compatible: false}
             )

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :reject,
        tokenizer_executable: "/missing/orchard-tokenizer"
      ],
      fn ->
        assert {:error, {:safe_tokenization_incompatible_template, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "cached safe-tokenization template incompatibility"
      end
    )
  end

  test "safe mode fails closed and caches valid helper template incompatibility" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")

    reason = %{
      "category" => "dual_render_mismatch",
      "leaf_class" => "messages[0].content",
      "sentinel_index" => 0,
      "first_diff_offset" => 0
    }

    response_executable =
      write_response_executable!(
        segmented_response(%{
          compatible: false,
          template_compatible: false,
          incompatibility_reason: reason
        })
      )

    on_exit(fn ->
      File.rm(response_executable)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: response_executable
      ],
      fn ->
        assert {:error, {:safe_tokenization_incompatible_template, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "helper returned incompatible"

        assert {:incompatible, ^reason} =
                 CompatibilityCache.get(
                   trusted_bundle_sha256(),
                   manifest.safe_tokenization.catalog_sha256
                 )
      end
    )
  end

  test "safe mode caches only tokenizer and template incompatibility helper errors" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")

    template_error_executable =
      write_response_executable!(
        segmented_error_response("safe_tokenization_incompatible_template")
      )

    marker_error_executable =
      write_response_executable!(segmented_error_response("safe_tokenization_marker_collision"))

    on_exit(fn ->
      File.rm(template_error_executable)
      File.rm(marker_error_executable)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: template_error_executable
      ],
      fn ->
        assert {:error, {:safe_tokenization_incompatible_template, _message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert {:incompatible,
                %{
                  "category" => "dual_render_mismatch",
                  "outer_category" => "safe_tokenization_incompatible_template"
                }} =
                 CompatibilityCache.get(
                   trusted_bundle_sha256(),
                   manifest.safe_tokenization.catalog_sha256
                 )
      end
    )

    CompatibilityCache.clear()

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: marker_error_executable
      ],
      fn ->
        assert {:error, {:safe_tokenization_marker_collision, _message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert :unknown =
                 CompatibilityCache.get(
                   trusted_bundle_sha256(),
                   manifest.safe_tokenization.catalog_sha256
                 )
      end
    )
  end

  test "safe mode caches helper template error preserving inner reason and outer category" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")

    response_executable =
      write_response_executable!(%{
        contract_version: 3,
        ok: false,
        error: %{
          category: "safe_tokenization_incompatible_template",
          message: "segmented helper failed",
          details: %{
            "reason" => %{
              "category" => "dual_render_mismatch",
              "leaf_class" => "messages[0].content",
              "sentinel_index" => 0,
              "first_diff_offset" => 0
            }
          }
        }
      })

    on_exit(fn ->
      File.rm(response_executable)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: response_executable
      ],
      fn ->
        assert {:error, {:safe_tokenization_incompatible_template, _message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert {:incompatible,
                %{
                  "category" => "dual_render_mismatch",
                  "outer_category" => "safe_tokenization_incompatible_template",
                  "leaf_class" => "messages[0].content",
                  "sentinel_index" => 0,
                  "first_diff_offset" => 0
                }} =
                 CompatibilityCache.get(
                   trusted_bundle_sha256(),
                   manifest.safe_tokenization.catalog_sha256
                 )
      end
    )
  end

  describe "runtime error-envelope diagnostics" do
    test "caches per-codepoint decode mismatch details without requiring verdict literal" do
      fixture_root = fixture_root_with_tokenizer_config!()
      manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")

      response_executable =
        write_response_executable!(%{
          contract_version: 3,
          ok: false,
          error: %{
            category: "safe_tokenization_incompatible_tokenizer",
            message: "segmented token IDs do not decode to the rendered prompt",
            details: %{
              # cli.py:515-523 emits this runtime envelope without the verdict literal field.
              "reason" => %{
                "category" => "per_codepoint_decode_mismatch",
                "first_diff_offset" => 4
              }
            }
          }
        })

      on_exit(fn ->
        File.rm(response_executable)
        File.rm_rf!(fixture_root)
      end)

      with_inference_overrides(
        [
          tokenizer_mode: :port,
          tokenizer_safe_mode: :on,
          tokenizer_executable: response_executable
        ],
        fn ->
          assert {:error,
                  {:safe_tokenization_incompatible_tokenizer,
                   "segmented token IDs do not decode to the rendered prompt"}} =
                   Client.tokenize(canonical_request(),
                     manifest: manifest,
                     bundle_root: fixture_root,
                     bundle_sha256: trusted_bundle_sha256()
                   )

          assert {:incompatible,
                  %{
                    "category" => "per_codepoint_decode_mismatch",
                    "outer_category" => "safe_tokenization_incompatible_tokenizer",
                    "first_diff_offset" => 4
                  }} =
                   CompatibilityCache.get(
                     trusted_bundle_sha256(),
                     manifest.safe_tokenization.catalog_sha256
                   )
        end
      )
    end

    test "caches dual-render guard details without requiring verdict leaf metadata" do
      fixture_root = fixture_root_with_tokenizer_config!()
      manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")

      response_executable =
        write_response_executable!(%{
          contract_version: 3,
          ok: false,
          error: %{
            category: "safe_tokenization_incompatible_template",
            message: "tagged render diverged from baseline render",
            details: %{
              # cli.py:494 can raise a request-local runtime envelope before verdict metadata exists.
              "reason" => %{
                "category" => "dual_render_mismatch",
                "first_diff_offset" => 9
              }
            }
          }
        })

      on_exit(fn ->
        File.rm(response_executable)
        File.rm_rf!(fixture_root)
      end)

      with_inference_overrides(
        [
          tokenizer_mode: :port,
          tokenizer_safe_mode: :on,
          tokenizer_executable: response_executable
        ],
        fn ->
          assert {:error,
                  {:safe_tokenization_incompatible_template,
                   "tagged render diverged from baseline render"}} =
                   Client.tokenize(canonical_request(),
                     manifest: manifest,
                     bundle_root: fixture_root,
                     bundle_sha256: trusted_bundle_sha256()
                   )

          assert {:incompatible,
                  %{
                    "category" => "dual_render_mismatch",
                    "outer_category" => "safe_tokenization_incompatible_template",
                    "first_diff_offset" => 9
                  }} =
                   CompatibilityCache.get(
                     trusted_bundle_sha256(),
                     manifest.safe_tokenization.catalog_sha256
                   )
        end
      )
    end
  end

  test "safe mode maps cached direct dual_render_mismatch to template incompatibility" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = safe_huggingface_manifest()

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    assert :ok =
             CompatibilityCache.put_incompatible(
               trusted_bundle_sha256(),
               manifest.safe_tokenization.catalog_sha256,
               %{
                 "category" => "dual_render_mismatch",
                 "leaf_class" => "messages[0].content",
                 "sentinel_index" => 0,
                 "first_diff_offset" => 0
               }
             )

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: "/missing/orchard-tokenizer"
      ],
      fn ->
        assert {:error, {:safe_tokenization_incompatible_template, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "cached safe-tokenization incompatibility"
      end
    )
  end

  test "safe mode maps cached incompatibility using outer_category when present" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = safe_huggingface_manifest()

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    assert :ok =
             CompatibilityCache.put_incompatible(
               trusted_bundle_sha256(),
               manifest.safe_tokenization.catalog_sha256,
               %{
                 "category" => "marker_walk_mismatch",
                 "outer_category" => "safe_tokenization_incompatible_template"
               }
             )

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: "/missing/orchard-tokenizer"
      ],
      fn ->
        assert {:error, {:safe_tokenization_incompatible_template, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "cached safe-tokenization incompatibility"
      end
    )
  end

  test "safe mode caches inner reason category and outer classification for template_compatible false" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")

    response_executable =
      write_response_executable!(
        segmented_response(%{
          compatible: false,
          template_compatible: false,
          incompatibility_reason: %{
            "category" => "dual_render_mismatch",
            "outer_category" => "safe_tokenization_incompatible_template",
            "leaf_class" => "messages[0].content",
            "sentinel_index" => 0,
            "first_diff_offset" => 0
          }
        })
      )

    on_exit(fn ->
      File.rm(response_executable)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: response_executable
      ],
      fn ->
        assert {:error, {:safe_tokenization_incompatible_template, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "helper returned incompatible"

        assert {:incompatible,
                %{
                  "category" => "dual_render_mismatch",
                  "outer_category" => "safe_tokenization_incompatible_template",
                  "leaf_class" => "messages[0].content",
                  "sentinel_index" => 0,
                  "first_diff_offset" => 0
                }} =
                 CompatibilityCache.get(
                   trusted_bundle_sha256(),
                   manifest.safe_tokenization.catalog_sha256
                 )
      end
    )
  end

  test "safe mode rejects malformed segmented success verdicts without caching" do
    fixture_root = fixture_root_with_tokenizer_config!()
    manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    invalid_results = [
      {"compatible true but template incompatible",
       %{
         compatible: true,
         template_compatible: false,
         incompatibility_reason: nil
       }},
      {"compatible false without reason",
       %{
         compatible: false,
         template_compatible: true,
         incompatibility_reason: nil
       }},
      {"unknown reason category",
       %{
         compatible: false,
         template_compatible: true,
         incompatibility_reason: %{"category" => "unknown"}
       }},
      {"dual render reason marked template compatible",
       %{
         compatible: false,
         template_compatible: true,
         incompatibility_reason: %{
           "category" => "dual_render_mismatch",
           "leaf_class" => "messages[0].content",
           "sentinel_index" => 0,
           "first_diff_offset" => 0
         }
       }},
      {"tokenizer reason marked template incompatible",
       %{
         compatible: false,
         template_compatible: false,
         incompatibility_reason: %{
           "category" => "reserved_id_persists",
           "literal" => "<|im_start|>"
         }
       }},
      {"dual render reason missing sentinel index",
       %{
         compatible: false,
         template_compatible: false,
         incompatibility_reason: %{
           "category" => "dual_render_mismatch",
           "leaf_class" => "messages[0].content",
           "first_diff_offset" => 0
         }
       }},
      {"tokenizer reason missing literal",
       %{
         compatible: false,
         template_compatible: true,
         incompatibility_reason: %{"category" => "reserved_id_persists"}
       }},
      {"empty literal reason has non-empty literal",
       %{
         compatible: false,
         template_compatible: true,
         incompatibility_reason: %{"category" => "empty_literal", "literal" => "<not-empty>"}
       }}
    ]

    for {case_label, result_overrides} <- invalid_results do
      CompatibilityCache.clear()
      response_executable = write_response_executable!(segmented_response(result_overrides))

      try do
        with_inference_overrides(
          [
            tokenizer_mode: :port,
            tokenizer_safe_mode: :on,
            tokenizer_executable: response_executable
          ],
          fn ->
            result =
              Client.tokenize(canonical_request(),
                manifest: manifest,
                bundle_root: fixture_root,
                bundle_sha256: trusted_bundle_sha256()
              )

            assert result == {:error, :invalid_response}, case_label

            assert :unknown =
                     CompatibilityCache.get(
                       trusted_bundle_sha256(),
                       manifest.safe_tokenization.catalog_sha256
                     )
          end
        )
      after
        File.rm(response_executable)
      end
    end
  end

  test "safe mode rejects segmented success missing compatible" do
    fixture_root = fixture_root_with_tokenizer_config!()

    manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")

    response =
      segmented_response()
      |> Map.update!(:result, &Map.delete(&1, :compatible))

    response_executable = write_response_executable!(response)

    on_exit(fn ->
      File.rm(response_executable)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: response_executable
      ],
      fn ->
        assert {:error, :invalid_response} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )
      end
    )
  end

  test "safe mode rejects segmented success missing template_compatible" do
    fixture_root = fixture_root_with_tokenizer_config!()

    manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")

    response =
      segmented_response()
      |> Map.update!(:result, &Map.delete(&1, :template_compatible))

    response_executable = write_response_executable!(response)

    on_exit(fn ->
      File.rm(response_executable)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: response_executable
      ],
      fn ->
        assert {:error, :invalid_response} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )
      end
    )
  end

  test "safe mode rejects segmented success with compatible true and incompatibility reason" do
    fixture_root = fixture_root_with_tokenizer_config!()

    manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")

    response_executable =
      write_response_executable!(
        segmented_response(%{
          incompatibility_reason: %{
            "category" => "reserved_id_persists",
            "literal" => "<|im_start|>"
          }
        })
      )

    on_exit(fn ->
      File.rm(response_executable)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: response_executable
      ],
      fn ->
        assert {:error, :invalid_response} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )
      end
    )
  end

  test "safe mode rejects segmented success with non-boolean compatible verdict" do
    fixture_root = fixture_root_with_tokenizer_config!()

    manifest = safe_huggingface_manifest(config_path: "tokenizer_config.json")

    response_executable =
      write_response_executable!(
        segmented_response(%{
          compatible: "true",
          template_compatible: true,
          incompatibility_reason: nil
        })
      )

    on_exit(fn ->
      File.rm(response_executable)
      File.rm_rf!(fixture_root)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_safe_mode: :on,
        tokenizer_executable: response_executable
      ],
      fn ->
        assert {:error, :invalid_response} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )
      end
    )
  end

  test "port mode forwards tools and tool_choice into template context" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        request =
          canonical_request(
            tooling: %{
              tools: [tool("lookup_weather")],
              tool_choice: %{"type" => "function", "function" => %{"name" => "lookup_weather"}}
            }
          )

        assert {:ok, %{rendered_prompt: rendered_prompt, input_token_count: input_token_count}} =
                 Client.tokenize(request,
                   manifest: tools_template_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert rendered_prompt =~ "tools_defined=True tools_len=1 tool_choice_is_none=False"
        assert rendered_prompt =~ "tool lookup_weather"
        assert is_integer(input_token_count)
        assert input_token_count > 0
      end
    )
  end

  test "port mode emits control-token telemetry for message content hits" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])

        request =
          canonical_request(%{
            input_items: [
              %{role: "system", content: "orchard"},
              %{role: "user", content: "hello <|im_start|>"}
            ]
          })

        assert {:ok,
                %{
                  rendered_prompt: "system orchard\nuser hello <|im_start|>\nassistant",
                  input_token_count: 6
                }} =
                 Client.tokenize(request,
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert_receive {^event_ref, _event, %{count: 1}, metadata}
        assert metadata.model_id == "mlx-community/phi-3"
        assert metadata.endpoint == :chat_completions
        assert metadata.bundle_id == String.duplicate("a", 64)
        assert metadata.provenance_paths == ["messages[1].content"]
        assert metadata.literals == ["<|im_start|>"]
        assert metadata.partial_detection == true

        assert metadata.missing_catalog_sources == [
                 :chat_template_literals,
                 :wrapper_tool_markers
               ]

        assert metadata.truncated == false
      end
    )
  end

  test "port mode does not emit control-token telemetry for valid message roles" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])

        request =
          canonical_request(%{
            input_items: [
              %{role: "system", content: "orchard"},
              %{role: "user", content: "hello orchard"}
            ]
          })

        assert {:ok, %{rendered_prompt: rendered_prompt, input_token_count: input_token_count}} =
                 Client.tokenize(request,
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert rendered_prompt =~ "user hello orchard"
        assert input_token_count > 0

        refute_receive {^event_ref, _event, _measurements, _metadata}, 100
      end
    )
  end

  test "port mode rejects unsupported message roles before telemetry or helper dispatch" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])

        request =
          canonical_request(%{
            input_items: [
              %{role: "system", content: "orchard"},
              %{role: "<|im_start|>", content: "hello orchard"}
            ]
          })

        assert {:error, {:invalid_input, message}} =
                 Client.tokenize(request,
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "input_items[1].role is unsupported"
        refute_receive {^event_ref, _event, _measurements, _metadata}, 100
      end
    )
  end

  test "port mode emits control-token telemetry for message name hits" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])

        request =
          canonical_request(%{
            input_items: [
              %{role: "system", content: "orchard"},
              %{role: "user", name: "caller_<|im_start|>", content: "hello orchard"}
            ]
          })

        assert {:ok, %{rendered_prompt: rendered_prompt, input_token_count: input_token_count}} =
                 Client.tokenize(request,
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert rendered_prompt =~ "user hello orchard"
        assert input_token_count > 0

        assert_receive {^event_ref, _event, %{count: 1}, metadata}
        assert metadata.provenance_paths == ["messages[1].name"]
        assert metadata.literals == ["<|im_start|>"]
      end
    )
  end

  test "port mode emits control-token telemetry for inline tool function name hits" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])

        request =
          canonical_request(
            tooling: %{
              tools: [tool("<|im_end|>")],
              tool_choice: "auto"
            }
          )

        assert {:ok, %{rendered_prompt: rendered_prompt, input_token_count: input_token_count}} =
                 Client.tokenize(request,
                   manifest: tools_template_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert rendered_prompt =~ "tool <|im_end|>"
        assert is_integer(input_token_count)
        assert input_token_count > 0

        assert_receive {^event_ref, _event, %{count: 1}, metadata}
        assert metadata.provenance_paths == ["tools[0].function.name"]
        assert metadata.literals == ["<|im_end|>"]
      end
    )
  end

  test "port mode emits control-token telemetry for top-level tool type hits" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])

        request =
          canonical_request(
            tooling: %{
              tools: [%{"type" => "<|im_start|>", "function" => %{"name" => "lookup_weather"}}],
              tool_choice: "auto"
            }
          )

        assert {:ok, %{rendered_prompt: rendered_prompt, input_token_count: input_token_count}} =
                 Client.tokenize(request,
                   manifest: tools_template_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert rendered_prompt =~ "tool_type <|im_start|>"
        assert input_token_count > 0

        assert_receive {^event_ref, _event, %{count: 1}, metadata}
        assert metadata.provenance_paths == ["tools[0].type"]
        assert metadata.literals == ["<|im_start|>"]
      end
    )
  end

  test "port mode emits control-token telemetry for string tool_choice hits" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])

        request =
          canonical_request(
            tooling: %{
              tools: [tool("lookup_weather")],
              tool_choice: "<|im_end|>"
            }
          )

        assert {:ok, %{rendered_prompt: rendered_prompt, input_token_count: input_token_count}} =
                 Client.tokenize(request,
                   manifest: tools_template_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert rendered_prompt =~ "tool_choice <|im_end|>"
        assert input_token_count > 0

        assert_receive {^event_ref, _event, %{count: 1}, metadata}
        assert metadata.provenance_paths == ["tool_choice"]
        assert metadata.literals == ["<|im_end|>"]
      end
    )
  end

  test "port mode emits control-token telemetry for map tool_choice type hits" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])

        request =
          canonical_request(
            tooling: %{
              tools: [tool("lookup_weather")],
              tool_choice: %{
                "type" => "<|im_start|>",
                "function" => %{"name" => "lookup_weather"}
              }
            }
          )

        assert {:ok, %{rendered_prompt: rendered_prompt, input_token_count: input_token_count}} =
                 Client.tokenize(request,
                   manifest: tools_template_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert rendered_prompt =~ "tool_choice"
        assert rendered_prompt =~ "<|im_start|>"
        assert input_token_count > 0

        assert_receive {^event_ref, _event, %{count: 1}, metadata}
        assert metadata.provenance_paths == ["tool_choice.type"]
        assert metadata.literals == ["<|im_start|>"]
      end
    )
  end

  test "port mode emits structural provenance for schema property key hits" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])
        property_key = "customer_secret_<|im_start|>"

        request =
          canonical_request(
            tooling: %{
              tools: [
                %{
                  "type" => "function",
                  "function" => %{
                    "name" => "lookup_weather",
                    "parameters" => %{
                      "type" => "object",
                      "properties" => %{property_key => %{"description" => "target city"}}
                    }
                  }
                }
              ],
              tool_choice: "auto"
            }
          )

        assert {:ok, %{input_token_count: input_token_count}} =
                 Client.tokenize(request,
                   manifest: tools_template_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert input_token_count > 0
        assert_receive {^event_ref, _event, %{count: 1}, metadata}
        assert metadata.provenance_paths == ["tools[0].function.parameters.properties[0].__key__"]
        refute Enum.any?(metadata.provenance_paths, &String.contains?(&1, property_key))
      end
    )
  end

  test "port mode does not count template-emitted control tokens as caller content" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])

        assert {:ok, %{rendered_prompt: rendered_prompt, input_token_count: input_token_count}} =
                 Client.tokenize(canonical_request(),
                   manifest: control_template_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert rendered_prompt =~ "<|im_start|>"
        assert rendered_prompt =~ "<|im_end|>"
        assert is_integer(input_token_count)
        assert input_token_count > 0
        refute_receive {^event_ref, _event, _measurements, _metadata}, 50
      end
    )
  end

  test "port mode preserves tokenizer hits when tokenizer_config is malformed" do
    fixture_root = write_fixture_with_malformed_tokenizer_config!()

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        error_ref = attach_telemetry([:orchard, :tokenizer, :detector_error])
        hit_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])

        request =
          canonical_request(%{
            input_items: [
              %{role: "system", content: "orchard"},
              %{role: "user", content: "hello <|im_start|>"}
            ]
          })

        assert {:ok,
                %{
                  rendered_prompt: "system orchard\nuser hello <|im_start|>\nassistant",
                  input_token_count: 6
                }} =
                 Client.tokenize(request,
                   manifest: huggingface_manifest(),
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert_receive {^error_ref, _event, %{count: 1}, error_metadata}
        assert error_metadata.error_category == :tokenizer_config
        assert error_metadata.error_detail == :invalid_json
        assert error_metadata.reason == "tokenizer_config.invalid_json"
        refute inspect(error_metadata) =~ "NOT JSON"
        assert error_metadata.partial_detection == true

        assert error_metadata.missing_catalog_sources == [
                 :chat_template_literals,
                 :wrapper_tool_markers
               ]

        assert_receive {^hit_ref, _event, %{count: 1}, hit_metadata}
        assert hit_metadata.provenance_paths == ["messages[1].content"]
        assert hit_metadata.literals == ["<|im_start|>"]
      end
    )
  end

  test "port mode skips escaped tokenizer_config without suppressing tokenizer hits" do
    {fixture_root, outside_root} = write_fixture_with_escaped_tokenizer_config!()

    on_exit(fn -> File.rm_rf!(Path.dirname(fixture_root)) end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        error_ref = attach_telemetry([:orchard, :tokenizer, :detector_error])
        hit_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])

        request =
          canonical_request(%{
            input_items: [
              %{role: "system", content: "orchard"},
              %{role: "user", content: "hello <|im_start|> <outside_secret>"}
            ]
          })

        assert {:ok, %{rendered_prompt: rendered_prompt, input_token_count: input_token_count}} =
                 Client.tokenize(request,
                   manifest: huggingface_manifest(),
                   bundle_root: fixture_root,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert rendered_prompt =~ "<outside_secret>"
        assert input_token_count > 0

        assert_receive {^error_ref, _event, %{count: 1}, error_metadata}
        assert error_metadata.error_category == :tokenizer_config
        assert error_metadata.error_detail == :asset_escapes_tokenizer_root
        assert error_metadata.reason == "tokenizer_config.asset_escapes_tokenizer_root"
        refute inspect(error_metadata) =~ outside_root

        assert_receive {^hit_ref, _event, %{count: 1}, hit_metadata}
        assert hit_metadata.provenance_paths == ["messages[1].content"]
        assert hit_metadata.literals == ["<|im_start|>"]
      end
    )
  end

  test "port mode reports sanitized detector exceptions without blocking tokenization" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :detector_error])

        assert {:ok,
                %{
                  rendered_prompt: "system orchard\nuser hello orchard\nassistant",
                  input_token_count: 6
                }} =
                 Client.tokenize(canonical_request(),
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   control_token_detector: RaisingControlTokenDetector
                 )

        assert_receive {^event_ref, _event, %{count: 1}, metadata}
        assert metadata.error_category == :detector_runtime
        assert metadata.error_detail == :exception
        assert metadata.reason == "detector_runtime.exception"
        refute inspect(metadata) =~ "secret"
        refute inspect(metadata) =~ "/tmp/caller-data"
      end
    )
  end

  test "port mode reports sanitized detector throws without blocking tokenization" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :detector_error])

        assert {:ok,
                %{
                  rendered_prompt: "system orchard\nuser hello orchard\nassistant",
                  input_token_count: 6
                }} =
                 Client.tokenize(canonical_request(),
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   control_token_detector: ThrowingControlTokenDetector
                 )

        assert_receive {^event_ref, _event, %{count: 1}, metadata}
        assert metadata.error_category == :detector_runtime
        assert metadata.error_detail == :caught_throw
        assert metadata.reason == "detector_runtime.caught_throw"
        refute inspect(metadata) =~ "secret"
        refute inspect(metadata) =~ "/tmp/caller-data"
      end
    )
  end

  test "port mode skips detector for unsupported tokenizer kinds without detector error noise" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :detector_error])

        manifest =
          put_in(huggingface_manifest().tokenizer.kind, "sentencepiece")

        assert {:error, {:unsupported_tokenizer, _message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        refute_receive {^event_ref, _event, _measurements, _metadata}, 50
      end
    )
  end

  test "port mode bounds control-token telemetry literals when truncated" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])
        repeated_literal = Enum.map_join(1..17, " ", fn _index -> "<|im_start|>" end)

        request =
          canonical_request(%{
            input_items: [
              %{role: "system", content: "orchard"},
              %{role: "user", content: repeated_literal}
            ]
          })

        assert {:ok, %{input_token_count: input_token_count}} =
                 Client.tokenize(request,
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert input_token_count > 0
        assert_receive {^event_ref, _event, %{count: 17}, metadata}
        assert length(metadata.literals) == 16
        assert metadata.truncated == true
      end
    )
  end

  test "port mode bounds oversized literal telemetry metadata" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        event_ref = attach_telemetry([:orchard, :tokenizer, :control_token_in_user_content])
        oversized_literal = "<|" <> String.duplicate("x", 100) <> "|>"

        assert {:ok, %{input_token_count: input_token_count}} =
                 Client.tokenize(canonical_request(),
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   control_token_detector: OversizedLiteralControlTokenDetector
                 )

        assert input_token_count > 0
        assert_receive {^event_ref, _event, %{count: 1}, metadata}
        assert metadata.provenance_paths == ["messages[0].content"]
        assert metadata.literals == [String.slice(oversized_literal, 0, 64)]
        assert metadata.literal_byte_sizes == [byte_size(oversized_literal)]
        assert metadata.literal_families == [:angle_pipe]
        assert metadata.literal_metadata_max_bytes == 64
        assert metadata.literal_truncated == true
        refute inspect(metadata) =~ oversized_literal
      end
    )
  end

  test "port mode maps missing tokenizer assets to a stable error category" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        request = canonical_request()

        assert {:error, {:missing_assets, message}} =
                 Client.tokenize(request,
                   manifest: missing_asset_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "tokenizer"
      end
    )
  end

  test "port mode returns unavailable when the executable is missing" do
    missing_executable = Path.join(System.tmp_dir!(), "orchard-tokenizer-missing")

    with_inference_overrides(
      [tokenizer_mode: :port, tokenizer_executable: missing_executable],
      fn ->
        assert {:error, :unavailable} =
                 Client.tokenize(canonical_request(),
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )
      end
    )
  end

  test "port mode returns timeout when the executable does not finish in time" do
    slow_executable = write_sleeping_executable!()

    on_exit(fn ->
      File.rm(slow_executable)
    end)

    with_inference_overrides([tokenizer_mode: :port, tokenizer_executable: slow_executable], fn ->
      assert {:error, :timeout} =
               Client.tokenize(canonical_request(),
                 manifest: huggingface_manifest(),
                 bundle_root: huggingface_fixture_root(),
                 timeout_ms: 25
               )
    end)
  end

  test "port mode helper timeout is an absolute deadline" do
    dribbling_executable = write_dribbling_runtime_stdout_executable!()

    on_exit(fn ->
      File.rm(dribbling_executable)
    end)

    with_inference_overrides(
      [tokenizer_mode: :port, tokenizer_executable: dribbling_executable],
      fn ->
        {elapsed_us, result} =
          :timer.tc(fn ->
            Client.tokenize(canonical_request(),
              manifest: huggingface_manifest(),
              bundle_root: huggingface_fixture_root(),
              bundle_sha256: trusted_bundle_sha256(),
              timeout_ms: 200
            )
          end)

        assert {:error, :timeout} = result
        assert System.convert_time_unit(elapsed_us, :microsecond, :millisecond) < 350
      end
    )
  end

  test "port mode helper stdout is cumulatively capped" do
    oversized_executable = write_oversized_runtime_stdout_executable!()

    on_exit(fn ->
      File.rm(oversized_executable)
    end)

    with_inference_overrides(
      [tokenizer_mode: :port, tokenizer_executable: oversized_executable],
      fn ->
        assert {:error, {:stdout_too_large, 64}} =
                 Client.tokenize(canonical_request(),
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256(),
                   max_stdout_bytes: 64
                 )
      end
    )
  end

  test "port mode returns missing_assets when manifest tokenizer metadata is incomplete" do
    malformed_manifest = %{huggingface_manifest() | tokenizer: nil}

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        assert {:error, {:missing_assets, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: malformed_manifest,
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "tokenizer"
      end
    )
  end

  test "port mode rejects manifest without chat_template" do
    no_chat_template_manifest = %{huggingface_manifest() | chat_template: nil}

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        assert {:error, {:missing_assets, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: no_chat_template_manifest,
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "chat_template"
      end
    )
  end

  test "fake mode still succeeds without chat_template in manifest" do
    # Fake mode does not use manifest assets, so missing chat_template is fine
    assert {:ok,
            %{
              rendered_prompt: "system orchard\nuser hello orchard\nassistant",
              input_token_count: 6
            }} = Client.tokenize(canonical_request())
  end

  test "port mode rejects malformed executable output" do
    malformed_executable = write_malformed_executable!()

    on_exit(fn ->
      File.rm(malformed_executable)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: malformed_executable
      ],
      fn ->
        assert {:error, :invalid_response} =
                 Client.tokenize(canonical_request(),
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root(),
                   bundle_sha256: trusted_bundle_sha256()
                 )
      end
    )
  end

  test "port mode rejects symlinked assets that escape bundle_root" do
    # Create isolated temp directory with two siblings:
    # parent/
    #   bundle/        <- bundle_root
    #     tokenizer.json -> ../outside/tokenizer.json  (symlink escape)
    #     chat_template.jinja  (normal file)
    #   outside/
    #     tokenizer.json  (real file, outside bundle_root)
    parent_dir =
      Path.join(System.tmp_dir!(), "orchard-symlink-test-#{System.unique_integer([:positive])}")

    bundle_dir = Path.join(parent_dir, "bundle")
    outside_dir = Path.join(parent_dir, "outside")

    File.mkdir_p!(bundle_dir)
    File.mkdir_p!(outside_dir)

    on_exit(fn -> File.rm_rf!(parent_dir) end)

    # Create real tokenizer file outside bundle_root
    outside_tokenizer = Path.join(outside_dir, "tokenizer.json")
    File.write!(outside_tokenizer, "{\"model_type\": \"escaped\"}")

    # Create symlink inside bundle_root pointing outside
    symlink_path = Path.join(bundle_dir, "tokenizer.json")
    File.ln_s!(outside_tokenizer, symlink_path)

    # Create normal chat_template inside bundle_root
    File.write!(Path.join(bundle_dir, "chat_template.jinja"), "{{ content }}")

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        manifest = huggingface_manifest()

        assert {:error, {:invalid_input, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: bundle_dir,
                   bundle_sha256: trusted_bundle_sha256()
                 )

        assert message =~ "escapes bundle_root"
      end
    )
  end

  defp attach_telemetry(event) do
    parent = self()
    ref = make_ref()

    :telemetry.attach(
      inspect(ref),
      event,
      fn event, measurements, metadata, _config ->
        send(parent, {ref, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(inspect(ref)) end)
    ref
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

  defp with_app_env(key, value, fun) when is_function(fun, 0) do
    previous = Application.get_env(:orchard_controller, key, :orchard_missing_env)
    Application.put_env(:orchard_controller, key, value)

    try do
      fun.()
    after
      case previous do
        :orchard_missing_env -> Application.delete_env(:orchard_controller, key)
        previous_value -> Application.put_env(:orchard_controller, key, previous_value)
      end
    end
  end

  defp with_system_tmpdir(tmp_dir, fun) when is_binary(tmp_dir) and is_function(fun, 0) do
    previous_tmpdir = System.get_env("TMPDIR")
    System.put_env("TMPDIR", tmp_dir)

    try do
      fun.()
    after
      restore_tmpdir(previous_tmpdir)
    end
  end

  defp restore_tmpdir(nil), do: System.delete_env("TMPDIR")
  defp restore_tmpdir(previous_tmpdir), do: System.put_env("TMPDIR", previous_tmpdir)

  defp canonical_request(overrides \\ %{}) do
    base = %{
      internal_id: "req_internal_tokenizer_test",
      public_id: "req_tokenizer_test",
      endpoint: :chat_completions,
      tenant_id: "tenant_test",
      model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
      input_items: [
        %{role: "system", content: "orchard"},
        %{role: "user", content: [%{type: "text", text: "hello orchard"}]}
      ]
    }

    CanonicalRequest.new(Map.merge(base, Map.new(overrides)))
  end

  defp huggingface_manifest do
    manifest_with_chat_template("chat_template.jinja")
  end

  defp tools_template_manifest do
    manifest_with_chat_template("chat_template_tools.jinja")
  end

  defp control_template_manifest do
    manifest_with_chat_template("chat_template_control.jinja")
  end

  defp safe_huggingface_manifest(opts \\ []) do
    base = huggingface_manifest()
    %Tokenizer{} = tokenizer = base.tokenizer
    config_path = Keyword.get(opts, :config_path)

    %ModelManifest{
      base
      | tokenizer: %Tokenizer{tokenizer | config_path: config_path},
        safe_tokenization: safe_tokenization()
    }
  end

  defp explicit_preflight_compatible_manifest(opts \\ []) do
    safe_huggingface_manifest(opts)
    |> put_safe_tokenization(%{
      compatible: true,
      template_compatible: true,
      preflight_compatible_declared?: true
    })
  end

  defp manifest_declared_incompatible do
    safe_huggingface_manifest()
    |> put_safe_tokenization(%{
      compatible: false,
      template_compatible: true,
      incompatibility_reason: %SafeTokenization.IncompatibilityReason{
        category: "reserved_id_persists",
        literal: "<|im_start|>"
      }
    })
  end

  defp put_safe_tokenization(
         %ModelManifest{safe_tokenization: safe_tokenization} = manifest,
         attrs
       ) do
    %ModelManifest{manifest | safe_tokenization: struct(safe_tokenization, attrs)}
  end

  defp safe_tokenization do
    %SafeTokenization{
      control_tokens: safe_control_tokens(),
      catalog_sha256: catalog_sha256(safe_control_tokens()),
      catalog_source: %SafeTokenization.CatalogSource{
        added_tokens_count: 2,
        config_singletons_count: 0,
        additional_special_tokens_count: 0,
        chat_template_literals_count: 0,
        wrapper_tool_markers_count: 0,
        extra_count: 0
      }
    }
  end

  defp safe_control_tokens, do: ["<|im_start|>", "<|im_end|>"]

  defp catalog_sha256(tokens) do
    :sha256
    |> :crypto.hash(Enum.join(tokens, <<0>>))
    |> Base.encode16(case: :lower)
  end

  defp trusted_bundle_sha256, do: String.duplicate("c", 64)

  defp manifest_with_chat_template(chat_template_path) do
    ModelManifest.new(%{
      model_id: "mlx-community/phi-3",
      version: "main",
      format: "mlx",
      artifact_layout: "directory",
      entrypoint: "weights/",
      sha256: String.duplicate("a", 64),
      max_context_tokens: 32_768,
      capabilities: ["chat"],
      tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "tokenizer.json"},
      chat_template: %ChatTemplate{
        path: chat_template_path,
        sha256: String.duplicate("b", 64)
      },
      runtime_requirements: %RuntimeRequirements{
        adapter: "mlx_lm",
        min_agent_capability: "mlx"
      }
    })
  end

  defp missing_asset_manifest do
    ModelManifest.new(%{
      model_id: "mlx-community/phi-3",
      version: "main",
      format: "mlx",
      artifact_layout: "directory",
      entrypoint: "weights/",
      sha256: String.duplicate("a", 64),
      max_context_tokens: 32_768,
      capabilities: ["chat"],
      tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "missing-tokenizer.json"},
      chat_template: %ChatTemplate{
        path: "chat_template.jinja",
        sha256: String.duplicate("b", 64)
      },
      runtime_requirements: %RuntimeRequirements{
        adapter: "mlx_lm",
        min_agent_capability: "mlx"
      }
    })
  end

  defp huggingface_fixture_root do
    Path.expand("../fixtures/tokenizer/minimal_hf", __DIR__)
  end

  defp tokenizer_executable do
    Client.executable()
  end

  defp unique_tmp_root!(prefix) do
    tmp_root = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_root)
    tmp_root
  end

  defp runtime_transport_dirs(tmp_root) do
    tmp_root
    |> Path.join("orchard-tokenizer-request-*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
  end

  defp realpath!(path) do
    {:ok, realpath} = Orchard.PathUtils.resolve_realpath(path)
    realpath
  end

  defp fixture_root_with_tokenizer_config! do
    fixture_root =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-safe-mode-#{System.unique_integer([:positive])}"
      )

    File.cp_r!(huggingface_fixture_root(), fixture_root)
    File.write!(Path.join(fixture_root, "tokenizer_config.json"), Jason.encode!(%{}))
    fixture_root
  end

  defp segmented_response(result_overrides \\ %{}) do
    result =
      Map.merge(
        %{
          rendered_prompt: "segmented",
          input_token_count: 2,
          prompt_token_ids: [101, 102],
          compatible: true,
          template_compatible: true,
          incompatibility_reason: nil,
          safe_encoding_events: []
        },
        result_overrides
      )

    %{
      contract_version: 3,
      ok: true,
      result: result
    }
  end

  defp segmented_error_response(category) do
    %{
      contract_version: 3,
      ok: false,
      error: %{
        category: category,
        message: "segmented helper failed",
        details: %{"reason" => %{"category" => "dual_render_mismatch"}}
      }
    }
  end

  defp write_fixture_with_malformed_tokenizer_config! do
    fixture_root =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-config-error-#{System.unique_integer([:positive])}"
      )

    File.cp_r!(huggingface_fixture_root(), fixture_root)
    File.write!(Path.join(fixture_root, "tokenizer_config.json"), "NOT JSON")
    fixture_root
  end

  defp write_fixture_with_escaped_tokenizer_config! do
    parent_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-config-escape-#{System.unique_integer([:positive])}"
      )

    fixture_root = Path.join(parent_dir, "bundle")
    outside_root = Path.join(parent_dir, "outside")

    File.mkdir_p!(parent_dir)
    File.cp_r!(huggingface_fixture_root(), fixture_root)
    File.mkdir_p!(outside_root)

    outside_config = Path.join(outside_root, "tokenizer_config.json")

    File.write!(
      outside_config,
      Jason.encode!(%{"additional_special_tokens" => ["<outside_secret>"]})
    )

    File.ln_s!(outside_config, Path.join(fixture_root, "tokenizer_config.json"))

    {fixture_root, outside_root}
  end

  defp write_runtime_transport_asserting_executable!(tmp_root) do
    probe_file =
      Path.join(
        tmp_root,
        "runtime-transport-probe-#{System.unique_integer([:positive])}.txt"
      )

    response =
      Jason.encode!(%{
        contract_version: 2,
        ok: true,
        result: %{rendered_prompt: "transport ok", input_token_count: 1}
      })

    script_path =
      Path.join(
        tmp_root,
        "orchard-tokenizer-runtime-transport-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(script_path, runtime_transport_asserting_script(probe_file, response))
    File.chmod!(script_path, 0o755)

    {script_path, probe_file}
  end

  defp runtime_transport_asserting_script(probe_file, response) do
    """
    #!/bin/sh
    set -eu

    tmp_root=${TMPDIR:-/tmp}
    transport_dirs=$(find "$tmp_root" -maxdepth 1 -type d -name 'orchard-tokenizer-request-*')
    transport_count=$(printf '%s\n' "$transport_dirs" | sed '/^$/d' | wc -l | tr -d ' ')

    if [ "$transport_count" != "1" ]; then
      printf 'expected one private transport directory, found %s\n' "$transport_count" > "#{probe_file}"
      exit 42
    fi

    request_dir=$(printf '%s\n' "$transport_dirs" | sed '/^$/d' | head -n 1)
    request_path="$request_dir/request.json"

    if [ ! -f "$request_path" ] || [ -L "$request_path" ]; then
      printf 'request.json missing, not a file, or symlink\n' > "#{probe_file}"
      exit 43
    fi

    dir_mode=$(stat -f '%Lp' "$request_dir" 2>/dev/null || stat -c '%a' "$request_dir")

    if [ "$dir_mode" != "700" ]; then
      printf 'unexpected directory mode %s\n' "$dir_mode" > "#{probe_file}"
      exit 44
    fi

    request_json=$(cat)

    case "$request_json" in
      *'"command":"render_and_count"'*) ;;
      *) printf 'unexpected request command\n' > "#{probe_file}"; exit 45 ;;
    esac

    printf 'ok\n' > "#{probe_file}"
    printf '%s\n' '#{response}'
    """
  end

  defp write_capture_request_executable!(response_map \\ legacy_capture_response()) do
    capture_file =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-captured-request-#{System.unique_integer([:positive])}.json"
      )

    response = Jason.encode!(response_map)

    script_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-capture-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(
      script_path,
      "#!/bin/sh\ncat > \"#{capture_file}\"\nprintf '%s\\n' '#{response}'\n"
    )

    File.chmod!(script_path, 0o755)
    {script_path, capture_file}
  end

  defp write_env_capture_executable!(response_map) do
    env_file =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-captured-env-#{System.unique_integer([:positive])}.txt"
      )

    response = Jason.encode!(response_map)

    script_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-env-capture-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(
      script_path,
      "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' \"${ORCHARD_TOKENIZER_SKIP_SENTINEL_PREFLIGHT:-}\" >> \"#{env_file}\"\nprintf '%s\\n' '#{response}'\n"
    )

    File.chmod!(script_path, 0o755)
    {script_path, env_file}
  end

  defp env_capture_lines(env_file) do
    env_file
    |> File.read!()
    |> String.split("\n", trim: false)
    |> Enum.drop(-1)
  end

  defp restore_skip_sentinel_preflight_env(nil) do
    System.delete_env("ORCHARD_TOKENIZER_SKIP_SENTINEL_PREFLIGHT")
  end

  defp restore_skip_sentinel_preflight_env(value) do
    System.put_env("ORCHARD_TOKENIZER_SKIP_SENTINEL_PREFLIGHT", value)
  end

  defp legacy_capture_response do
    %{
      contract_version: 2,
      ok: true,
      result: %{
        rendered_prompt: "captured",
        input_token_count: 1
      }
    }
  end

  defp write_response_executable!(response_map) do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-response-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(
      script_path,
      "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '#{Jason.encode!(response_map)}'\n"
    )

    File.chmod!(script_path, 0o755)
    script_path
  end

  defp write_sleeping_executable! do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-sleeping-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(script_path, "#!/bin/sh\nsleep 1\n")
    File.chmod!(script_path, 0o755)
    script_path
  end

  defp write_dribbling_runtime_stdout_executable! do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-dribbling-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(script_path, """
    #!/bin/sh
    perl -e '$| = 1; for (1..20) { print "x" x 1024; select(undef, undef, undef, 0.02); }' 2>/dev/null || true
    """)

    File.chmod!(script_path, 0o755)
    script_path
  end

  defp write_oversized_runtime_stdout_executable! do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-oversized-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(script_path, """
    #!/bin/sh
    cat >/dev/null
    printf '%s' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    printf '%s' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    printf '%s' 'c'
    """)

    File.chmod!(script_path, 0o755)
    script_path
  end

  defp tool(name) do
    %{"type" => "function", "function" => %{"name" => name}}
  end

  defp write_malformed_executable! do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-malformed-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(script_path, "#!/bin/sh\necho not-json\n")
    File.chmod!(script_path, 0o755)
    script_path
  end
end
