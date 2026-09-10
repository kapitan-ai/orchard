defmodule Orchard.Models.ImporterTest do
  use Orchard.DataCase, async: false

  alias Orchard.Models
  alias Orchard.Models.BundleBuilder
  alias Orchard.Models.Importer
  alias Orchard.Models.ManifestParser

  @fixture_bundle Path.expand("../../fixtures/bundles/test-model-bundle", __DIR__)

  setup do
    artifacts_root =
      System.tmp_dir!()
      |> Path.join("orchard_importer_test_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(artifacts_root)

    on_exit(fn -> File.rm_rf!(artifacts_root) end)

    %{artifacts_root: artifacts_root}
  end

  describe "import_bundle/2" do
    test "imports a valid bundle as :registered", %{artifacts_root: artifacts_root} do
      assert {:ok, model} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: artifacts_root)

      assert model.model_id == "test-org/tiny-llm"
      assert model.version == "mlx-q4-v1"
      assert model.state == :registered
      assert model.format == "mlx"
      assert model.capabilities == ["chat"]
      assert model.max_context_tokens == 4_096

      # SHA-256 is computed, not from manifest
      assert is_binary(model.artifact_sha256)
      assert String.length(model.artifact_sha256) == 64
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, model.artifact_sha256)

      assert model.artifact_uri ==
               "file://#{Path.join([artifacts_root, "test-org/tiny-llm", "mlx-q4-v1"])}"

      assert model.artifact_source_uri == model.artifact_uri

      dest = Path.join([artifacts_root, "test-org/tiny-llm", "mlx-q4-v1"])
      assert File.exists?(Path.join(dest, "manifest.json"))
      assert File.exists?(Path.join(dest, "tokenizer.json"))
      assert File.exists?(Path.join(dest, "weights/model.safetensors"))
    end

    test "imports with --activate sets state to :active", %{artifacts_root: artifacts_root} do
      assert {:ok, model} =
               Importer.import_bundle(@fixture_bundle,
                 artifacts_root: artifacts_root,
                 activate: true
               )

      assert model.state == :active

      # Should show up in active models list
      active = Models.list_active_models()
      assert length(active) == 1
      assert hd(active).id == model.id
    end

    test "rejects duplicate model_id + version", %{artifacts_root: artifacts_root} do
      assert {:ok, _model} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: artifacts_root)

      assert {:error, {:duplicate, message}} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: artifacts_root)

      assert message =~ "test-org/tiny-llm@mlx-q4-v1"
      assert message =~ "already exists"
    end

    test "keeps an imported tuple immutable and admits a capability repair only at a new version",
         %{
           artifacts_root: artifacts_root
         } do
      original_bundle =
        create_bundle(artifacts_root, %{
          "capability_evidence" => tool_capability_evidence("unknown"),
          "version" => "mlx-q4-v1"
        })

      assert {:ok, original} =
               Importer.import_bundle(original_bundle, artifacts_root: artifacts_root)

      original_manifest = read_imported_manifest!(original)

      duplicate_bundle =
        create_bundle(artifacts_root, %{
          "capabilities" => ["chat", "tool_calling"],
          "capability_evidence" => tool_capability_evidence("declared"),
          "version" => "mlx-q4-v1"
        })

      assert {:error, {:duplicate, _message}} =
               Importer.import_bundle(duplicate_bundle, artifacts_root: artifacts_root)

      assert read_imported_manifest!(original) == original_manifest

      repaired_bundle =
        create_bundle(artifacts_root, %{
          "capabilities" => ["chat", "tool_calling"],
          "capability_evidence" => tool_capability_evidence("declared"),
          "version" => "mlx-q4-v1-tool-admission"
        })

      assert {:ok, repaired} =
               Importer.import_bundle(repaired_bundle, artifacts_root: artifacts_root)

      assert repaired.version == "mlx-q4-v1-tool-admission"
      assert repaired.capabilities == ["chat", "tool_calling"]

      refute Map.has_key?(read_imported_manifest!(repaired), "capability_evidence")
      assert repaired.capability_evidence["tool_calling"]["result"] == "declared"

      assert read_imported_tool_capability_evidence!(repaired)["tool_calling"]["result"] ==
               "declared"
    end

    test "rejects nonexistent source path", %{artifacts_root: artifacts_root} do
      assert {:error, {:source_not_found, "/nonexistent/path"}} =
               Importer.import_bundle("/nonexistent/path", artifacts_root: artifacts_root)
    end

    test "rejects source that is a file instead of directory", %{artifacts_root: artifacts_root} do
      file_path = Path.join(artifacts_root, "not_a_dir.txt")
      File.write!(file_path, "hi")

      assert {:error, {:source_not_directory, message}} =
               Importer.import_bundle(file_path, artifacts_root: artifacts_root)

      assert message =~ "expected a directory"
    end

    test "rejects bundle without manifest.json", %{artifacts_root: artifacts_root} do
      empty_bundle = Path.join(artifacts_root, "empty_bundle")
      File.mkdir_p!(empty_bundle)

      assert {:error, {:manifest_not_found, _path}} =
               Importer.import_bundle(empty_bundle, artifacts_root: artifacts_root)
    end

    test "imported model is visible via list when active", %{artifacts_root: artifacts_root} do
      assert {:ok, _model} =
               Importer.import_bundle(@fixture_bundle,
                 artifacts_root: artifacts_root,
                 activate: true
               )

      models = Models.list_active_models()
      assert length(models) == 1

      model = hd(models)
      assert model.model_id == "test-org/tiny-llm"
      assert model.version == "mlx-q4-v1"
    end

    test "registered model is not visible in active list", %{artifacts_root: artifacts_root} do
      assert {:ok, _model} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: artifacts_root)

      assert Models.list_active_models() == []
    end

    test "SHA-256 is deterministic across imports with different staging paths", %{
      artifacts_root: artifacts_root
    } do
      # Import the same bundle into two separate roots. The random staging-*
      # directory name must NOT leak into the hash.
      root2 =
        System.tmp_dir!()
        |> Path.join("orchard_sha_test_#{:rand.uniform(1_000_000)}")

      File.mkdir_p!(root2)
      on_exit(fn -> File.rm_rf!(root2) end)

      assert {:ok, m1} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: artifacts_root)

      # Delete the catalog record so the duplicate check passes for the second import
      Orchard.Repo.delete!(m1)

      assert {:ok, m2} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: root2)

      assert m1.artifact_sha256 == m2.artifact_sha256
    end

    test "no staging directory remains on success", %{artifacts_root: artifacts_root} do
      assert {:ok, _model} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: artifacts_root)

      staging_dirs =
        artifacts_root
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, ".staging-"))

      assert staging_dirs == []
    end

    test "imports bundle-builder derived kv_cache_bytes_per_token", %{
      artifacts_root: artifacts_root
    } do
      source_dir = new_source_dir(artifacts_root)

      write_bundle_builder_input(source_dir, %{
        "max_position_embeddings" => 4096,
        "num_hidden_layers" => 24,
        "num_attention_heads" => 64,
        "num_key_value_heads" => 16,
        "head_dim" => 32,
        "torch_dtype" => "float16"
      })

      assert {:ok, _bundle_dir} =
               BundleBuilder.prepare_bundle(source_dir, "mlx-community/test-model", %{
                 revision_sha: "rev-a"
               })

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(source_dir)
      assert manifest.kv_cache_bytes_per_token == 49_152

      assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
      assert model.kv_cache_bytes_per_token == 49_152
    end

    test "imports bundle-builder fail-open kv_cache_bytes_per_token=0 when unknown", %{
      artifacts_root: artifacts_root
    } do
      source_dir = new_source_dir(artifacts_root)

      write_bundle_builder_input(source_dir, %{
        "max_position_embeddings" => 4096,
        "num_attention_heads" => 64,
        "num_key_value_heads" => 16,
        "head_dim" => 32,
        "torch_dtype" => "float16"
      })

      assert {:ok, _bundle_dir} =
               BundleBuilder.prepare_bundle(source_dir, "mlx-community/test-model", %{
                 revision_sha: "rev-b"
               })

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(source_dir)
      assert manifest.kv_cache_bytes_per_token == 0

      assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
      assert model.kv_cache_bytes_per_token == 0
    end

    test "imports SPEC.md §6.4 bundle-builder derived resident_memory_bytes", %{
      artifacts_root: artifacts_root
    } do
      source_dir = new_source_dir(artifacts_root)

      write_bundle_builder_input(source_dir, %{"max_position_embeddings" => 4096})
      write_safetensors_index(source_dir, %{"metadata" => %{"total_size" => 6_442_450_944}})

      assert {:ok, _bundle_dir} =
               BundleBuilder.prepare_bundle(source_dir, "mlx-community/test-model", %{
                 revision_sha: "rev-resident"
               })

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(source_dir)
      assert manifest.resident_memory_bytes == 6_442_450_944

      assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
      assert model.resident_memory_bytes == 6_442_450_944
    end

    test "imports SPEC.md §6.4 fail-open resident_memory_bytes=0 when unknown", %{
      artifacts_root: artifacts_root
    } do
      source_dir = new_source_dir(artifacts_root)

      write_bundle_builder_input(source_dir, %{"max_position_embeddings" => 4096})
      File.rm!(Path.join(source_dir, "model.safetensors"))

      assert {:ok, _bundle_dir} =
               BundleBuilder.prepare_bundle(source_dir, "mlx-community/test-model", %{
                 revision_sha: "rev-resident-zero"
               })

      assert {:ok, manifest} = ManifestParser.parse_from_bundle(source_dir)
      assert manifest.resident_memory_bytes == 0

      assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
      assert model.resident_memory_bytes == 0
    end

    test "imports SPEC.md §6.4 CLI path tops up resident_memory_bytes from estimator and keeps DB aligned",
         %{artifacts_root: artifacts_root} do
      source_dir = create_bundle(artifacts_root, %{"resident_memory_bytes" => 0})
      write_estimator_index(source_dir, 6_442_450_944)

      assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
      assert model.resident_memory_bytes == 6_442_450_944

      imported_bundle_path = artifact_path(model)
      assert {:ok, imported_manifest} = ManifestParser.parse_from_bundle(imported_bundle_path)
      assert imported_manifest.resident_memory_bytes == 6_442_450_944

      persisted_model = Models.get_model!(model.id)
      assert persisted_model.resident_memory_bytes == imported_manifest.resident_memory_bytes
    end

    test "imports SPEC.md §6.4 CLI path fail-open when resident estimator is unknown", %{
      artifacts_root: artifacts_root
    } do
      source_dir = create_bundle(artifacts_root, %{"resident_memory_bytes" => 0})

      assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
      assert model.resident_memory_bytes == 0

      imported_bundle_path = artifact_path(model)
      assert {:ok, imported_manifest} = ManifestParser.parse_from_bundle(imported_bundle_path)
      assert imported_manifest.resident_memory_bytes == 0
    end

    test "imports SPEC.md §6.4 CLI path tops up omitted resident_memory_bytes key from estimator",
         %{artifacts_root: artifacts_root} do
      source_dir = create_bundle_with_manifest(artifacts_root, base_manifest_without_resident())
      write_estimator_index(source_dir, 6_442_450_944)

      assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
      assert model.resident_memory_bytes == 6_442_450_944

      imported_bundle_path = artifact_path(model)
      assert {:ok, imported_manifest} = ManifestParser.parse_from_bundle(imported_bundle_path)
      assert imported_manifest.resident_memory_bytes == 6_442_450_944

      persisted_model = Models.get_model!(model.id)
      assert persisted_model.resident_memory_bytes == imported_manifest.resident_memory_bytes
    end

    test "imports SPEC.md §6.4 CLI path normalizes omitted resident_memory_bytes key to 0 when estimator is unknown",
         %{artifacts_root: artifacts_root} do
      source_dir = create_bundle_with_manifest(artifacts_root, base_manifest_without_resident())

      assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
      assert model.resident_memory_bytes == 0

      imported_bundle_path = artifact_path(model)
      assert {:ok, imported_manifest} = ManifestParser.parse_from_bundle(imported_bundle_path)
      assert imported_manifest.resident_memory_bytes == 0

      persisted_model = Models.get_model!(model.id)
      assert persisted_model.resident_memory_bytes == 0
    end

    test "auto-fills missing chat_template from chat_template.jinja for chat bundles", %{
      artifacts_root: artifacts_root
    } do
      template = "{{ messages[0].content }}"
      expected_sha = hash_string(template)

      source_dir =
        create_bundle_with_manifest(
          artifacts_root,
          base_manifest_without_resident()
          |> Map.put("version", "chat-template-autofill")
          |> Map.put("entrypoint", ".")
        )

      File.write!(Path.join(source_dir, "tokenizer.json"), ~s({"version":"1.0"}))
      File.write!(Path.join(source_dir, "chat_template.jinja"), template)
      File.write!(Path.join(source_dir, "model.safetensors"), "fake-weights")

      assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

      imported = read_imported_manifest!(model)
      assert imported["chat_template"]["path"] == "chat_template.jinja"
      assert imported["chat_template"]["sha256"] == expected_sha
    end

    test "auto-fills missing chat_template from tokenizer_config.json for chat bundles", %{
      artifacts_root: artifacts_root
    } do
      template = "{{ messages[0].content }}"
      expected_sha = hash_string(template)

      source_dir = Path.join(artifacts_root, "chat_template_from_tokenizer_config")
      File.mkdir_p!(source_dir)

      File.write!(
        Path.join(source_dir, "manifest.json"),
        Jason.encode!(
          base_manifest_without_resident()
          |> Map.put("version", "chat-template-from-config")
          |> Map.put("entrypoint", ".")
        )
      )

      File.write!(Path.join(source_dir, "tokenizer.json"), ~s({"version":"1.0"}))

      File.write!(
        Path.join(source_dir, "tokenizer_config.json"),
        Jason.encode!(%{"chat_template" => template})
      )

      File.write!(Path.join(source_dir, "model.safetensors"), "fake-weights")

      assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

      imported = read_imported_manifest!(model)
      assert imported["chat_template"]["path"] == "chat_template.jinja"
      assert imported["chat_template"]["sha256"] == expected_sha
      assert File.exists?(Path.join(artifact_path(model), "chat_template.jinja"))
    end

    test "fails closed when chat bundle has no resolvable chat_template", %{
      artifacts_root: artifacts_root
    } do
      source_dir = Path.join(artifacts_root, "chat_template_missing_bundle")
      File.mkdir_p!(source_dir)

      File.write!(
        Path.join(source_dir, "manifest.json"),
        Jason.encode!(
          base_manifest_without_resident()
          |> Map.put("version", "chat-template-missing")
          |> Map.put("entrypoint", ".")
        )
      )

      File.write!(Path.join(source_dir, "tokenizer.json"), ~s({"version":"1.0"}))
      File.write!(Path.join(source_dir, "model.safetensors"), "fake-weights")

      assert {:error, {:missing_chat_template, message}} =
               Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

      assert message =~ "chat_template"
      assert staging_dirs_under(artifacts_root) == []
    end

    test "eager preflight writes compatibility fields on import", %{
      artifacts_root: artifacts_root
    } do
      source_dir = create_safe_bundle(artifacts_root)
      write_tokenizer_config!(source_dir)
      helper = write_preflight_helper!(artifacts_root, compatible_preflight_response())

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

        imported_manifest = read_imported_manifest!(model)
        assert imported_manifest["safe_tokenization"]["compatible"] == true
        assert imported_manifest["safe_tokenization"]["template_compatible"] == true
        refute Map.has_key?(imported_manifest["safe_tokenization"], "incompatibility_reason")
      end)
    end

    test "eager preflight uses sibling tokenizer_config fallback during import", %{
      artifacts_root: artifacts_root
    } do
      source_dir = create_safe_bundle(artifacts_root)
      write_tokenizer_config!(source_dir)

      invocation_marker = Path.join(artifacts_root, "sibling-fallback-helper-invoked")

      helper =
        write_tokenizer_config_required_preflight_helper!(
          artifacts_root,
          compatible_preflight_response(),
          invocation_marker
        )

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

        imported_manifest = read_imported_manifest!(model)
        assert imported_manifest["safe_tokenization"]["compatible"] == true
        assert imported_manifest["safe_tokenization"]["template_compatible"] == true
        assert File.exists?(invocation_marker)
      end)
    end

    test "eager preflight merge rollback emits bundle_preflight error telemetry", %{
      artifacts_root: artifacts_root
    } do
      source_dir = create_safe_bundle(artifacts_root)
      write_tokenizer_config!(source_dir)

      helper =
        write_readonly_manifest_preflight_helper!(artifacts_root, compatible_preflight_response())

      event_ref = attach_telemetry([:orchard, :tokenizer, :bundle_preflight, :error])

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:error,
                {:safe_tokenization_preflight_rollback_failed, {:manifest_write, message}}} =
                 Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

        assert message =~ "failed to write"

        assert_receive {^event_ref, [:orchard, :tokenizer, :bundle_preflight, :error],
                        measurements, metadata}

        assert measurements.count == 1
        assert measurements.duration_ms == 0
        assert is_integer(measurements.manifest_json_bytes)
        assert metadata.reason == :merge_validation_failed
        assert metadata.stage == :write_or_reparse
        assert metadata.tokenizer_kind == "huggingface_tokenizer_json"
        assert metadata.details.kind == :manifest_write
        assert is_binary(metadata.details.detail)
      end)
    end

    test "eager preflight aborts when trust disabled authored positive helper verdict cannot be persisted",
         %{artifacts_root: artifacts_root} do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "safe_tokenization" => authored_positive_safe_tokenization_map()
        })

      write_tokenizer_config!(source_dir)

      helper =
        write_readonly_manifest_preflight_helper!(artifacts_root, compatible_preflight_response())

      with_app_env(:trust_manifest_compatibility_declarations, false, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:error,
                  {:safe_tokenization_untrusted_verdict_strip_failed,
                   {:write_or_reparse, {:error, {:manifest_write, message}}}}} =
                   Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

          assert message =~ "failed to write"
          assert staging_dirs_under(artifacts_root) == []
        end)
      end)
    end

    test "eager preflight restore rollback failure cleans staging directory", %{
      artifacts_root: artifacts_root
    } do
      source_dir = create_safe_bundle(artifacts_root)
      write_tokenizer_config!(source_dir)

      helper = write_mutating_readonly_manifest_preflight_helper!(artifacts_root)

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:error,
                {:safe_tokenization_preflight_rollback_failed, {:manifest_write, message}}} =
                 Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

        assert message =~ "failed to write"
        assert staging_dirs_under(artifacts_root) == []
      end)
    end

    test "eager preflight preserves declared compatible false", %{artifacts_root: artifacts_root} do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "safe_tokenization" =>
            Map.merge(safe_tokenization_map(), %{
              "compatible" => false,
              "template_compatible" => true,
              "incompatibility_reason" => %{
                "category" => "reserved_id_persists",
                "literal" => "<reserved>"
              }
            })
        })

      with_inference_overrides(
        [tokenizer_executable: Path.join(artifacts_root, "missing-helper")],
        fn ->
          assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

          imported_manifest = read_imported_manifest!(model)
          assert imported_manifest["safe_tokenization"]["compatible"] == false
          assert imported_manifest["safe_tokenization"]["template_compatible"] == true

          assert imported_manifest["safe_tokenization"]["incompatibility_reason"] == %{
                   "category" => "reserved_id_persists",
                   "literal" => "<reserved>"
                 }
        end
      )
    end

    test "eager preflight skips explicit positive verdict", %{artifacts_root: artifacts_root} do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "safe_tokenization" =>
            Map.merge(safe_tokenization_map(), %{
              "compatible" => true,
              "template_compatible" => true
            })
        })

      with_inference_overrides(
        [tokenizer_executable: Path.join(artifacts_root, "missing-helper")],
        fn ->
          assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

          imported_manifest = read_imported_manifest!(model)
          assert imported_manifest["safe_tokenization"]["compatible"] == true
          assert imported_manifest["safe_tokenization"]["template_compatible"] == true
        end
      )
    end

    test "eager preflight revalidates explicit positive verdict when trust is disabled", %{
      artifacts_root: artifacts_root
    } do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "safe_tokenization" =>
            Map.merge(safe_tokenization_map(), %{
              "compatible" => true,
              "template_compatible" => true
            })
        })

      write_tokenizer_config!(source_dir)
      helper = write_preflight_helper!(artifacts_root, incompatible_preflight_response())

      with_app_env(:trust_manifest_compatibility_declarations, false, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

          imported_manifest = read_imported_manifest!(model)
          assert imported_manifest["safe_tokenization"]["compatible"] == false
          assert imported_manifest["safe_tokenization"]["template_compatible"] == true

          assert imported_manifest["safe_tokenization"]["incompatibility_reason"] == %{
                   "category" => "reserved_id_persists",
                   "literal" => "<reserved>"
                 }
        end)
      end)
    end

    test "eager preflight strips authored positive verdict when trust is disabled and helper is missing",
         %{artifacts_root: artifacts_root} do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "safe_tokenization" => authored_positive_safe_tokenization_map()
        })

      write_tokenizer_config!(source_dir)

      with_app_env(:trust_manifest_compatibility_declarations, false, fn ->
        with_inference_overrides(
          [tokenizer_executable: Path.join(artifacts_root, "missing-helper")],
          fn ->
            assert {:ok, model} =
                     Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

            assert_safe_tokenization_verdict_fields_omitted!(model)
          end
        )
      end)
    end

    test "eager preflight strips compatible-only positive verdict when trust is disabled and helper is missing",
         %{artifacts_root: artifacts_root} do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "safe_tokenization" => Map.put(safe_tokenization_map(), "compatible", true)
        })

      write_tokenizer_config!(source_dir)

      with_app_env(:trust_manifest_compatibility_declarations, false, fn ->
        with_inference_overrides(
          [tokenizer_executable: Path.join(artifacts_root, "missing-helper")],
          fn ->
            assert {:ok, model} =
                     Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

            assert_safe_tokenization_verdict_fields_omitted!(model)
          end
        )
      end)
    end

    test "eager preflight strips template-only positive verdict when trust is disabled and helper success is invalid",
         %{artifacts_root: artifacts_root} do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "safe_tokenization" => Map.put(safe_tokenization_map(), "template_compatible", true)
        })

      write_tokenizer_config!(source_dir)
      helper = write_preflight_helper!(artifacts_root, invalid_preflight_response())

      with_app_env(:trust_manifest_compatibility_declarations, false, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
          assert_safe_tokenization_verdict_fields_omitted!(model)
        end)
      end)
    end

    test "eager preflight preserves helper-confirmed compatible verdict when trust is disabled",
         %{artifacts_root: artifacts_root} do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "safe_tokenization" => Map.put(safe_tokenization_map(), "compatible", true)
        })

      write_tokenizer_config!(source_dir)
      helper = write_preflight_helper!(artifacts_root, compatible_preflight_response())

      with_app_env(:trust_manifest_compatibility_declarations, false, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

          imported_manifest = read_imported_manifest!(model)
          assert imported_manifest["safe_tokenization"]["compatible"] == true
          assert imported_manifest["safe_tokenization"]["template_compatible"] == true
          refute Map.has_key?(imported_manifest["safe_tokenization"], "incompatibility_reason")
        end)
      end)
    end

    test "eager preflight strips authored positive verdict when trust is disabled and tokenizer config is missing",
         %{artifacts_root: artifacts_root} do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "safe_tokenization" => authored_positive_safe_tokenization_map()
        })

      helper = write_preflight_helper!(artifacts_root, compatible_preflight_response())

      with_app_env(:trust_manifest_compatibility_declarations, false, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
          assert_safe_tokenization_verdict_fields_omitted!(model)
        end)
      end)
    end

    test "eager preflight strips authored positive verdict when trust is disabled and helper success is invalid",
         %{artifacts_root: artifacts_root} do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "safe_tokenization" => authored_positive_safe_tokenization_map()
        })

      write_tokenizer_config!(source_dir)
      helper = write_preflight_helper!(artifacts_root, invalid_preflight_response())

      with_app_env(:trust_manifest_compatibility_declarations, false, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
          assert_safe_tokenization_verdict_fields_omitted!(model)
        end)
      end)
    end

    test "eager preflight strips authored positive verdict when trust is disabled and helper returns error",
         %{artifacts_root: artifacts_root} do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "safe_tokenization" => authored_positive_safe_tokenization_map()
        })

      write_tokenizer_config!(source_dir)
      helper = write_preflight_helper!(artifacts_root, helper_error_preflight_response())

      with_app_env(:trust_manifest_compatibility_declarations, false, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
          assert_safe_tokenization_verdict_fields_omitted!(model)
        end)
      end)
    end

    test "eager preflight strips authored positive verdict when trust is disabled and helper times out",
         %{artifacts_root: artifacts_root} do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "safe_tokenization" => authored_positive_safe_tokenization_map()
        })

      write_tokenizer_config!(source_dir)
      helper = write_sleeping_preflight_helper!(artifacts_root)

      with_app_env(:trust_manifest_compatibility_declarations, false, fn ->
        with_app_env(:bundle_build_preflight_timeout_ms, 100, fn ->
          with_inference_overrides([tokenizer_executable: helper], fn ->
            assert {:ok, model} =
                     Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

            assert_safe_tokenization_verdict_fields_omitted!(model)
          end)
        end)
      end)
    end

    test "eager preflight helper failure during import does not abort", %{
      artifacts_root: artifacts_root
    } do
      source_dir = create_safe_bundle(artifacts_root)
      write_tokenizer_config!(source_dir)

      with_inference_overrides(
        [tokenizer_executable: Path.join(artifacts_root, "missing-helper")],
        fn ->
          assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

          imported_manifest = read_imported_manifest!(model)
          refute Map.has_key?(imported_manifest["safe_tokenization"], "compatible")
          refute Map.has_key?(imported_manifest["safe_tokenization"], "template_compatible")
          refute Map.has_key?(imported_manifest["safe_tokenization"], "incompatibility_reason")
        end
      )
    end

    test "eager preflight skips when tokenizer_config cannot resolve", %{
      artifacts_root: artifacts_root
    } do
      source_dir = create_safe_bundle(artifacts_root)
      helper = write_preflight_helper!(artifacts_root, compatible_preflight_response())

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

        imported_manifest = read_imported_manifest!(model)
        refute Map.has_key?(imported_manifest["safe_tokenization"], "compatible")
        refute Map.has_key?(imported_manifest["safe_tokenization"], "template_compatible")
        refute Map.has_key?(imported_manifest["safe_tokenization"], "incompatibility_reason")
      end)
    end

    test "eager preflight skips explicit missing tokenizer_config path", %{
      artifacts_root: artifacts_root
    } do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "tokenizer" => %{
            "kind" => "huggingface_tokenizer_json",
            "path" => "tokenizer.json",
            "config_path" => "missing-tokenizer_config.json"
          }
        })

      write_tokenizer_config!(source_dir)
      invocation_marker = Path.join(artifacts_root, "explicit-missing-helper-invoked")

      helper =
        write_marker_preflight_helper!(
          artifacts_root,
          compatible_preflight_response(),
          invocation_marker
        )

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

        imported_manifest = read_imported_manifest!(model)
        refute Map.has_key?(imported_manifest["safe_tokenization"], "compatible")
        refute Map.has_key?(imported_manifest["safe_tokenization"], "template_compatible")
        refute Map.has_key?(imported_manifest["safe_tokenization"], "incompatibility_reason")
        refute File.exists?(invocation_marker)
      end)
    end

    test "eager preflight rejects explicit blank tokenizer_config path before fallback", %{
      artifacts_root: artifacts_root
    } do
      source_dir =
        create_safe_bundle(artifacts_root, %{
          "tokenizer" => %{
            "kind" => "huggingface_tokenizer_json",
            "path" => "tokenizer.json",
            "config_path" => ""
          }
        })

      write_tokenizer_config!(source_dir)
      invocation_marker = Path.join(artifacts_root, "explicit-blank-helper-invoked")

      helper =
        write_marker_preflight_helper!(
          artifacts_root,
          compatible_preflight_response(),
          invocation_marker
        )

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:error, {:validation, message}} =
                 Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

        assert message =~ "optional non-empty config_path"
        refute File.exists?(invocation_marker)
      end)
    end

    test "eager preflight invalid helper success leaves imported manifest unchanged", %{
      artifacts_root: artifacts_root
    } do
      source_dir = create_safe_bundle(artifacts_root)
      write_tokenizer_config!(source_dir)

      helper =
        write_preflight_helper!(artifacts_root, %{
          "contract_version" => 3,
          "ok" => true,
          "result" => %{
            "compatible" => false,
            "template_compatible" => true,
            "incompatibility_reason" => %{"category" => "not_an_allowed_category"}
          }
        })

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

        imported_manifest = read_imported_manifest!(model)
        refute Map.has_key?(imported_manifest["safe_tokenization"], "compatible")
        refute Map.has_key?(imported_manifest["safe_tokenization"], "template_compatible")
        refute Map.has_key?(imported_manifest["safe_tokenization"], "incompatibility_reason")

        assert {:ok, _manifest} = ManifestParser.parse_from_bundle(artifact_path(model))
      end)
    end

    test "eager preflight skips valid legacy manifests", %{artifacts_root: artifacts_root} do
      source_dir = create_bundle(artifacts_root, %{})

      with_inference_overrides(
        [tokenizer_executable: Path.join(artifacts_root, "missing-helper")],
        fn ->
          assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
          imported_manifest = read_imported_manifest!(model)
          refute Map.has_key?(imported_manifest, "safe_tokenization")
        end
      )
    end

    test "eager preflight disabled keeps Phase 1 import behavior unchanged", %{
      artifacts_root: artifacts_root
    } do
      source_dir = create_safe_bundle(artifacts_root)
      helper = write_preflight_helper!(artifacts_root, compatible_preflight_response())

      with_app_env(:bundle_build_eager_preflight_enabled, false, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)

          imported_manifest = read_imported_manifest!(model)
          refute Map.has_key?(imported_manifest["safe_tokenization"], "compatible")
          refute Map.has_key?(imported_manifest["safe_tokenization"], "template_compatible")
          refute Map.has_key?(imported_manifest["safe_tokenization"], "incompatibility_reason")
        end)
      end)
    end

    test "SPEC 6.5 stores the final post-rewrite tree digest independently of legacy sha256", %{
      artifacts_root: artifacts_root
    } do
      legacy_sha256 = String.duplicate("f", 64)
      source_dir = create_safe_bundle(artifacts_root, %{"sha256" => legacy_sha256})
      write_tokenizer_config!(source_dir)
      {:ok, pre_rewrite_sha} = Orchard.ArtifactBundle.tree_sha256(source_dir)
      helper = write_preflight_helper!(artifacts_root, compatible_preflight_response())

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:ok, model} = Importer.import_bundle(source_dir, artifacts_root: artifacts_root)
        {:ok, imported_sha} = Orchard.ArtifactBundle.tree_sha256(artifact_path(model))

        assert model.artifact_sha256 == imported_sha
        refute model.artifact_sha256 == pre_rewrite_sha
        refute model.artifact_sha256 == legacy_sha256
      end)
    end
  end

  describe "import_bundle/2 security" do
    test "rejects model_id with path traversal", %{artifacts_root: artifacts_root} do
      evil_bundle = create_bundle(artifacts_root, %{"model_id" => "../escape"})

      assert {:error, {:validation, message}} =
               Importer.import_bundle(evil_bundle, artifacts_root: artifacts_root)

      assert message =~ "path traversal"
    end

    test "rejects version with path traversal", %{artifacts_root: artifacts_root} do
      evil_bundle = create_bundle(artifacts_root, %{"version" => "../../etc"})

      assert {:error, {:validation, message}} =
               Importer.import_bundle(evil_bundle, artifacts_root: artifacts_root)

      assert message =~ "path traversal"
    end

    test "rejects model_id with unsafe characters", %{artifacts_root: artifacts_root} do
      evil_bundle = create_bundle(artifacts_root, %{"model_id" => "model; rm -rf /"})

      assert {:error, {:validation, message}} =
               Importer.import_bundle(evil_bundle, artifacts_root: artifacts_root)

      assert message =~ "unsafe characters"
    end

    test "rejects symlinks in bundle contents", %{artifacts_root: artifacts_root} do
      bundle_dir = Path.join(artifacts_root, "symlink_bundle")
      File.mkdir_p!(bundle_dir)

      write_manifest(bundle_dir, %{"model_id" => "safe-model", "version" => "v1"})

      outside_file = Path.join(artifacts_root, "secret.txt")
      File.write!(outside_file, "secret data")
      File.ln_s!(outside_file, Path.join(bundle_dir, "linked.txt"))

      assert {:error, {:symlink_rejected, message}} =
               Importer.import_bundle(bundle_dir, artifacts_root: artifacts_root)

      assert message =~ "symlinks not allowed"
    end
  end

  # -- Test helpers ----------------------------------------------------------

  defp new_source_dir(root) do
    source_dir = Path.join(root, "bundle_builder_source_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(source_dir)
    source_dir
  end

  defp write_bundle_builder_input(source_dir, config_map) do
    File.write!(Path.join(source_dir, "config.json"), Jason.encode!(config_map))
    File.write!(Path.join(source_dir, "tokenizer.json"), ~s({"version": "1.0"}))
    File.write!(Path.join(source_dir, "chat_template.jinja"), "{{ messages[0].content }}")
    File.write!(Path.join(source_dir, "model.safetensors"), "fake-weights")
  end

  defp write_safetensors_index(source_dir, data) do
    File.write!(Path.join(source_dir, "model.safetensors.index.json"), Jason.encode!(data))
  end

  defp write_estimator_index(source_dir, total_size) do
    write_safetensors_index(source_dir, %{"metadata" => %{"total_size" => total_size}})
  end

  defp create_bundle(root, manifest_overrides) do
    bundle_dir = Path.join(root, "test_bundle_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(bundle_dir)
    write_manifest(bundle_dir, manifest_overrides)
    ensure_default_chat_template_file!(bundle_dir)
    bundle_dir
  end

  defp create_bundle_with_manifest(root, manifest_map) do
    bundle_dir = Path.join(root, "test_bundle_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(bundle_dir)
    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(manifest_map))
    ensure_default_chat_template_file!(bundle_dir)
    bundle_dir
  end

  defp ensure_default_chat_template_file!(bundle_dir) do
    path = Path.join(bundle_dir, "chat_template.jinja")

    unless File.exists?(path) do
      File.write!(path, "{{ messages[0].content }}")
    end
  end

  defp create_safe_bundle(root, manifest_overrides \\ %{}) do
    bundle_dir = Path.join(root, "safe_test_bundle_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(bundle_dir)
    File.write!(Path.join(bundle_dir, "tokenizer.json"), ~s({"version":"1.0"}))
    File.write!(Path.join(bundle_dir, "chat_template.jinja"), "{{ messages[0].content }}")
    File.write!(Path.join(bundle_dir, "model.safetensors"), "fake-weights")

    manifest =
      base_safe_manifest()
      |> Map.merge(manifest_overrides)

    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(manifest))
    bundle_dir
  end

  defp write_tokenizer_config!(bundle_dir) do
    File.write!(
      Path.join(bundle_dir, "tokenizer_config.json"),
      Jason.encode!(%{"bos_token" => "<s>"})
    )
  end

  defp base_safe_manifest do
    base_manifest_without_resident()
    |> Map.merge(%{
      "resident_memory_bytes" => 2048,
      "tokenizer" => %{"kind" => "huggingface_tokenizer_json", "path" => "tokenizer.json"},
      "chat_template" => %{
        "path" => "chat_template.jinja",
        "sha256" => hash_string("{{ messages[0].content }}")
      },
      "safe_tokenization" => safe_tokenization_map()
    })
  end

  defp safe_tokenization_map do
    %{
      "control_tokens" => ["<reserved>"],
      "catalog_sha256" => hash_catalog(["<reserved>"]),
      "catalog_source" => %{
        "added_tokens_count" => 0,
        "config_singletons_count" => 0,
        "additional_special_tokens_count" => 0,
        "chat_template_literals_count" => 1,
        "wrapper_tool_markers_count" => 0,
        "extra_count" => 0
      }
    }
  end

  defp authored_positive_safe_tokenization_map do
    Map.merge(safe_tokenization_map(), %{
      "compatible" => true,
      "template_compatible" => true
    })
  end

  defp tool_capability_evidence("unknown") do
    %{
      "tool_calling" => %{
        "source_repository" => "mlx-community/test-model",
        "source_revision" => "0123456789abcdef",
        "base_model_refs" => [],
        "preflight" => %{
          "parser_recognized" => false,
          "definition_rendered" => false,
          "history_rendered" => false
        },
        "result" => "unknown",
        "runtime_qualification" => "not_established"
      }
    }
  end

  defp tool_capability_evidence("declared") do
    %{
      "tool_calling" => %{
        "source_repository" => "mlx-community/test-model",
        "source_revision" => "0123456789abcdef",
        "base_model_refs" => [],
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

  defp base_manifest_without_resident do
    %{
      "model_id" => "test-org/tiny-llm",
      "version" => "mlx-q4-v1",
      "format" => "mlx",
      "artifact_layout" => "directory",
      "entrypoint" => "weights/",
      "sha256" => String.duplicate("a", 64),
      "size_bytes" => 1024,
      "kv_cache_bytes_per_token" => 16,
      "prefill_workspace_bytes_per_token" => 8,
      "max_context_tokens" => 4096,
      "capabilities" => ["chat"],
      "tokenizer" => %{"kind" => "huggingface_tokenizer_json", "path" => "tokenizer.json"},
      "runtime_requirements" => %{"adapter" => "mlx_lm", "min_agent_capability" => "mlx"}
    }
  end

  defp artifact_path(model) do
    String.replace_prefix(model.artifact_uri, "file://", "")
  end

  defp read_imported_manifest!(model) do
    model
    |> artifact_path()
    |> Path.join("manifest.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp read_imported_tool_capability_evidence!(model) do
    model
    |> artifact_path()
    |> Path.join("tool_capability_evidence.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp assert_safe_tokenization_verdict_fields_omitted!(model) do
    safe_tokenization = read_imported_manifest!(model)["safe_tokenization"]

    assert is_map(safe_tokenization)
    refute Map.has_key?(safe_tokenization, "compatible")
    refute Map.has_key?(safe_tokenization, "template_compatible")
    refute Map.has_key?(safe_tokenization, "incompatibility_reason")
  end

  defp staging_dirs_under(root) do
    root
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, ".staging-"))
  end

  defp write_preflight_helper!(dir, response) do
    path = Path.join(dir, "import-preflight-helper-#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    cat >/dev/null
    cat <<'JSON'
    #{Jason.encode!(response)}
    JSON
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp write_marker_preflight_helper!(dir, response, marker_path) do
    path = Path.join(dir, "marker-preflight-helper-#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    cat >/dev/null
    #{marker_write_command(marker_path)}
    cat <<'JSON'
    #{Jason.encode!(response)}
    JSON
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp write_sleeping_preflight_helper!(dir) do
    path = Path.join(dir, "sleeping-preflight-helper-#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    cat >/dev/null
    sleep 1
    cat <<'JSON'
    #{Jason.encode!(compatible_preflight_response())}
    JSON
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp write_tokenizer_config_required_preflight_helper!(dir, response, marker_path) do
    path =
      Path.join(dir, "tokenizer-config-required-helper-#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/bin/sh
    payload=$(cat)
    case "$payload" in
      *'"tokenizer_config_path":null'*) exit 42 ;;
    esac
    case "$payload" in
      *'"tokenizer_config_path":"'*tokenizer_config.json'"'*) ;;
      *) exit 42 ;;
    esac
    #{marker_write_command(marker_path)}
    cat <<'JSON'
    #{Jason.encode!(response)}
    JSON
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp marker_write_command(nil), do: ""
  defp marker_write_command(path), do: "printf invoked > #{shell_quote(path)}"

  defp shell_quote(path) do
    "'" <> String.replace(path, "'", "'\"'\"'") <> "'"
  end

  defp write_readonly_manifest_preflight_helper!(dir, response) do
    path =
      Path.join(
        dir,
        "readonly-manifest-preflight-helper-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(path, """
    #!/bin/sh
    payload=$(cat)
    tokenizer_path=$(printf '%s' "$payload" | sed -E 's/.*"tokenizer_path":"([^"]+)".*/\\1/')
    if [ "$tokenizer_path" != "$payload" ]; then
      chmod 0400 "$(dirname "$tokenizer_path")/manifest.json"
    fi
    cat <<'JSON'
    #{Jason.encode!(response)}
    JSON
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp write_mutating_readonly_manifest_preflight_helper!(dir) do
    path =
      Path.join(
        dir,
        "mutating-readonly-manifest-helper-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(path, """
    #!/bin/sh
    payload=$(cat)
    tokenizer_path=$(printf '%s' "$payload" | sed -E 's/.*"tokenizer_path":"([^"]+)".*/\\1/')
    if [ "$tokenizer_path" != "$payload" ]; then
      manifest_path="$(dirname "$tokenizer_path")/manifest.json"
      printf '{}' > "$manifest_path"
      chmod 0400 "$manifest_path"
    fi
    cat <<'JSON'
    #{Jason.encode!(invalid_preflight_response())}
    JSON
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp compatible_preflight_response do
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

  defp incompatible_preflight_response do
    %{
      "contract_version" => 3,
      "ok" => true,
      "result" => %{
        "compatible" => false,
        "template_compatible" => true,
        "incompatibility_reason" => %{
          "category" => "reserved_id_persists",
          "literal" => "<reserved>"
        }
      }
    }
  end

  defp invalid_preflight_response do
    %{
      "contract_version" => 3,
      "ok" => true,
      "result" => %{
        "compatible" => false,
        "template_compatible" => true,
        "incompatibility_reason" => %{"category" => "not_an_allowed_category"}
      }
    }
  end

  defp helper_error_preflight_response do
    %{
      "contract_version" => 3,
      "ok" => false,
      "error" => %{
        "category" => "preflight_unavailable",
        "message" => "helper could not validate"
      }
    }
  end

  defp attach_telemetry(event) do
    owner = self()
    ref = make_ref()
    handler_id = "importer-test-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      event,
      fn emitted_event, measurements, metadata, _config ->
        send(owner, {ref, emitted_event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
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

  defp hash_string(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp hash_catalog(control_tokens) do
    control_tokens
    |> Enum.intersperse(<<0>>)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp write_manifest(bundle_dir, overrides) do
    {capability_evidence, manifest_overrides} = Map.pop(overrides, "capability_evidence")

    manifest =
      Map.merge(
        %{
          "model_id" => "test-org/tiny-llm",
          "version" => "mlx-q4-v1",
          "format" => "mlx",
          "artifact_layout" => "directory",
          "entrypoint" => "weights/",
          "sha256" => String.duplicate("a", 64),
          "size_bytes" => 1024,
          "resident_memory_bytes" => 2048,
          "kv_cache_bytes_per_token" => 16,
          "prefill_workspace_bytes_per_token" => 8,
          "max_context_tokens" => 4096,
          "capabilities" => ["chat"],
          "tokenizer" => %{"kind" => "huggingface_tokenizer_json", "path" => "tokenizer.json"},
          "runtime_requirements" => %{"adapter" => "mlx_lm", "min_agent_capability" => "mlx"}
        },
        manifest_overrides
      )

    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(manifest))

    if capability_evidence do
      File.write!(
        Path.join(bundle_dir, "tool_capability_evidence.json"),
        Jason.encode!(capability_evidence)
      )
    end
  end
end
