defmodule Orchard.Models.BundleBuilderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Orchard.Models.BundleBuilder
  alias Orchard.Models.ManifestParser

  @repo_id "mlx-community/test-model"
  @revision_sha "abc123def456789"
  @detail_metadata %{revision_sha: @revision_sha}

  setup do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("bundle_builder_test_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  # -- Happy-path: existing chat_template.jinja -----------------------------

  describe "prepare_bundle/3 with existing template" do
    test "uses existing chat_template.jinja and skips tokenizer_config extraction", ctx do
      template_content = "{% for msg in messages %}{{ msg.content }}{% endfor %}"

      write_minimal_bundle(ctx.tmp_dir,
        chat_template: template_content,
        tokenizer_config: %{"chat_template" => "SHOULD NOT BE USED"}
      )

      assert {:ok, dir} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      assert dir == ctx.tmp_dir

      # Template file unchanged
      assert File.read!(Path.join(ctx.tmp_dir, "chat_template.jinja")) == template_content

      # Manifest includes chat_template with correct SHA
      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.chat_template.path == "chat_template.jinja"
      expected_sha = :crypto.hash(:sha256, template_content) |> Base.encode16(case: :lower)
      assert manifest.chat_template.sha256 == expected_sha
    end

    test "uses existing chat_template.jinja2", ctx do
      template_content = "{% for msg in messages %}{{ msg.content }}{% endfor %}"

      write_minimal_bundle(ctx.tmp_dir,
        tokenizer_config: %{"add_bos_token" => true}
      )

      File.write!(Path.join(ctx.tmp_dir, "chat_template.jinja2"), template_content)

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.chat_template.path == "chat_template.jinja2"
    end
  end

  # -- Chat template extraction from tokenizer_config.json ------------------

  describe "chat template extraction" do
    test "extracts string chat_template from tokenizer_config.json", ctx do
      template_str = "{{ bos_token }}{% for msg in messages %}{{ msg.content }}{% endfor %}"

      write_minimal_bundle(ctx.tmp_dir,
        tokenizer_config: %{"chat_template" => template_str}
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      # Template written to file
      generated_path = Path.join(ctx.tmp_dir, "chat_template.jinja")
      assert File.read!(generated_path) == template_str

      # Manifest references it with correct SHA
      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.chat_template.path == "chat_template.jinja"
      expected_sha = :crypto.hash(:sha256, template_str) |> Base.encode16(case: :lower)
      assert manifest.chat_template.sha256 == expected_sha
    end

    test "extracts list-form chat_template, selecting 'default' entry", ctx do
      default_template = "DEFAULT TEMPLATE CONTENT"

      write_minimal_bundle(ctx.tmp_dir,
        tokenizer_config: %{
          "chat_template" => [
            %{"name" => "tool_use", "template" => "TOOL TEMPLATE"},
            %{"name" => "default", "template" => default_template},
            %{"name" => "rag", "template" => "RAG TEMPLATE"}
          ]
        }
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert File.read!(Path.join(ctx.tmp_dir, "chat_template.jinja")) == default_template
    end

    test "extracts list-form chat_template, falls back to first entry", ctx do
      first_template = "FIRST ENTRY TEMPLATE"

      write_minimal_bundle(ctx.tmp_dir,
        tokenizer_config: %{
          "chat_template" => [
            %{"name" => "tool_use", "template" => first_template},
            %{"name" => "rag", "template" => "RAG TEMPLATE"}
          ]
        }
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert File.read!(Path.join(ctx.tmp_dir, "chat_template.jinja")) == first_template
    end
  end

  # -- No template available (warning-only) ---------------------------------

  describe "missing chat template" do
    test "succeeds with warning when no template source available", ctx do
      write_minimal_bundle(ctx.tmp_dir)

      log =
        capture_log(fn ->
          assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
        end)

      assert log =~ "no chat template found"

      # Manifest valid without chat_template
      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.chat_template == nil

      # Raw JSON should not contain "chat_template" key
      raw = File.read!(Path.join(ctx.tmp_dir, "manifest.json")) |> Jason.decode!()
      refute Map.has_key?(raw, "chat_template")
    end

    test "warns when tokenizer_config.json exists but has no chat_template field", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        tokenizer_config: %{"add_bos_token" => true}
      )

      log =
        capture_log(fn ->
          assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
        end)

      assert log =~ "no chat template found"
    end
  end

  # -- Context-window precedence --------------------------------------------

  describe "context window extraction" do
    test "uses max_position_embeddings first", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        config: %{
          "model_type" => "llama",
          "max_position_embeddings" => 32_768,
          "n_positions" => 2048,
          "max_sequence_length" => 1024
        }
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.max_context_tokens == 32_768
    end

    test "falls back to n_positions", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        config: %{"model_type" => "gpt2", "n_positions" => 2048}
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.max_context_tokens == 2048
    end

    test "falls back to max_sequence_length as string", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        config: %{"model_type" => "custom", "max_sequence_length" => "4096"}
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.max_context_tokens == 4096
    end

    test "extracts context window from nested text_config (Gemma 3 VLM)", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        config: %{
          "model_type" => "gemma3",
          "architectures" => ["Gemma3ForConditionalGeneration"],
          "text_config" => %{
            "model_type" => "gemma3_text",
            "max_position_embeddings" => 131_072
          }
        }
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.max_context_tokens == 131_072
    end

    test "top-level context window takes precedence over text_config", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        config: %{
          "model_type" => "gemma3",
          "max_position_embeddings" => 8192,
          "text_config" => %{"max_position_embeddings" => 131_072}
        }
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.max_context_tokens == 8192
    end

    test "derives kv_cache_bytes_per_token from config.json", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        config: %{
          "max_position_embeddings" => 4096,
          "num_hidden_layers" => 24,
          "num_attention_heads" => 64,
          "num_key_value_heads" => 16,
          "head_dim" => 32,
          "torch_dtype" => "float16"
        }
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.kv_cache_bytes_per_token == 49_152
    end

    test "writes kv_cache_bytes_per_token=0 when estimate is unknown", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        config: %{
          "max_position_embeddings" => 4096,
          "num_attention_heads" => 64,
          "num_key_value_heads" => 16,
          "head_dim" => 32,
          "torch_dtype" => "float16"
        }
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.kv_cache_bytes_per_token == 0
    end

    test "derives kv_cache_bytes_per_token from nested text_config", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        config: %{
          "model_type" => "gemma3",
          "max_position_embeddings" => 4096,
          "text_config" => %{
            "num_hidden_layers" => 24,
            "num_attention_heads" => 64,
            "num_key_value_heads" => 16,
            "head_dim" => 32,
            "torch_dtype" => "fp16"
          }
        }
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.kv_cache_bytes_per_token == 49_152
    end

    test "derives SPEC.md §6.4 resident_memory_bytes from safetensors index metadata", ctx do
      write_minimal_bundle(ctx.tmp_dir)
      write_safetensors_index(ctx.tmp_dir, %{"metadata" => %{"total_size" => 6_442_450_944}})

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.resident_memory_bytes == 6_442_450_944
    end

    test "derives SPEC.md §6.4 resident_memory_bytes from safetensors file-size fallback", ctx do
      write_minimal_bundle(ctx.tmp_dir)
      File.write!(Path.join(ctx.tmp_dir, "model.safetensors.index.json"), "not json")

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.resident_memory_bytes == byte_size("fake-weights")
    end

    test "writes SPEC.md §6.4 resident_memory_bytes=0 when no source is usable", ctx do
      write_minimal_bundle(ctx.tmp_dir)
      File.rm!(Path.join(ctx.tmp_dir, "model.safetensors"))

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.resident_memory_bytes == 0
    end
  end

  # -- Size accounting -------------------------------------------------------

  describe "size accounting" do
    test "includes downloaded files and generated template, excludes manifest.json", ctx do
      config_content = ~s({"max_position_embeddings": 4096})
      tokenizer_content = ~s({"version": "1.0"})
      weights_content = String.duplicate("x", 1000)
      template_str = "template content here"

      write_minimal_bundle(ctx.tmp_dir,
        config: config_content,
        tokenizer: tokenizer_content,
        weights: weights_content,
        tokenizer_config: %{"chat_template" => template_str}
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)

      tokenizer_config_size =
        byte_size(Jason.encode!(%{"chat_template" => template_str}))

      expected_size =
        byte_size(config_content) +
          byte_size(tokenizer_content) +
          byte_size(weights_content) +
          byte_size(template_str) +
          tokenizer_config_size

      assert manifest.size_bytes == expected_size
    end
  end

  # -- Manifest round-trip validation ----------------------------------------

  describe "manifest round-trip" do
    test "generated manifest passes ManifestParser + ModelManifest validation", ctx do
      template = "{% for m in messages %}{{ m.content }}{% endfor %}"

      write_minimal_bundle(ctx.tmp_dir,
        chat_template: template,
        tokenizer_config: %{"add_bos_token" => true}
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.model_id == @repo_id
      assert manifest.version == @revision_sha
      assert manifest.format == "mlx"
      assert manifest.artifact_layout == "directory"
      assert manifest.entrypoint == "."
      assert manifest.sha256 == "pending"
      assert manifest.max_context_tokens > 0
      assert manifest.capabilities == ["chat"]
      assert manifest.tokenizer.kind == "huggingface_tokenizer_json"
      assert manifest.tokenizer.path == "tokenizer.json"
      assert manifest.runtime_requirements.adapter == "mlx_lm"
      assert manifest.runtime_requirements.min_agent_capability == "mlx"
      assert manifest.chat_template.path == "chat_template.jinja"
      assert is_binary(manifest.chat_template.sha256)
    end
  end

  # -- Safe tokenization catalog --------------------------------------------

  describe "safe tokenization catalog" do
    test "generates SPEC.md §6.4 effective catalog from tokenizer, config, template, and wrapper sources",
         ctx do
      copy_tokenizer_fixture!("qwen2_added_tokens", ctx.tmp_dir)

      helper =
        write_catalog_helper!(ctx.tmp_dir, %{
          "control_tokens_chat_template" => ["<template_only>", "<|im_start|>"],
          "control_tokens_wrapper_tool" => ["</tool_call>", "<tool_call>"],
          "chat_template_literals_count" => 2,
          "wrapper_tool_markers_count" => 2
        })

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.tokenizer.config_path == "tokenizer_config.json"

      assert manifest.safe_tokenization.control_tokens == [
               "</s>",
               "</tool_call>",
               "<extra_token>",
               "<s>",
               "<template_only>",
               "<tool_call>",
               "<|im_end|>",
               "<|im_start|>"
             ]

      assert manifest.safe_tokenization.catalog_sha256 ==
               hash_catalog(manifest.safe_tokenization.control_tokens)

      assert manifest.safe_tokenization.catalog_source.added_tokens_count == 2
      assert manifest.safe_tokenization.catalog_source.config_singletons_count == 2
      assert manifest.safe_tokenization.catalog_source.additional_special_tokens_count == 2
      assert manifest.safe_tokenization.catalog_source.chat_template_literals_count == 2
      assert manifest.safe_tokenization.catalog_source.wrapper_tool_markers_count == 2
      assert manifest.safe_tokenization.catalog_source.extra_count == 0

      raw = read_manifest_json!(ctx.tmp_dir)
      refute Map.has_key?(raw["safe_tokenization"], "compatible")
      refute Map.has_key?(raw["safe_tokenization"], "template_compatible")
      refute Map.has_key?(raw["safe_tokenization"], "incompatibility_reason")
    end

    test "records wrapper markers even when they are absent from added_tokens", ctx do
      copy_tokenizer_fixture!("wrapper_marker_only", ctx.tmp_dir)

      helper =
        write_catalog_helper!(ctx.tmp_dir, %{
          "control_tokens_chat_template" => [],
          "control_tokens_wrapper_tool" => ["</tool_call>", "<tool_call>"],
          "chat_template_literals_count" => 0,
          "wrapper_tool_markers_count" => 2
        })

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.safe_tokenization.control_tokens == ["</tool_call>", "<tool_call>"]
      assert manifest.safe_tokenization.catalog_source.added_tokens_count == 0
      assert manifest.safe_tokenization.catalog_source.wrapper_tool_markers_count == 2
    end

    test "extracts object-form additional_special_tokens without invoking helper", ctx do
      copy_tokenizer_fixture!("additional_special_tokens_object_form", ctx.tmp_dir)

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.safe_tokenization.control_tokens == ["<object_special>", "<string_special>"]
      assert manifest.safe_tokenization.catalog_source.additional_special_tokens_count == 2
      assert manifest.safe_tokenization.catalog_source.chat_template_literals_count == 0
      assert manifest.safe_tokenization.catalog_source.wrapper_tool_markers_count == 0
    end

    test "invokes helper for SPEC.md §6.4 bracket-style template without angle bracket",
         ctx do
      write_minimal_bundle(ctx.tmp_dir,
        chat_template: "[INST] {{ messages[0].content }} [/INST]",
        tokenizer_config: %{"add_bos_token" => true}
      )

      helper =
        write_catalog_helper!(ctx.tmp_dir, %{
          "control_tokens_chat_template" => ["[/INST]", "[INST]"],
          "control_tokens_wrapper_tool" => [],
          "chat_template_literals_count" => 4,
          "wrapper_tool_markers_count" => 0
        })

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.safe_tokenization.control_tokens == ["[/INST]", "[INST]"]
      assert manifest.safe_tokenization.catalog_source.chat_template_literals_count == 4
    end

    test "counts SPEC.md §6.4 local source observations before dedupe", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        tokenizer:
          Jason.encode!(%{
            "added_tokens" => [
              %{"content" => "<dup>"},
              %{"content" => "<dup>"},
              %{"content" => ""},
              %{"content" => "<added>"}
            ]
          }),
        tokenizer_config: %{
          "bos_token" => "<s>",
          "eos_token" => %{"content" => "<s>"},
          "additional_special_tokens" => [
            "<extra>",
            "<extra>",
            %{"content" => "<extra_obj>"},
            %{"content" => ""},
            123
          ]
        }
      )

      capture_log(fn ->
        assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)

      assert manifest.safe_tokenization.control_tokens == [
               "<added>",
               "<dup>",
               "<extra>",
               "<extra_obj>",
               "<s>"
             ]

      assert manifest.safe_tokenization.catalog_source.added_tokens_count == 3
      assert manifest.safe_tokenization.catalog_source.config_singletons_count == 2
      assert manifest.safe_tokenization.catalog_source.additional_special_tokens_count == 3
    end

    test "extracts template literals when chat template exists without tokenizer_config.json",
         ctx do
      write_minimal_bundle(ctx.tmp_dir,
        chat_template: "prefix <|template_without_config|> suffix"
      )

      helper =
        write_catalog_helper!(ctx.tmp_dir, %{
          "control_tokens_chat_template" => ["<|template_without_config|>"],
          "control_tokens_wrapper_tool" => [],
          "chat_template_literals_count" => 1,
          "wrapper_tool_markers_count" => 0
        })

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.tokenizer.config_path == nil
      assert manifest.chat_template.path == "chat_template.jinja"
      assert manifest.safe_tokenization.control_tokens == ["<|template_without_config|>"]
      assert manifest.safe_tokenization.catalog_source.chat_template_literals_count == 1
    end

    test "surfaces helper invalid_input for malformed jinja without angle bracket", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        tokenizer_config: %{"chat_template" => "{% if messages"}
      )

      helper =
        write_catalog_error_helper!(
          ctx.tmp_dir,
          "invalid_input",
          "chat template asset is invalid"
        )

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:error,
                {:safe_tokenization_helper_unavailable,
                 {:invalid_input, "chat template asset is invalid"}}} =
                 BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      refute File.exists?(Path.join(ctx.tmp_dir, "manifest.json"))
    end

    test "extracts wrapper markers when tokenizer_config has parser metadata but no template",
         ctx do
      write_minimal_bundle(ctx.tmp_dir,
        tokenizer_config: %{"tool_parser_type" => "qwen2"}
      )

      helper =
        write_catalog_helper!(ctx.tmp_dir, %{
          "control_tokens_chat_template" => [],
          "control_tokens_wrapper_tool" => ["</tool_call>", "<tool_call>"],
          "chat_template_literals_count" => 0,
          "wrapper_tool_markers_count" => 2
        })

      log =
        capture_log(fn ->
          with_inference_overrides([tokenizer_executable: helper], fn ->
            assert {:ok, _} =
                     BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
          end)
        end)

      assert log =~ "no chat template found"
      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.chat_template == nil
      assert manifest.safe_tokenization.control_tokens == ["</tool_call>", "<tool_call>"]
      assert manifest.safe_tokenization.catalog_source.wrapper_tool_markers_count == 2
    end

    test "skips malformed added_tokens entries that do not carry string content", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        tokenizer:
          Jason.encode!(%{
            "added_tokens" => [
              %{"content" => "<valid>"},
              %{"content" => ""},
              %{"content" => 123},
              %{"not_content" => "<missing>"},
              "not-an-object"
            ]
          })
      )

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.safe_tokenization.control_tokens == ["<valid>"]
      assert manifest.safe_tokenization.catalog_source.added_tokens_count == 1
    end

    test "aborts manifest write when safe-tokenization helper is unavailable", ctx do
      copy_tokenizer_fixture!("wrapper_marker_only", ctx.tmp_dir)
      missing_executable = Path.join(ctx.tmp_dir, "missing-helper")

      with_inference_overrides([tokenizer_executable: missing_executable], fn ->
        assert {:error, {:safe_tokenization_helper_unavailable, :unavailable}} =
                 BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      refute File.exists?(Path.join(ctx.tmp_dir, "manifest.json"))
    end

    test "aborts manifest write when safe-tokenization helper times out", ctx do
      copy_tokenizer_fixture!("wrapper_marker_only", ctx.tmp_dir)
      helper = write_sleeping_catalog_helper!(ctx.tmp_dir)

      with_app_env(:bundle_build_catalog_timeout_ms, 10, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:error, {:safe_tokenization_helper_unavailable, :timeout}} =
                   BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
        end)
      end)

      refute File.exists?(Path.join(ctx.tmp_dir, "manifest.json"))
    end

    test "rejects helper source count without emitted tokens", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        chat_template: "plain template",
        tokenizer_config: %{"add_bos_token" => true}
      )

      helper =
        write_catalog_helper!(ctx.tmp_dir, %{
          "control_tokens_chat_template" => [],
          "control_tokens_wrapper_tool" => [],
          "chat_template_literals_count" => 1,
          "wrapper_tool_markers_count" => 0
        })

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:error, {:safe_tokenization_helper_unavailable, :invalid_response}} =
                 BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      refute File.exists?(Path.join(ctx.tmp_dir, "manifest.json"))
    end

    test "aborts manifest write when safe-tokenization helper response is malformed", ctx do
      copy_tokenizer_fixture!("wrapper_marker_only", ctx.tmp_dir)

      helper =
        write_catalog_helper!(ctx.tmp_dir, %{
          "control_tokens_chat_template" => [],
          "control_tokens_wrapper_tool" => ["<tool_call>", "<tool_call>", ""],
          "chat_template_literals_count" => 0,
          "wrapper_tool_markers_count" => 3
        })

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:error, {:safe_tokenization_helper_unavailable, :invalid_response}} =
                 BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      refute File.exists?(Path.join(ctx.tmp_dir, "manifest.json"))
    end
  end

  # -- Failure paths ---------------------------------------------------------

  describe "failure paths" do
    test "missing config.json", ctx do
      File.write!(Path.join(ctx.tmp_dir, "tokenizer.json"), "{}")
      File.write!(Path.join(ctx.tmp_dir, "model.safetensors"), "weights")

      assert {:error, {:missing_config, msg}} =
               BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert msg =~ "not found"
    end

    test "malformed config.json", ctx do
      write_minimal_bundle(ctx.tmp_dir, config: "NOT JSON")

      assert {:error, {:invalid_config_json, msg}} =
               BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert msg =~ "Invalid JSON"
    end

    test "config.json not an object", ctx do
      write_minimal_bundle(ctx.tmp_dir, config: "[1,2,3]")

      assert {:error, {:invalid_config_json, msg}} =
               BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert msg =~ "JSON object"
    end

    test "context window key present but invalid value rejects with error", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        config: %{"model_type" => "llama", "max_position_embeddings" => 0}
      )

      assert {:error, {:invalid_config, msg}} =
               BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert msg =~ "not a positive integer"
    end

    test "context window key present but garbage string rejects with error", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        config: %{"model_type" => "llama", "max_position_embeddings" => "not_a_number"}
      )

      assert {:error, {:invalid_config, msg}} =
               BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert msg =~ "not a positive integer"
    end

    test "missing context window in config produces bundle with nil max_context_tokens", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        config: %{"model_type" => "llama"}
      )

      assert {:ok, _bundle_dir} =
               BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.max_context_tokens == nil
    end

    test "missing tokenizer.json", ctx do
      File.write!(Path.join(ctx.tmp_dir, "config.json"), ~s({"max_position_embeddings": 4096}))

      assert {:error, {:missing_tokenizer, msg}} =
               BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert msg =~ "tokenizer.json"
    end

    test "nil revision_sha", ctx do
      write_minimal_bundle(ctx.tmp_dir)

      assert {:error, {:invalid_detail_metadata, msg}} =
               BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, %{revision_sha: nil})

      assert msg =~ "revision_sha"
    end

    test "blank revision_sha", ctx do
      write_minimal_bundle(ctx.tmp_dir)

      assert {:error, {:invalid_detail_metadata, msg}} =
               BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, %{revision_sha: "  "})

      assert msg =~ "revision_sha"
    end

    test "malformed tokenizer_config.json", ctx do
      write_minimal_bundle(ctx.tmp_dir)
      File.write!(Path.join(ctx.tmp_dir, "tokenizer_config.json"), "NOT JSON")

      assert {:error, {:invalid_tokenizer_config, msg}} =
               BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert msg =~ "Invalid JSON"
    end

    test "chat_template list with missing template field", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        tokenizer_config: %{
          "chat_template" => [%{"name" => "default"}]
        }
      )

      assert {:error, {:invalid_tokenizer_config, msg}} =
               BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert msg =~ "template"
    end

    test "non-binary repo_id" do
      assert {:error, {:invalid_repo_id, _}} =
               BundleBuilder.prepare_bundle("/tmp", 123, @detail_metadata)
    end

    test "non-map detail_metadata" do
      assert {:error, {:invalid_detail_metadata, _}} =
               BundleBuilder.prepare_bundle("/tmp", @repo_id, "not a map")
    end
  end

  # -- Symlink rejection -----------------------------------------------------

  describe "symlink rejection" do
    test "rejects symlinks in bundle directory", ctx do
      write_minimal_bundle(ctx.tmp_dir)
      symlink_path = Path.join(ctx.tmp_dir, "evil_link.json")
      File.ln_s!("/etc/passwd", symlink_path)

      assert {:error, {:invalid_bundle_layout, msg}} =
               BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert msg =~ "symlink"
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp write_minimal_bundle(dir, opts \\ []) do
    # Config
    config =
      case Keyword.get(opts, :config) do
        nil -> ~s({"max_position_embeddings": 4096})
        raw when is_binary(raw) -> raw
        map when is_map(map) -> Jason.encode!(map)
      end

    File.write!(Path.join(dir, "config.json"), config)

    # Tokenizer
    tokenizer = Keyword.get(opts, :tokenizer, ~s({"version": "1.0"}))
    File.write!(Path.join(dir, "tokenizer.json"), tokenizer)

    # Weights (for realistic bundle)
    weights = Keyword.get(opts, :weights, "fake-weights")
    File.write!(Path.join(dir, "model.safetensors"), weights)

    # Optional chat template
    case Keyword.get(opts, :chat_template) do
      nil -> :ok
      content -> File.write!(Path.join(dir, "chat_template.jinja"), content)
    end

    # Optional tokenizer_config.json
    case Keyword.get(opts, :tokenizer_config) do
      nil ->
        :ok

      config_map ->
        File.write!(Path.join(dir, "tokenizer_config.json"), Jason.encode!(config_map))
    end
  end

  defp write_safetensors_index(dir, data) do
    File.write!(Path.join(dir, "model.safetensors.index.json"), Jason.encode!(data))
  end

  defp tokenizer_fixture_root do
    Path.expand("../../fixtures/tokenizer", __DIR__)
  end

  defp copy_tokenizer_fixture!(name, destination) do
    source = Path.join(tokenizer_fixture_root(), name)

    source
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      File.cp_r!(path, Path.join(destination, Path.basename(path)))
    end)
  end

  defp write_catalog_helper!(dir, result) do
    response =
      Jason.encode!(%{
        "contract_version" => 3,
        "ok" => true,
        "result" => result
      })

    write_executable!(dir, "catalog-helper.sh", """
    #!/bin/sh
    cat >/dev/null
    cat <<'JSON'
    #{response}
    JSON
    """)
  end

  defp write_catalog_error_helper!(dir, category, message) do
    response =
      Jason.encode!(%{
        "contract_version" => 3,
        "ok" => false,
        "error" => %{"category" => category, "message" => message}
      })

    write_executable!(dir, "catalog-error-helper.sh", """
    #!/bin/sh
    cat >/dev/null
    cat <<'JSON'
    #{response}
    JSON
    """)
  end

  defp write_sleeping_catalog_helper!(dir) do
    write_executable!(dir, "sleeping-catalog-helper.sh", """
    #!/bin/sh
    cat >/dev/null
    sleep 1
    """)
  end

  defp write_executable!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    File.chmod!(path, 0o755)
    path
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
        value -> Application.put_env(:orchard_controller, key, value)
      end
    end
  end

  defp read_manifest_json!(dir) do
    dir
    |> Path.join("manifest.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp hash_catalog(control_tokens) do
    control_tokens
    |> Enum.intersperse(<<0>>)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
