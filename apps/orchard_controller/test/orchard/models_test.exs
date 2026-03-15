defmodule Orchard.ModelsTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.Models
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
end
