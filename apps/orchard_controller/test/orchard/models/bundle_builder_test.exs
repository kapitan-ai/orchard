defmodule Orchard.Models.BundleBuilderTest do
  use ExUnit.Case, async: true

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
      write_minimal_bundle(ctx.tmp_dir)
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
      write_minimal_bundle(ctx.tmp_dir, chat_template: template)

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

      {:ok, manifest} = Orchard.Models.ManifestParser.parse_from_bundle(ctx.tmp_dir)
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
end
