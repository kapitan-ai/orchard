defmodule Orchard.Models.ManifestParserTest do
  use ExUnit.Case, async: true

  alias Orchard.ModelManifest
  alias Orchard.Models.ManifestParser

  @fixture_bundle Path.expand("../../fixtures/bundles/test-model-bundle", __DIR__)

  describe "parse_from_bundle/1" do
    test "parses a valid bundle manifest" do
      assert {:ok, %ModelManifest{} = manifest} =
               ManifestParser.parse_from_bundle(@fixture_bundle)

      assert manifest.model_id == "test-org/tiny-llm"
      assert manifest.version == "mlx-q4-v1"
      assert manifest.format == "mlx"
      assert manifest.artifact_layout == "directory"
      assert manifest.entrypoint == "weights/"
      assert manifest.sha256 == "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
      assert manifest.size_bytes == 1_024_000
      assert manifest.resident_memory_bytes == 2_048_000
      assert manifest.kv_cache_bytes_per_token == 16_384
      assert manifest.prefill_workspace_bytes_per_token == 2_048
      assert manifest.max_context_tokens == 4_096
      assert manifest.capabilities == ["chat"]

      assert %ModelManifest.Tokenizer{kind: "huggingface_tokenizer_json", path: "tokenizer.json"} =
               manifest.tokenizer

      assert %ModelManifest.ChatTemplate{path: "chat_template.jinja"} = manifest.chat_template

      assert %ModelManifest.RuntimeRequirements{adapter: "mlx_lm", min_agent_capability: "mlx"} =
               manifest.runtime_requirements
    end

    test "returns error for missing directory" do
      assert {:error, {:manifest_not_found, path}} =
               ManifestParser.parse_from_bundle("/nonexistent/path")

      assert path =~ "manifest.json"
    end

    test "returns error for directory without manifest.json" do
      dir = System.tmp_dir!() |> Path.join("empty_bundle_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:error, {:manifest_not_found, _}} = ManifestParser.parse_from_bundle(dir)
    end
  end

  describe "parse_json/1" do
    test "parses valid JSON" do
      json = valid_manifest_json()

      assert {:ok, %ModelManifest{model_id: "test-org/tiny-llm"}} =
               ManifestParser.parse_json(json)
    end

    test "parses safe_tokenization and defaults compatible=true when absent" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["tokenizer", "config_path"], "tokenizer_config.json")
        |> Jason.encode!()

      assert {:ok, %ModelManifest{} = manifest} = ManifestParser.parse_json(json)
      assert manifest.tokenizer.config_path == "tokenizer_config.json"
      assert manifest.safe_tokenization.compatible == true
    end

    test "rejects non-object JSON" do
      assert {:error, {:json_decode, "manifest must be a JSON object"}} =
               ManifestParser.parse_json("[1, 2, 3]")
    end

    test "rejects malformed JSON" do
      assert {:error, {:json_decode, _message}} = ManifestParser.parse_json("{bad json")
    end

    test "rejects unknown top-level keys" do
      json =
        valid_manifest_json()
        |> Jason.decode!()
        |> Map.put("unknown_field", "value")
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "unknown manifest keys"
      assert message =~ "unknown_field"
    end

    test "rejects unknown nested tokenizer keys" do
      json =
        valid_manifest_json()
        |> Jason.decode!()
        |> Map.put("tokenizer", %{"kind" => "hf", "path" => "t.json", "extra" => true})
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "unknown keys in :tokenizer"
    end

    test "rejects unknown nested safe_tokenization keys" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "unexpected"], true)
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "unknown keys in :safe_tokenization"
    end

    test "rejects unknown nested safe_tokenization.catalog_source keys" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "catalog_source", "unexpected"], 1)
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "unknown keys in :safe"
    end

    test "returns validation error when safe_tokenization is not an object" do
      json =
        valid_manifest_json()
        |> Jason.decode!()
        |> Map.put("safe_tokenization", "bad")
        |> Jason.encode!()

      assert {:error, {:validation, "safe_tokenization must be an object when present"}} =
               ManifestParser.parse_json(json)
    end

    test "rejects unknown nested safe_tokenization.incompatibility_reason keys" do
      json =
        valid_manifest_json_with_safe_tokenization(false, "per_codepoint_decode_mismatch")
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "incompatibility_reason", "unexpected"], 1)
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "unknown keys in :reason"
    end

    test "returns validation error for missing required fields" do
      json =
        valid_manifest_json()
        |> Jason.decode!()
        |> Map.delete("model_id")
        |> Jason.encode!()

      assert {:error, {:validation, _message}} = ManifestParser.parse_json(json)
    end

    test "rejects control_tokens when value is not a list" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "control_tokens"], "not-a-list")
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "control_tokens must be a list"
    end

    test "rejects control_tokens when list contains non-string entries" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "control_tokens"], ["<|im_start|>", 1])
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "control_tokens must contain only strings"
    end

    test "rejects control_tokens when list contains empty strings" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "control_tokens"], ["", "<|im_start|>"])
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "control_tokens must contain only non-empty strings"
    end

    test "rejects duplicate control_tokens" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "control_tokens"], ["<a>", "<a>"])
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "control_tokens must be deduped"
    end

    test "rejects unsorted control_tokens" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "control_tokens"], ["z", "a"])
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "control_tokens must be lexicographically sorted"
    end

    test "rejects duplicate extra_control_token_strings" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "extra_control_token_strings"], ["<a>", "<a>"])
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "extra_control_token_strings must be deduped"
    end

    test "rejects null extra_control_token_strings when key is present" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "extra_control_token_strings"], nil)
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "extra_control_token_strings must be a list"
    end

    test "rejects extra_control_token_strings entries outside control_tokens" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "extra_control_token_strings"], ["<missing>"])
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "extra_control_token_strings entries must also appear in control_tokens"
    end

    test "rejects catalog_source.extra_count larger than extra_control_token_strings length" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "catalog_source", "extra_count"], 2)
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)

      assert message =~
               "catalog_source.extra_count must equal length(extra_control_token_strings || [])"
    end

    test "rejects nonzero catalog_source.extra_count when extra_control_token_strings is absent" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> update_in(["safe_tokenization"], &Map.delete(&1, "extra_control_token_strings"))
        |> put_in(["safe_tokenization", "catalog_source", "extra_count"], 1)
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)

      assert message =~
               "catalog_source.extra_count must equal length(extra_control_token_strings || [])"
    end

    test "accepts absent extra_control_token_strings when catalog_source.extra_count is zero" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> update_in(["safe_tokenization"], &Map.delete(&1, "extra_control_token_strings"))
        |> put_in(["safe_tokenization", "catalog_source", "extra_count"], 0)
        |> Jason.encode!()

      assert {:ok, %ModelManifest{} = manifest} = ManifestParser.parse_json(json)
      assert manifest.safe_tokenization.extra_control_token_strings == nil
    end

    test "rejects catalog_sha256 mismatch" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "catalog_sha256"], String.duplicate("a", 64))
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "catalog_sha256 does not match control_tokens"
    end

    test "rejects safe_tokenization when catalog_sha256 is absent" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> update_in(["safe_tokenization"], &Map.delete(&1, "catalog_sha256"))
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "catalog_sha256 is required"
    end

    test "rejects null catalog_sha256 when key is present" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "catalog_sha256"], nil)
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "catalog_sha256 must be 64-character lowercase hex"
    end

    test "rejects missing catalog_source when safe_tokenization exists" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> update_in(["safe_tokenization"], &Map.delete(&1, "catalog_source"))
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "catalog_source is required"
    end

    test "rejects catalog_source when each required key is missing" do
      required_keys = [
        "added_tokens_count",
        "config_singletons_count",
        "additional_special_tokens_count",
        "chat_template_literals_count",
        "wrapper_tool_markers_count",
        "extra_count"
      ]

      Enum.each(required_keys, fn key ->
        json =
          valid_manifest_json_with_safe_tokenization()
          |> Jason.decode!()
          |> update_in(["safe_tokenization", "catalog_source"], &Map.delete(&1, key))
          |> Jason.encode!()

        assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
        assert message =~ "catalog_source missing required keys"
        assert message =~ key
      end)
    end

    test "rejects negative catalog_source counts for every required key" do
      required_keys = [
        "added_tokens_count",
        "config_singletons_count",
        "additional_special_tokens_count",
        "chat_template_literals_count",
        "wrapper_tool_markers_count",
        "extra_count"
      ]

      Enum.each(required_keys, fn key ->
        json =
          valid_manifest_json_with_safe_tokenization()
          |> Jason.decode!()
          |> put_in(["safe_tokenization", "catalog_source", key], -1)
          |> Jason.encode!()

        assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
        assert message =~ "catalog_source.#{key} must be a non-negative integer"
      end)
    end

    test "rejects non-integer catalog_source counts for every required key" do
      required_keys = [
        "added_tokens_count",
        "config_singletons_count",
        "additional_special_tokens_count",
        "chat_template_literals_count",
        "wrapper_tool_markers_count",
        "extra_count"
      ]

      Enum.each(required_keys, fn key ->
        json =
          valid_manifest_json_with_safe_tokenization()
          |> Jason.decode!()
          |> put_in(["safe_tokenization", "catalog_source", key], "1")
          |> Jason.encode!()

        assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
        assert message =~ "catalog_source.#{key} must be a non-negative integer"
      end)
    end

    test "rejects incompatible reason with compatible true" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "compatible"], true)
        |> put_in(["safe_tokenization", "incompatibility_reason"], %{
          "category" => "reserved_id_persists",
          "literal" => "<x>"
        })
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "incompatibility_reason is not allowed"
    end

    test "rejects compatible false without incompatibility reason" do
      json =
        valid_manifest_json_with_safe_tokenization()
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "compatible"], false)
        |> update_in(["safe_tokenization"], &Map.delete(&1, "incompatibility_reason"))
        |> Jason.encode!()

      assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
      assert message =~ "requires incompatibility_reason"
    end

    test "accepts dual_render_mismatch only with template_compatible false and required fields" do
      json =
        valid_manifest_json_with_safe_tokenization(false, "dual_render_mismatch")
        |> Jason.decode!()
        |> put_in(["safe_tokenization", "template_compatible"], false)
        |> put_in(["safe_tokenization", "incompatibility_reason"], %{
          "category" => "dual_render_mismatch",
          "leaf_class" => "tool_call",
          "sentinel_index" => 0,
          "first_diff_offset" => 1
        })
        |> Jason.encode!()

      assert {:ok, _manifest} = ManifestParser.parse_json(json)
    end

    test "parses manifest without optional chat_template" do
      json =
        valid_manifest_json()
        |> Jason.decode!()
        |> Map.delete("chat_template")
        |> Jason.encode!()

      assert {:ok, %ModelManifest{chat_template: nil}} = ManifestParser.parse_json(json)
    end

    test "parses manifest without optional size fields" do
      json =
        valid_manifest_json()
        |> Jason.decode!()
        |> Map.delete("size_bytes")
        |> Map.delete("resident_memory_bytes")
        |> Jason.encode!()

      assert {:ok, %ModelManifest{size_bytes: nil, resident_memory_bytes: nil}} =
               ManifestParser.parse_json(json)
    end
  end

  defp valid_manifest_json do
    Jason.encode!(base_manifest_map())
  end

  defp valid_manifest_json_with_safe_tokenization(compatible \\ nil, category \\ nil) do
    control_tokens = ["<extra>", "<|im_end|>", "<|im_start|>"]

    safe = %{
      "control_tokens" => control_tokens,
      "extra_control_token_strings" => ["<extra>"] |> Enum.sort(),
      "catalog_sha256" => hash_catalog(control_tokens),
      "catalog_source" => %{
        "added_tokens_count" => 1,
        "config_singletons_count" => 1,
        "additional_special_tokens_count" => 1,
        "chat_template_literals_count" => 1,
        "wrapper_tool_markers_count" => 1,
        "extra_count" => 1
      }
    }

    safe =
      if is_boolean(compatible) do
        Map.put(safe, "compatible", compatible)
      else
        safe
      end

    safe =
      if compatible == false and is_binary(category) do
        Map.put(safe, "incompatibility_reason", %{"category" => category, "literal" => "<lit>"})
      else
        safe
      end

    base_manifest_map()
    |> Map.put("safe_tokenization", safe)
    |> Jason.encode!()
  end

  defp hash_catalog(control_tokens) do
    control_tokens
    |> Enum.intersperse(<<0>>)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp base_manifest_map do
    %{
      "model_id" => "test-org/tiny-llm",
      "version" => "mlx-q4-v1",
      "format" => "mlx",
      "artifact_layout" => "directory",
      "entrypoint" => "weights/",
      "sha256" => "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
      "size_bytes" => 1_024_000,
      "resident_memory_bytes" => 2_048_000,
      "kv_cache_bytes_per_token" => 16_384,
      "prefill_workspace_bytes_per_token" => 2_048,
      "max_context_tokens" => 4_096,
      "capabilities" => ["chat"],
      "tokenizer" => %{
        "kind" => "huggingface_tokenizer_json",
        "path" => "tokenizer.json"
      },
      "chat_template" => %{
        "path" => "chat_template.jinja",
        "sha256" => "def0123456789abcdef0123456789abcdef0123456789abcdef0123456789abc"
      },
      "runtime_requirements" => %{
        "adapter" => "mlx_lm",
        "min_agent_capability" => "mlx"
      }
    }
  end
end
