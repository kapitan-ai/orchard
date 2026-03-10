defmodule Orchard.Models.ManifestParserTest do
  use ExUnit.Case, async: true

  alias Orchard.ModelManifest
  alias Orchard.Models.ManifestParser

  @fixture_bundle Path.expand("../../fixtures/bundles/test-model-bundle", __DIR__)

  describe "parse_from_bundle/1" do
    test "parses a valid bundle manifest" do
      assert {:ok, %ModelManifest{} = manifest} = ManifestParser.parse_from_bundle(@fixture_bundle)

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
      assert {:ok, %ModelManifest{model_id: "test-org/tiny-llm"}} = ManifestParser.parse_json(json)
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

    test "returns validation error for missing required fields" do
      json =
        valid_manifest_json()
        |> Jason.decode!()
        |> Map.delete("model_id")
        |> Jason.encode!()

      assert {:error, {:validation, _message}} = ManifestParser.parse_json(json)
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
    Jason.encode!(%{
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
    })
  end
end
