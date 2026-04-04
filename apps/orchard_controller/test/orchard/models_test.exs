defmodule Orchard.ModelsTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.Models
  alias Orchard.Models.Importer
  alias Orchard.Models.Model

  test "create_model/1 persists a model and enforces uniqueness on identity" do
    attrs = model_attrs()
    assert {:ok, model} = Models.create_model(attrs)
    assert model.state == :registered
    assert model.model_id == attrs.model_id
    assert model.version == "main"

    # Same attrs → uniqueness violation
    assert {:error, changeset} = Models.create_model(attrs)
    assert %{model_id: ["has already been taken"]} = errors_on(changeset)
  end

  test "create_model/1 validates artifact_uri before hitting the database" do
    assert {:error, changeset} = Models.create_model(model_attrs(%{artifact_uri: nil}))
    assert %{artifact_uri: ["can't be blank"]} = errors_on(changeset)
  end

  test "create_model/1 persists artifact_source_uri when provided" do
    attrs = model_attrs()
    assert {:ok, model} = Models.create_model(attrs)
    assert model.artifact_source_uri == attrs.artifact_source_uri
  end

  test "create_model/1 succeeds when artifact_source_uri is nil" do
    assert {:ok, model} = Models.create_model(model_attrs(%{artifact_source_uri: nil}))
    assert model.artifact_source_uri == nil
  end

  test "create_model/1 accepts nil max_context_tokens" do
    assert {:ok, model} = Models.create_model(model_attrs(%{max_context_tokens: nil}))
    assert model.max_context_tokens == nil
  end

  test "create_model/1 rejects zero max_context_tokens" do
    assert {:error, changeset} = Models.create_model(model_attrs(%{max_context_tokens: 0}))
    assert %{max_context_tokens: [_]} = errors_on(changeset)
  end

  test "create_model/1 rejects malformed capabilities instead of raising" do
    assert {:error, changeset} = Models.create_model(model_attrs(%{capabilities: nil}))
    assert %{capabilities: ["must contain non-empty strings"]} = errors_on(changeset)
  end

  test "list_active_models/0 returns only active catalog entries" do
    assert {:ok, _registered} = Models.create_model(model_attrs(%{model_id: "registered-model"}))

    assert {:ok, active} =
             Models.create_model(
               model_attrs(%{model_id: "active-model", state: :active, version: "v2"})
             )

    assert [listed] = Models.list_active_models()
    assert listed.id == active.id
    assert listed.state == :active
  end

  test "catalog_summary/0 returns zero-filled counts when DB is empty" do
    summary = Models.catalog_summary()

    assert summary.total == 0

    for state <- Model.states() do
      assert Map.has_key?(summary.by_state, state), "missing state: #{state}"
      assert summary.by_state[state] == 0
    end
  end

  test "catalog_summary/0 returns grouped counts and derived total" do
    create_model!(%{model_id: "reg-1"})
    create_model!(%{model_id: "reg-2"})
    create_model!(%{model_id: "active-1", state: :active})
    create_model!(%{model_id: "retired-1", state: :retired})

    summary = Models.catalog_summary()

    assert summary.total == 4
    assert summary.by_state.registered == 2
    assert summary.by_state.active == 1
    assert summary.by_state.deprecated == 0
    assert summary.by_state.retired == 1
  end

  # -- Lifecycle transitions --

  describe "available_transitions/1" do
    test "returns valid targets for each state" do
      assert Models.available_transitions(:registered) == [:active, :retired]
      assert Models.available_transitions(:active) == [:deprecated, :retired]
      assert Models.available_transitions(:deprecated) == [:active, :retired]
      assert Models.available_transitions(:retired) == []
    end

    test "accepts a Model struct" do
      model = create_model!(%{state: :active})
      assert Models.available_transitions(model) == [:deprecated, :retired]
    end

    test "returns empty list for unknown state" do
      assert Models.available_transitions(:unknown) == []
    end
  end

  describe "activate_model/1" do
    test "transitions registered model to active" do
      model = create_model!(%{model_id: "reg-model", state: :registered})
      assert {:ok, activated} = Models.activate_model(model.id)
      assert activated.state == :active
      assert activated.id == model.id
    end

    test "transitions deprecated model to active" do
      model = create_model!(%{model_id: "dep-model", state: :deprecated})
      assert {:ok, activated} = Models.activate_model(model)
      assert activated.state == :active
    end

    test "rejects transition from active (already active)" do
      model = create_model!(%{model_id: "active-model", state: :active})
      assert {:error, changeset} = Models.activate_model(model.id)
      assert %{state: [msg]} = errors_on(changeset)
      assert msg =~ "cannot transition from active to active"
    end

    test "rejects transition from retired (terminal)" do
      model = create_model!(%{model_id: "retired-model", state: :retired})
      assert {:error, changeset} = Models.activate_model(model.id)
      assert %{state: [msg]} = errors_on(changeset)
      assert msg =~ "cannot transition from retired to active"
    end
  end

  describe "deprecate_model/1" do
    test "transitions active model to deprecated" do
      model = create_model!(%{model_id: "active-model", state: :active})
      assert {:ok, deprecated} = Models.deprecate_model(model.id)
      assert deprecated.state == :deprecated
    end

    test "rejects transition from registered" do
      model = create_model!(%{model_id: "reg-model", state: :registered})
      assert {:error, changeset} = Models.deprecate_model(model.id)
      assert %{state: [msg]} = errors_on(changeset)
      assert msg =~ "cannot transition from registered to deprecated"
    end
  end

  describe "retire_model/1" do
    test "transitions registered model to retired" do
      model = create_model!(%{model_id: "reg-model", state: :registered})
      assert {:ok, retired} = Models.retire_model(model.id)
      assert retired.state == :retired
    end

    test "transitions active model to retired" do
      model = create_model!(%{model_id: "active-model", state: :active})
      assert {:ok, retired} = Models.retire_model(model.id)
      assert retired.state == :retired
    end

    test "transitions deprecated model to retired" do
      model = create_model!(%{model_id: "dep-model", state: :deprecated})
      assert {:ok, retired} = Models.retire_model(model)
      assert retired.state == :retired
    end

    test "rejects transition from retired (terminal)" do
      model = create_model!(%{model_id: "retired-model", state: :retired})
      assert {:error, changeset} = Models.retire_model(model.id)
      assert %{state: [msg]} = errors_on(changeset)
      assert msg =~ "cannot transition from retired to retired"
    end
  end

  # -- Model deletion --

  describe "deletable?/1" do
    test "returns true for :retired atom" do
      assert Models.deletable?(:retired)
    end

    test "returns false for non-retired atoms" do
      refute Models.deletable?(:registered)
      refute Models.deletable?(:active)
      refute Models.deletable?(:deprecated)
      refute Models.deletable?(:unknown)
    end

    test "accepts a Model struct" do
      model = create_model!(%{state: :retired})
      assert Models.deletable?(model)

      active_model = create_model!(%{state: :active})
      refute Models.deletable?(active_model)
    end
  end

  describe "delete_model/1" do
    setup do
      # Create a temp artifacts_root and override inference config for the test
      tmp_root =
        Path.join(System.tmp_dir!(), "orchard_delete_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_root)

      original_config = Application.get_env(:orchard_controller, :inference)
      updated_config = Keyword.put(original_config, :artifacts_root, tmp_root)
      Application.put_env(:orchard_controller, :inference, updated_config)

      on_exit(fn ->
        Application.put_env(:orchard_controller, :inference, original_config)
        File.rm_rf(tmp_root)
      end)

      %{artifacts_root: tmp_root}
    end

    test "deletes retired model with no requests, removing DB row and artifact dir", %{
      artifacts_root: root
    } do
      model = create_model!(%{state: :retired})
      dir = materialize_artifact_dir!(model, root)
      assert File.dir?(dir)

      assert {:ok, deleted} = Models.delete_model(model.id)
      assert deleted.id == model.id
      assert deleted.state == :retired

      # DB row gone
      assert Orchard.Repo.get(Model, model.id) == nil
      # Artifact dir removed
      refute File.dir?(dir)
    end

    test "succeeds when artifact directory is already missing" do
      model = create_model!(%{state: :retired})

      assert {:ok, deleted} = Models.delete_model(model.id)
      assert deleted.id == model.id
      assert Orchard.Repo.get(Model, model.id) == nil
    end

    test "nullifies model_id on terminal requests before delete", %{artifacts_root: root} do
      model = create_model!(%{state: :retired})
      _dir = materialize_artifact_dir!(model, root)

      terminal_req =
        create_request!(%{
          model_id: model.id,
          requested_model: "#{model.model_id}@#{model.version}",
          state: :completed
        })

      assert {:ok, _deleted} = Models.delete_model(model.id)

      # Request preserved with model_id nullified
      reloaded = Orchard.Repo.get!(Orchard.Requests.Request, terminal_req.id)
      assert reloaded.model_id == nil
      assert reloaded.requested_model == "#{model.model_id}@#{model.version}"
    end

    test "rejects with {:model_in_use, N} when non-terminal requests exist", %{
      artifacts_root: root
    } do
      model = create_model!(%{state: :retired})
      dir = materialize_artifact_dir!(model, root)

      # One terminal, one non-terminal
      _terminal =
        create_request!(%{model_id: model.id, requested_model: "m@v", state: :completed})

      _running =
        create_request!(%{model_id: model.id, requested_model: "m@v", state: :running})

      assert {:error, {:model_in_use, 1}} = Models.delete_model(model.id)

      # Everything still intact
      assert Orchard.Repo.get(Model, model.id) != nil
      assert File.dir?(dir)
    end

    test "rejects with :not_retired for non-retired models" do
      for state <- [:registered, :active, :deprecated] do
        model = create_model!(%{state: state})
        assert {:error, :not_retired} = Models.delete_model(model.id)
        assert Orchard.Repo.get(Model, model.id) != nil
      end
    end

    test "returns :not_found for unknown UUID" do
      assert {:error, :not_found} = Models.delete_model(Ecto.UUID.generate())
    end

    test "returns :not_found for malformed UUID" do
      assert {:error, :not_found} = Models.delete_model("not-a-uuid")
    end

    test "validates artifact path is contained under artifacts_root" do
      # Create a model with a path-traversal model_id via direct DB insert
      model = create_model!(%{model_id: "../escape-test", state: :retired})

      assert {:error, {:path_escape, _path}} = Models.delete_model(model.id)
      assert Orchard.Repo.get(Model, model.id) != nil
    end

    test "re-import succeeds after delete", %{artifacts_root: root} do
      source = Path.join(root, "_source_bundle")
      File.mkdir_p!(source)

      manifest = %{
        "model_id" => "test-org/reimport-model",
        "version" => "v1",
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
      }

      File.write!(Path.join(source, "manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(source, "tokenizer.json"), "{}")

      # First import
      assert {:ok, model} = Importer.import_bundle(source, artifacts_root: root)

      # Retire and delete
      assert {:ok, retired} = Models.retire_model(model.id)
      assert {:ok, _deleted} = Models.delete_model(retired.id)

      # Re-import same identity — should succeed (duplicate guard cleared)
      assert {:ok, reimported} = Importer.import_bundle(source, artifacts_root: root)

      assert reimported.model_id == "test-org/reimport-model"
      assert reimported.version == "v1"
    end
  end

  describe "Importer.artifact_destination_path/3" do
    test "returns canonical path matching importer layout" do
      assert Importer.artifact_destination_path("/root", "org/model", "v1") ==
               "/root/org/model/v1"
    end
  end

  describe "transition edge cases" do
    test "returns :not_found for unknown UUID" do
      assert {:error, :not_found} = Models.activate_model(Ecto.UUID.generate())
    end

    test "returns :not_found for malformed UUID string" do
      assert {:error, :not_found} = Models.activate_model("not-a-uuid")
    end

    test "state changes immediately affect list_active_models/0" do
      model = create_model!(%{model_id: "visibility-test", state: :registered})
      assert Models.list_active_models() == []

      assert {:ok, _} = Models.activate_model(model.id)
      assert [active] = Models.list_active_models()
      assert active.id == model.id

      assert {:ok, _} = Models.deprecate_model(active.id)
      assert Models.list_active_models() == []

      assert {:ok, _} = Models.activate_model(model.id)
      assert [reactivated] = Models.list_active_models()
      assert reactivated.id == model.id

      assert {:ok, _} = Models.retire_model(model.id)
      assert Models.list_active_models() == []
    end
  end
end
