defmodule Orchard.Models.ManifestSchemaContractTest do
  use ExUnit.Case, async: true

  alias Orchard.ModelManifest
  alias Orchard.Models.ManifestParser

  @contract_path Path.expand(
                   "../../../../orchard_shared/test/fixtures/manifest_schema/v1.json",
                   __DIR__
                 )
  @fixture_bundle Path.expand("../../fixtures/bundles/test-model-bundle", __DIR__)

  test "SPEC 6.4 manifest schema contract fixture is versioned and deterministic" do
    contract = load_contract!()

    assert contract["version"] == 1
    assert contract["top_level_keys"] == Enum.sort(contract["top_level_keys"])

    expected_nested_names =
      parser_contract_key_sets()
      |> Map.fetch!("nested_keys")
      |> Map.keys()
      |> Enum.sort()

    assert contract["nested_keys"] |> Map.keys() |> Enum.sort() == expected_nested_names

    Enum.each(contract["nested_keys"], fn {_name, keys} ->
      assert keys == Enum.sort(keys)
    end)

    assert contract["worker_validates_top_level_keys"] == true

    assert contract["worker_validates_nested_keys"] == [
             "chat_template",
             "runtime_requirements",
             "tokenizer"
           ]
  end

  test "SPEC 6.4 parser schema keys match the shared contract" do
    contract = load_contract!()

    assert parser_contract_key_sets() == %{
             "top_level_keys" => contract["top_level_keys"],
             "nested_keys" => contract["nested_keys"]
           }
  end

  test "SPEC 6.4 canonical bundle parses with tokenizer config and safe-tokenization metadata" do
    assert {:ok, %ModelManifest{} = manifest} = ManifestParser.parse_from_bundle(@fixture_bundle)

    assert manifest.tokenizer.config_path == "tokenizer_config.json"
    assert manifest.safe_tokenization.control_tokens == []

    assert manifest.safe_tokenization.catalog_sha256 ==
             "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    assert manifest.safe_tokenization.catalog_source.extra_count == 0
  end

  test "SPEC 6.4 parser accepts compatible optional safe-tokenization metadata literal" do
    control_tokens = ["<extra>", "<|im_end|>", "<|im_start|>"]

    json =
      base_manifest_map()
      |> Map.put("safe_tokenization", %{
        "control_tokens" => control_tokens,
        "extra_control_token_strings" => ["<extra>"],
        "catalog_sha256" => hash_catalog(control_tokens),
        "catalog_source" => %{
          "added_tokens_count" => 1,
          "additional_special_tokens_count" => 1,
          "chat_template_literals_count" => 1,
          "config_singletons_count" => 1,
          "extra_count" => 1,
          "wrapper_tool_markers_count" => 1
        },
        "compatible" => true,
        "template_compatible" => true
      })
      |> Jason.encode!()

    assert {:ok, %ModelManifest{} = manifest} = ManifestParser.parse_json(json)
    assert manifest.safe_tokenization.control_tokens == control_tokens
    assert manifest.safe_tokenization.extra_control_token_strings == ["<extra>"]
    assert manifest.safe_tokenization.catalog_source.extra_count == 1
    assert manifest.safe_tokenization.preflight_compatible_declared?
  end

  test "SPEC 6.4 parser accepts incompatible dual-render verdict literal" do
    control_tokens = ["</s>", "<s>"]

    json =
      base_manifest_map()
      |> Map.put("safe_tokenization", %{
        "control_tokens" => control_tokens,
        "catalog_sha256" => hash_catalog(control_tokens),
        "catalog_source" => %{
          "added_tokens_count" => 2,
          "additional_special_tokens_count" => 0,
          "chat_template_literals_count" => 0,
          "config_singletons_count" => 0,
          "extra_count" => 0,
          "wrapper_tool_markers_count" => 0
        },
        "compatible" => false,
        "template_compatible" => false,
        "incompatibility_reason" => %{
          "category" => "dual_render_mismatch",
          "first_diff_offset" => 12,
          "leaf_class" => "messages[0].content",
          "sentinel_index" => 0
        }
      })
      |> Jason.encode!()

    assert {:ok, %ModelManifest{} = manifest} = ManifestParser.parse_json(json)
    assert manifest.safe_tokenization.compatible == false
    assert manifest.safe_tokenization.template_compatible == false

    assert manifest.safe_tokenization.incompatibility_reason.category ==
             "dual_render_mismatch"

    assert manifest.safe_tokenization.incompatibility_reason.leaf_class ==
             "messages[0].content"

    assert manifest.safe_tokenization.incompatibility_reason.sentinel_index == 0
    assert manifest.safe_tokenization.incompatibility_reason.first_diff_offset == 12
  end

  defp parser_contract_key_sets do
    schema_keys = ManifestParser.schema_keys()

    %{
      "top_level_keys" => schema_keys.top_level_keys,
      "nested_keys" => %{
        "chat_template" => schema_keys.nested_keys.chat_template,
        "runtime_requirements" => schema_keys.nested_keys.runtime_requirements,
        "safe_tokenization" => schema_keys.nested_keys.safe_tokenization,
        "safe_tokenization.catalog_source" =>
          schema_keys.nested_keys.safe_tokenization_catalog_source,
        "safe_tokenization.incompatibility_reason" =>
          schema_keys.nested_keys.safe_tokenization_incompatibility_reason,
        "tokenizer" => schema_keys.nested_keys.tokenizer
      }
    }
  end

  defp load_contract! do
    @contract_path
    |> File.read!()
    |> Jason.decode!()
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
        "path" => "tokenizer.json",
        "config_path" => "tokenizer_config.json"
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

  defp hash_catalog(control_tokens) do
    control_tokens
    |> Enum.intersperse(<<0>>)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
