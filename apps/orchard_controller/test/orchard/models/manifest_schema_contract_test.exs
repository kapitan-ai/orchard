defmodule Orchard.Models.ManifestSchemaContractTest do
  use ExUnit.Case, async: true

  alias Orchard.ModelManifest
  alias Orchard.Models.{ManifestParser, SafeTokenizationPreflight}
  alias Orchard.Tokenizer.Client, as: TokenizerClient

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

  test "SPEC 6.4 top-level manifest fields distinguish required optional and deprecated keys" do
    contract = load_contract!()

    assert contract["required_top_level_keys"] ==
             ~w(artifact_layout capabilities entrypoint format model_id runtime_requirements tokenizer version)

    assert contract["optional_top_level_keys"] ==
             ~w(chat_template kv_cache_bytes_per_token max_context_tokens prefill_workspace_bytes_per_token resident_memory_bytes safe_tokenization sha256 size_bytes)

    assert contract["deprecated_top_level_keys"] == ["sha256"]

    assert Enum.sort(contract["required_top_level_keys"] ++ contract["optional_top_level_keys"]) ==
             contract["top_level_keys"]
  end

  test "SPEC 6.4 safe-tokenization incompatibility category enum contract is sorted and partitioned" do
    contract = load_contract!()
    category_sets = contract_category_sets(contract)

    assert contract["version"] == 1

    assert contract["category_enums"] |> Map.keys() |> Enum.sort() == [
             "safe_tokenization.incompatibility_reason.category",
             "safe_tokenization.incompatibility_reason.template_categories",
             "safe_tokenization.incompatibility_reason.tokenizer_categories"
           ]

    Enum.each(category_sets, fn {_name, categories} ->
      assert categories == Enum.sort(categories)
    end)

    assert category_sets.all ==
             category_sets.tokenizer
             |> MapSet.new()
             |> MapSet.union(MapSet.new(category_sets.template))
             |> MapSet.to_list()
             |> Enum.sort()

    assert MapSet.disjoint?(
             MapSet.new(category_sets.tokenizer),
             MapSet.new(category_sets.template)
           )
  end

  test "SPEC 6.4 safe-tokenization incompatibility required-field contract is sorted and complete" do
    contract = load_contract!()
    category_sets = contract_category_sets(contract)
    required_fields = contract_required_fields(contract)

    assert required_fields |> Map.keys() |> Enum.sort() == category_sets.all
    assert Map.keys(required_fields) == required_fields |> Map.keys() |> Enum.sort()

    Enum.each(required_fields, fn {_category, fields} ->
      assert fields == Enum.sort(fields)
    end)

    assert required_fields == %{
             "dual_render_mismatch" => [
               "category",
               "first_diff_offset",
               "leaf_class",
               "sentinel_index"
             ],
             "empty_literal" => ["category", "literal"],
             "per_codepoint_decode_mismatch" => ["category", "literal"],
             "reserved_id_persists" => ["category", "literal"],
             "reserved_id_set_overlap" => ["category", "literal"]
           }
  end

  test "SPEC 6.4 Elixir safe-tokenization incompatibility category owners match the shared contract" do
    contract_sets = load_contract!() |> contract_category_sets()

    assert ManifestParser.incompatibility_reason_category_sets() == contract_sets
    assert SafeTokenizationPreflight.incompatibility_reason_category_sets() == contract_sets
    assert TokenizerClient.incompatibility_reason_category_sets() == contract_sets
  end

  test "SPEC 6.4 Elixir safe-tokenization incompatibility semantic rules preserve verdict parity" do
    contract = load_contract!()
    category_sets = contract_category_sets(contract)
    required_fields = contract_required_fields(contract)
    rule_maps = verdict_rule_maps()

    assert Keyword.keys(rule_maps) == [:manifest, :helper_preflight, :runtime_success]

    assert Enum.map(rule_maps, fn {_owner, rules} ->
             Map.take(rules, [:path, :reason_key_encoding])
           end) == [
             %{path: :manifest_verdict, reason_key_encoding: :atom},
             %{path: :helper_preflight_verdict, reason_key_encoding: :string},
             %{path: :runtime_success_verdict, reason_key_encoding: :string}
           ]

    Enum.each(rule_maps, fn {_owner, rules} ->
      categories = Map.fetch!(rules, :categories)
      assert categories |> Map.keys() |> Enum.sort() == category_sets.all

      Enum.each(categories, fn {category, rule} ->
        assert Map.fetch!(rule, :required) == Map.fetch!(required_fields, category)
        assert Map.fetch!(rule, :required) == rule |> Map.fetch!(:required) |> Enum.sort()
      end)
    end)

    Enum.each(category_sets.all, fn category ->
      required_field_sets =
        Enum.map(rule_maps, fn {_owner, rules} ->
          rules
          |> Map.fetch!(:categories)
          |> Map.fetch!(category)
          |> Map.fetch!(:required)
        end)

      assert Enum.uniq(required_field_sets) == [Map.fetch!(required_fields, category)]

      predicate_sets =
        Enum.map(rule_maps, fn {_owner, rules} ->
          rules
          |> Map.fetch!(:categories)
          |> Map.fetch!(category)
          |> Map.drop([:required, :template_compatible])
        end)

      assert Enum.uniq(predicate_sets) == [List.first(predicate_sets)]
    end)

    rule_maps_by_owner = Map.new(rule_maps)

    manifest_categories = rule_maps_by_owner |> Map.fetch!(:manifest) |> Map.fetch!(:categories)

    helper_categories =
      rule_maps_by_owner |> Map.fetch!(:helper_preflight) |> Map.fetch!(:categories)

    runtime_categories =
      rule_maps_by_owner |> Map.fetch!(:runtime_success) |> Map.fetch!(:categories)

    Enum.each([manifest_categories, helper_categories, runtime_categories], fn categories ->
      assert get_in(categories, ["empty_literal", :literal]) == :equals_empty_string

      Enum.each(category_sets.tokenizer -- ["empty_literal"], fn category ->
        assert get_in(categories, [category, :literal]) == :non_empty_binary
      end)

      assert Map.take(Map.fetch!(categories, "dual_render_mismatch"), [
               :template_compatible,
               :leaf_class,
               :sentinel_index,
               :first_diff_offset
             ]) == %{
               template_compatible: :equals_false,
               leaf_class: :non_empty_binary,
               sentinel_index: :non_negative_integer,
               first_diff_offset: :non_negative_integer
             }
    end)

    Enum.each(category_sets.tokenizer, fn category ->
      assert get_in(manifest_categories, [category, :template_compatible]) == :not_false
      assert get_in(helper_categories, [category, :template_compatible]) == :equals_true
      assert get_in(runtime_categories, [category, :template_compatible]) == :equals_true
    end)

    assert Map.fetch!(manifest_categories, "dual_render_mismatch") ==
             Map.fetch!(helper_categories, "dual_render_mismatch")

    assert Map.fetch!(helper_categories, "dual_render_mismatch") ==
             Map.fetch!(runtime_categories, "dual_render_mismatch")

    rejected_categories = helper_diagnostics() ++ error_envelope_categories()

    Enum.each(rule_maps, fn {_owner, rules} ->
      categories = Map.fetch!(rules, :categories)
      assert Enum.all?(rejected_categories, &(&1 not in Map.keys(categories)))
    end)
  end

  test "SPEC 6.4 diagnostic and error-envelope categories are not manifest verdict categories" do
    contract_sets = load_contract!() |> contract_category_sets()

    helper_diagnostics = ~w(
      marker_collision
      marker_walk_mismatch
      catalog_hash_mismatch
    )

    error_envelope_categories = ~w(
      safe_tokenization_incompatible_tokenizer
      safe_tokenization_incompatible_template
      safe_tokenization_marker_collision
      safe_tokenization_catalog_hash_mismatch
    )

    rejected_categories = helper_diagnostics ++ error_envelope_categories

    assert Enum.all?(rejected_categories, &(&1 not in contract_sets.all))

    Enum.each(helper_diagnostics, fn category ->
      json =
        category
        |> incompatible_manifest_with_category()
        |> Jason.encode!()

      assert {:error, {:validation, "incompatibility_reason.category is invalid"}} =
               ManifestParser.parse_json(json)
    end)
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

  test "SPEC 6.4 keeps capability evidence out of the N-1 worker manifest schema" do
    json =
      base_manifest_map()
      |> Map.put("capability_evidence", tool_capability_evidence("declared"))
      |> Jason.encode!()

    assert {:error, {:validation, message}} = ManifestParser.parse_json(json)
    assert message =~ "unknown manifest keys"
  end

  test "SPEC 6.4 a structurally valid declared sidecar cannot replace missing artifacts" do
    bundle_path =
      Path.join(System.tmp_dir!(), "manifest-schema-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bundle_path)

    on_exit(fn -> File.rm_rf!(bundle_path) end)

    File.write!(
      Path.join(bundle_path, "manifest.json"),
      base_manifest_map()
      |> Map.put("capabilities", ["chat", "tool_calling"])
      |> Jason.encode!()
    )

    File.write!(
      Path.join(bundle_path, "tool_capability_evidence.json"),
      Jason.encode!(tool_capability_evidence("declared"))
    )

    assert {:error, {:validation, message}} = ManifestParser.parse_from_bundle(bundle_path)
    assert message =~ "does not verify against bundle artifacts"
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

  defp tool_capability_evidence("declared") do
    %{
      "tool_calling" => %{
        "source_repository" => "mlx-community/example",
        "source_revision" => "0123456789abcdef",
        "base_model_refs" => ["upstream/example"],
        "tokenizer_config_sha256" => String.duplicate("a", 64),
        "chat_template_sha256" => String.duplicate("b", 64),
        "tool_parser_type" => "glm47",
        "preflight" => %{
          "parser_recognized" => true,
          "definition_rendered" => true,
          "history_rendered" => true
        },
        "result" => "declared",
        "runtime_qualification" => "not_established"
      }
    }
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

  defp contract_category_sets(contract) do
    category_enums = Map.fetch!(contract, "category_enums")

    %{
      all: Map.fetch!(category_enums, "safe_tokenization.incompatibility_reason.category"),
      tokenizer:
        Map.fetch!(
          category_enums,
          "safe_tokenization.incompatibility_reason.tokenizer_categories"
        ),
      template:
        Map.fetch!(
          category_enums,
          "safe_tokenization.incompatibility_reason.template_categories"
        )
    }
  end

  defp contract_required_fields(contract), do: Map.fetch!(contract, "category_required_fields")

  defp verdict_rule_maps do
    [
      manifest: ManifestParser.incompatibility_reason_rules(),
      helper_preflight: SafeTokenizationPreflight.incompatibility_reason_rules(),
      runtime_success: TokenizerClient.incompatibility_reason_rules()
    ]
  end

  defp helper_diagnostics do
    ~w(
      marker_collision
      marker_walk_mismatch
      catalog_hash_mismatch
    )
  end

  defp error_envelope_categories do
    ~w(
      safe_tokenization_incompatible_tokenizer
      safe_tokenization_incompatible_template
      safe_tokenization_marker_collision
      safe_tokenization_catalog_hash_mismatch
    )
  end

  defp incompatible_manifest_with_category(category) do
    control_tokens = ["</s>", "<s>"]

    Map.put(base_manifest_map(), "safe_tokenization", %{
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
      "template_compatible" => true,
      "incompatibility_reason" => %{
        "category" => category,
        "literal" => "<s>"
      }
    })
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
