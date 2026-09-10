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

  # -- Revision-bound tool capability evidence ------------------------------

  describe "tool capability admission" do
    test "declares tool calling only after a recognized parser and bounded rendering preflight",
         ctx do
      template =
        "{% for tool in tools %}{{ tool.function.name }} {{ tool.function.description }}{% endfor %}" <>
          "{% for message in messages %}{{ message.content }}{% endfor %}"

      write_minimal_bundle(ctx.tmp_dir,
        chat_template: template,
        tokenizer_config: %{"tool_parser_type" => "glm47"}
      )

      detail_metadata = %{
        revision_sha: @revision_sha,
        metadata_summary: %{base_models: ["zai-org/GLM-4.7-Flash"]}
      }

      helper =
        write_catalog_helper!(ctx.tmp_dir, %{
          "control_tokens_chat_template" => [],
          "control_tokens_wrapper_tool" => [],
          "chat_template_literals_count" => 0,
          "wrapper_tool_markers_count" => 0
        })

      {:ok, manifest} =
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, detail_metadata)
          ManifestParser.parse_from_bundle(ctx.tmp_dir)
        end)

      assert manifest.capabilities == ["chat", "tool_calling"]

      refute Map.has_key?(
               Jason.decode!(File.read!(Path.join(ctx.tmp_dir, "manifest.json"))),
               "capability_evidence"
             )

      assert File.exists?(Path.join(ctx.tmp_dir, "tool_capability_evidence.json"))

      evidence = manifest.capability_evidence.tool_calling
      assert evidence.source_repository == @repo_id
      assert evidence.source_revision == @revision_sha
      assert evidence.base_model_refs == ["zai-org/GLM-4.7-Flash"]
      assert evidence.tool_parser_type == "glm47"

      assert evidence.preflight == %{
               parser_recognized: true,
               definition_rendered: true,
               history_rendered: true
             }

      assert evidence.result == "declared"
      assert evidence.runtime_qualification == "not_established"
      assert is_binary(evidence.tokenizer_config_sha256)
      assert is_binary(evidence.chat_template_sha256)
    end

    test "keeps an unknown parser chat-only without inferring capability from metadata", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        chat_template: "{% for message in messages %}{{ message.content }}{% endfor %}",
        tokenizer_config: %{"tool_parser_type" => "unqualified_parser"}
      )

      helper =
        write_catalog_helper!(
          ctx.tmp_dir,
          %{
            "control_tokens_chat_template" => [],
            "control_tokens_wrapper_tool" => [],
            "chat_template_literals_count" => 0,
            "wrapper_tool_markers_count" => 0
          },
          compatible_preflight_result(),
          %{
            "contract_version" => 3,
            "ok" => true,
            "result" => %{
              "parser_recognized" => false,
              "definition_rendered" => true,
              "history_rendered" => true
            }
          }
        )

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.capabilities == ["chat"]
      assert manifest.capability_evidence.tool_calling.result == "conflicted"
      assert manifest.capability_evidence.tool_calling.preflight.parser_recognized == false
      assert manifest.capability_evidence.tool_calling.runtime_qualification == "not_established"
    end

    test "logs why a declared parser stayed chat-only when the preflight fails", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        chat_template: "{% for message in messages %}{{ message.content }}{% endfor %}",
        tokenizer_config: %{"tool_parser_type" => "glm47"}
      )

      helper =
        write_catalog_helper!(
          ctx.tmp_dir,
          %{
            "control_tokens_chat_template" => [],
            "control_tokens_wrapper_tool" => [],
            "chat_template_literals_count" => 0,
            "wrapper_tool_markers_count" => 0
          },
          compatible_preflight_result(),
          %{
            "contract_version" => 3,
            "ok" => false,
            "error" => %{"category" => "missing_assets", "message" => "helper is unavailable"}
          }
        )

      log =
        capture_log(fn ->
          with_inference_overrides([tokenizer_executable: helper], fn ->
            assert {:ok, _} =
                     BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
          end)
        end)

      assert log =~ "tool capability preflight failed"
      assert log =~ "helper_error"
      assert log =~ "missing_assets"
      assert log =~ "helper is unavailable"
      refute log =~ "invalid_response"

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.capabilities == ["chat"]
      assert manifest.capability_evidence.tool_calling.result == "unknown"
    end

    test "records unknown evidence when the immutable tuple has no parser or template", ctx do
      write_minimal_bundle(ctx.tmp_dir)

      assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.capabilities == ["chat"]
      assert manifest.capability_evidence.tool_calling.result == "unknown"

      assert manifest.capability_evidence.tool_calling.preflight == %{
               parser_recognized: false,
               definition_rendered: false,
               history_rendered: false
             }
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

      {:ok, manifest} =
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
          ManifestParser.parse_from_bundle(ctx.tmp_dir)
        end)

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
      assert raw["safe_tokenization"]["compatible"] == true
      assert raw["safe_tokenization"]["template_compatible"] == true
      refute Map.has_key?(raw["safe_tokenization"], "incompatibility_reason")
    end

    test "eager preflight writes compatible/template_compatible on success", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        chat_template: "{% for msg in messages %}{{ msg.content }}{% endfor %}",
        tokenizer_config: %{"add_bos_token" => true}
      )

      helper =
        write_catalog_helper!(ctx.tmp_dir, %{
          "control_tokens_chat_template" => ["<template_only>"],
          "control_tokens_wrapper_tool" => [],
          "chat_template_literals_count" => 1,
          "wrapper_tool_markers_count" => 0
        })

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      raw = read_manifest_json!(ctx.tmp_dir)
      assert raw["safe_tokenization"]["compatible"] == true
      assert raw["safe_tokenization"]["template_compatible"] == true
      refute Map.has_key?(raw["safe_tokenization"], "incompatibility_reason")
    end

    test "eager preflight writes dual_render_mismatch incompatibility", ctx do
      copy_tokenizer_fixture!("minimal_hf_template_divergent", ctx.tmp_dir)

      helper =
        write_catalog_helper!(
          ctx.tmp_dir,
          %{
            "control_tokens_chat_template" => [],
            "control_tokens_wrapper_tool" => [],
            "chat_template_literals_count" => 0,
            "wrapper_tool_markers_count" => 0
          },
          incompatible_preflight_result(
            %{
              "category" => "dual_render_mismatch",
              "leaf_class" => "message_content",
              "sentinel_index" => 0,
              "first_diff_offset" => 1
            },
            false
          )
        )

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      raw = read_manifest_json!(ctx.tmp_dir)
      assert raw["safe_tokenization"]["compatible"] == false
      assert raw["safe_tokenization"]["template_compatible"] == false

      assert raw["safe_tokenization"]["incompatibility_reason"] == %{
               "category" => "dual_render_mismatch",
               "leaf_class" => "message_content",
               "sentinel_index" => 0,
               "first_diff_offset" => 1
             }
    end

    test "eager preflight writes reserved_id_persists incompatibility", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        chat_template: "{% for msg in messages %}{{ msg.content }}{% endfor %}",
        tokenizer_config: %{"add_bos_token" => true}
      )

      helper =
        write_catalog_helper!(
          ctx.tmp_dir,
          %{
            "control_tokens_chat_template" => ["<reserved>"],
            "control_tokens_wrapper_tool" => [],
            "chat_template_literals_count" => 1,
            "wrapper_tool_markers_count" => 0
          },
          incompatible_preflight_result(%{
            "category" => "reserved_id_persists",
            "literal" => "<reserved>"
          })
        )

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      raw = read_manifest_json!(ctx.tmp_dir)
      assert raw["safe_tokenization"]["compatible"] == false
      assert raw["safe_tokenization"]["template_compatible"] == true

      assert raw["safe_tokenization"]["incompatibility_reason"] == %{
               "category" => "reserved_id_persists",
               "literal" => "<reserved>"
             }
    end

    test "SPEC.md §6.4 accepts empty_literal preflight verdict through manifest validation",
         ctx do
      write_minimal_bundle(ctx.tmp_dir,
        chat_template: "{% for msg in messages %}{{ msg.content }}{% endfor %}",
        tokenizer_config: %{"add_bos_token" => true}
      )

      helper =
        write_catalog_helper!(
          ctx.tmp_dir,
          %{
            "control_tokens_chat_template" => ["<reserved>"],
            "control_tokens_wrapper_tool" => [],
            "chat_template_literals_count" => 1,
            "wrapper_tool_markers_count" => 0
          },
          incompatible_preflight_result(%{"category" => "empty_literal", "literal" => ""})
        )

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.safe_tokenization.compatible == false
      assert manifest.safe_tokenization.template_compatible == true
      assert manifest.safe_tokenization.incompatibility_reason.category == "empty_literal"
      assert manifest.safe_tokenization.incompatibility_reason.literal == ""

      raw = read_manifest_json!(ctx.tmp_dir)

      assert raw["safe_tokenization"]["incompatibility_reason"] == %{
               "category" => "empty_literal",
               "literal" => ""
             }
    end

    test "eager preflight helper failure leaves manifest fields unset", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        chat_template: "{% for msg in messages %}{{ msg.content }}{% endfor %}",
        tokenizer_config: %{"add_bos_token" => true}
      )

      helper =
        write_catalog_helper!(
          ctx.tmp_dir,
          %{
            "control_tokens_chat_template" => ["<template_only>"],
            "control_tokens_wrapper_tool" => [],
            "chat_template_literals_count" => 1,
            "wrapper_tool_markers_count" => 0
          },
          preflight_error_response("safe_tokenization_catalog_hash_mismatch", "catalog mismatch")
        )

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      raw = read_manifest_json!(ctx.tmp_dir)
      refute Map.has_key?(raw["safe_tokenization"], "compatible")
      refute Map.has_key?(raw["safe_tokenization"], "template_compatible")
      refute Map.has_key?(raw["safe_tokenization"], "incompatibility_reason")
    end

    test "eager preflight timeout leaves manifest fields unset", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        chat_template: "{% for msg in messages %}{{ msg.content }}{% endfor %}",
        tokenizer_config: %{"add_bos_token" => true}
      )

      helper =
        write_catalog_then_sleeping_preflight_helper!(ctx.tmp_dir, %{
          "control_tokens_chat_template" => ["<template_only>"],
          "control_tokens_wrapper_tool" => [],
          "chat_template_literals_count" => 1,
          "wrapper_tool_markers_count" => 0
        })

      with_app_env(:bundle_build_preflight_timeout_ms, 10, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
        end)
      end)

      raw = read_manifest_json!(ctx.tmp_dir)
      refute Map.has_key?(raw["safe_tokenization"], "compatible")
      refute Map.has_key?(raw["safe_tokenization"], "template_compatible")
      refute Map.has_key?(raw["safe_tokenization"], "incompatibility_reason")
    end

    test "eager preflight invalid helper success leaves manifest fields unset", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        chat_template: "{% for msg in messages %}{{ msg.content }}{% endfor %}",
        tokenizer_config: %{"add_bos_token" => true}
      )

      helper =
        write_catalog_helper!(
          ctx.tmp_dir,
          %{
            "control_tokens_chat_template" => ["<template_only>"],
            "control_tokens_wrapper_tool" => [],
            "chat_template_literals_count" => 1,
            "wrapper_tool_markers_count" => 0
          },
          incompatible_preflight_result(%{"category" => "not_an_allowed_category"})
        )

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      raw = read_manifest_json!(ctx.tmp_dir)
      refute Map.has_key?(raw["safe_tokenization"], "compatible")
      refute Map.has_key?(raw["safe_tokenization"], "template_compatible")
      refute Map.has_key?(raw["safe_tokenization"], "incompatibility_reason")
    end

    test "eager preflight disabled keeps Phase 1 manifest shape", ctx do
      write_minimal_bundle(ctx.tmp_dir,
        chat_template: "{% for msg in messages %}{{ msg.content }}{% endfor %}",
        tokenizer_config: %{"add_bos_token" => true}
      )

      helper =
        write_catalog_helper!(ctx.tmp_dir, %{
          "control_tokens_chat_template" => ["<template_only>"],
          "control_tokens_wrapper_tool" => [],
          "chat_template_literals_count" => 1,
          "wrapper_tool_markers_count" => 0
        })

      with_app_env(:bundle_build_eager_preflight_enabled, false, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
        end)
      end)

      raw = read_manifest_json!(ctx.tmp_dir)
      refute Map.has_key?(raw["safe_tokenization"], "compatible")
      refute Map.has_key?(raw["safe_tokenization"], "template_compatible")
      refute Map.has_key?(raw["safe_tokenization"], "incompatibility_reason")
    end

    test "catalog helper request uses private temp directory and cleans it up", ctx do
      tmp_root = Path.join(ctx.tmp_dir, "transport-tmp")
      File.mkdir_p!(tmp_root)

      write_minimal_bundle(ctx.tmp_dir,
        chat_template: "{% for msg in messages %}{{ msg.content }}{% endfor %}",
        tokenizer_config: %{"add_bos_token" => true}
      )

      helper = write_private_catalog_transport_asserting_helper!(ctx.tmp_dir)

      with_tmpdir(tmp_root, fn ->
        with_app_env(:bundle_build_eager_preflight_enabled, false, fn ->
          with_inference_overrides([tokenizer_executable: helper], fn ->
            assert {:ok, _} =
                     BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
          end)
        end)

        assert catalog_transport_dirs(tmp_root) == []
      end)
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

      {:ok, manifest} =
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
          ManifestParser.parse_from_bundle(ctx.tmp_dir)
        end)

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
        write_catalog_helper!(
          ctx.tmp_dir,
          %{
            "control_tokens_chat_template" => ["<|template_without_config|>"],
            "control_tokens_wrapper_tool" => [],
            "chat_template_literals_count" => 1,
            "wrapper_tool_markers_count" => 0
          },
          preflight_error_response(
            "safe_tokenization_catalog_hash_mismatch",
            "should not be called"
          )
        )

      error_ref = attach_telemetry([:orchard, :tokenizer, :bundle_preflight, :error])

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, _} = BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
      end)

      refute_receive {^error_ref, [:orchard, :tokenizer, :bundle_preflight, :error], _, _}

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(ctx.tmp_dir)
      assert manifest.tokenizer.config_path == nil
      assert manifest.chat_template.path == "chat_template.jinja"
      assert manifest.safe_tokenization.control_tokens == ["<|template_without_config|>"]
      assert manifest.safe_tokenization.catalog_source.chat_template_literals_count == 1

      raw = read_manifest_json!(ctx.tmp_dir)
      refute Map.has_key?(raw["safe_tokenization"], "compatible")
      refute Map.has_key?(raw["safe_tokenization"], "template_compatible")
      refute Map.has_key?(raw["safe_tokenization"], "incompatibility_reason")
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

    test "SPEC.md §6.4 catalog helper timeout is an absolute deadline", ctx do
      copy_tokenizer_fixture!("wrapper_marker_only", ctx.tmp_dir)
      helper = write_dribbling_catalog_helper!(ctx.tmp_dir)

      with_app_env(:bundle_build_catalog_timeout_ms, 200, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          {elapsed_us, result} =
            :timer.tc(fn ->
              BundleBuilder.prepare_bundle(ctx.tmp_dir, @repo_id, @detail_metadata)
            end)

          assert {:error, {:safe_tokenization_helper_unavailable, :timeout}} = result
          assert System.convert_time_unit(elapsed_us, :microsecond, :millisecond) < 800
        end)
      end)

      refute File.exists?(Path.join(ctx.tmp_dir, "manifest.json"))
    end

    test "SPEC.md §6.4 catalog helper stdout is cumulatively capped", ctx do
      copy_tokenizer_fixture!("wrapper_marker_only", ctx.tmp_dir)
      helper = write_oversized_catalog_stdout_helper!(ctx.tmp_dir)

      with_app_env(:bundle_build_catalog_max_stdout_bytes, 64, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:error, {:safe_tokenization_helper_unavailable, {:stdout_too_large, 64}}} =
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

  defp write_catalog_helper!(
         dir,
         result,
         preflight_result \\ compatible_preflight_result(),
         tool_capability_result \\ compatible_tool_capability_result()
       ) do
    catalog_response =
      Jason.encode!(%{
        "contract_version" => 3,
        "ok" => true,
        "result" => result
      })

    preflight_response = Jason.encode!(preflight_result)
    tool_capability_response = Jason.encode!(tool_capability_result)

    write_executable!(dir, "catalog-helper.sh", """
    #!/bin/sh
    payload=$(cat)
    case "$payload" in
      *'"command":"preflight_tool_capability"'*)
        cat <<'JSON'
    #{tool_capability_response}
    JSON
        ;;
      *'"command":"preflight_safe_tokenization"'*)
        cat <<'JSON'
    #{preflight_response}
    JSON
        ;;
      *)
        cat <<'JSON'
    #{catalog_response}
    JSON
        ;;
    esac
    """)
  end

  defp compatible_tool_capability_result do
    %{
      "contract_version" => 3,
      "ok" => true,
      "result" => %{
        "parser_recognized" => true,
        "definition_rendered" => true,
        "history_rendered" => true
      }
    }
  end

  defp compatible_preflight_result do
    %{
      "contract_version" => 3,
      "ok" => true,
      "result" => %{
        "compatible" => true,
        "template_compatible" => true,
        "incompatibility_reason" => nil
      }
    }
  end

  defp incompatible_preflight_result(reason, template_compatible \\ true) do
    %{
      "contract_version" => 3,
      "ok" => true,
      "result" => %{
        "compatible" => false,
        "template_compatible" => template_compatible,
        "incompatibility_reason" => reason
      }
    }
  end

  defp preflight_error_response(category, message) do
    %{
      "contract_version" => 3,
      "ok" => false,
      "error" => %{"category" => category, "message" => message}
    }
  end

  defp write_catalog_then_sleeping_preflight_helper!(dir, result) do
    catalog_response =
      Jason.encode!(%{
        "contract_version" => 3,
        "ok" => true,
        "result" => result
      })

    write_executable!(dir, "catalog-sleeping-preflight-helper.sh", """
    #!/bin/sh
    payload=$(cat)
    case "$payload" in
      *'"command":"preflight_safe_tokenization"'*)
        sleep 1
        ;;
      *)
        cat <<'JSON'
    #{catalog_response}
    JSON
        ;;
    esac
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

  defp write_private_catalog_transport_asserting_helper!(dir) do
    response =
      Jason.encode!(%{
        "contract_version" => 3,
        "ok" => true,
        "result" => %{
          "control_tokens_chat_template" => ["<template_only>"],
          "control_tokens_wrapper_tool" => [],
          "chat_template_literals_count" => 1,
          "wrapper_tool_markers_count" => 0
        }
      })

    write_executable!(dir, "catalog-transport-asserting-helper.sh", """
    #!/bin/sh
    set -eu
    tmp="${TMPDIR:-/tmp}"
    count=0
    selected=""

    for candidate in "$tmp"/orchard-tokenizer-catalog-*; do
      [ -e "$candidate" ] || continue

      if [ -d "$candidate" ]; then
        count=$((count + 1))
        selected="$candidate"
      fi
    done

    [ "$count" -eq 1 ] || exit 21

    request="$selected/request.json"
    [ -f "$request" ] || exit 22
    [ ! -L "$request" ] || exit 23

    mode=$(stat -c '%a' "$selected" 2>/dev/null || stat -f '%Lp' "$selected" 2>/dev/null || echo unknown)
    [ "$mode" = "700" ] || exit 24

    payload=$(cat)

    case "$payload" in
      *'"command":"extract_safe_tokenization_catalog"'*) ;;
      *) exit 25 ;;
    esac

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

  defp write_dribbling_catalog_helper!(dir) do
    write_executable!(dir, "dribbling-catalog-helper.sh", """
    #!/bin/sh
    perl -e '$| = 1; for (1..20) { print "x" x 1024; select(undef, undef, undef, 0.05); }' 2>/dev/null || true
    """)
  end

  defp write_oversized_catalog_stdout_helper!(dir) do
    write_executable!(dir, "oversized-catalog-stdout-helper.sh", """
    #!/bin/sh
    cat >/dev/null
    printf '%s' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    printf '%s' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    printf '%s' 'c'
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

  defp with_tmpdir(tmp_dir, fun) when is_function(fun, 0) do
    previous = System.get_env("TMPDIR")
    System.put_env("TMPDIR", tmp_dir)

    try do
      fun.()
    after
      restore_env("TMPDIR", previous)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp catalog_transport_dirs(tmp_root) do
    tmp_root
    |> Path.join("orchard-tokenizer-catalog-*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
  end

  defp read_manifest_json!(dir) do
    dir
    |> Path.join("manifest.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp attach_telemetry(event) do
    parent = self()
    ref = make_ref()

    :telemetry.attach(
      inspect(ref),
      event,
      fn emitted_event, measurements, metadata, _config ->
        send(parent, {ref, emitted_event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(inspect(ref)) end)
    ref
  end

  defp hash_catalog(control_tokens) do
    control_tokens
    |> Enum.intersperse(<<0>>)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
