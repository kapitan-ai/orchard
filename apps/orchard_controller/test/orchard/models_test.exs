defmodule Orchard.ModelsTest do
  use Orchard.DataCase, async: false

  alias Orchard.Models

  test "create_model/1 persists a model and enforces uniqueness on identity" do
    assert {:ok, model} = Models.create_model(model_attrs())
    assert model.state == :registered
    assert model.model_id == "mlx-community/phi-3"
    assert model.version == "main"

    assert {:error, changeset} = Models.create_model(model_attrs())
    assert %{model_id: ["has already been taken"]} = errors_on(changeset)
  end

  test "create_model/1 validates artifact_uri before hitting the database" do
    assert {:error, changeset} = Models.create_model(model_attrs(%{artifact_uri: nil}))
    assert %{artifact_uri: ["can't be blank"]} = errors_on(changeset)
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

  defp model_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        model_id: "mlx-community/phi-3",
        version: "main",
        state: :registered,
        format: "mlx",
        capabilities: ["chat"],
        tokenizer: %{"kind" => "huggingface_tokenizer_json", "path" => "tokenizer.json"},
        artifact_uri: "file:///tmp/phi-3",
        artifact_sha256: String.duplicate("a", 64),
        artifact_size_bytes: 1_024,
        resident_memory_bytes: 2_048,
        kv_cache_bytes_per_token: 16,
        prefill_workspace_bytes_per_token: 8,
        max_context_tokens: 32_768,
        default_parameters: %{"temperature" => 0.7},
        runtime_requirements: %{"adapter" => "mlx_lm", "min_agent_capability" => "mlx"}
      },
      overrides
    )
  end
end
