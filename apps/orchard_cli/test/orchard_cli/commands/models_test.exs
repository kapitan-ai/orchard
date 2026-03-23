defmodule OrchardCLI.Commands.ModelsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Models
  alias Orchard.Repo
  alias OrchardCLI.Commands.Models, as: ModelsCmd

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # -- Local test helpers --

  defp create_model!(overrides \\ %{}) do
    suffix = System.unique_integer([:positive, :monotonic])

    attrs =
      Map.merge(
        %{
          model_id: "test-org/cli-model-#{suffix}",
          version: "main",
          state: :registered,
          format: "mlx",
          capabilities: ["chat"],
          tokenizer: %{"kind" => "huggingface_tokenizer_json", "path" => "tokenizer.json"},
          artifact_uri: "file:///tmp/cli-model-#{suffix}",
          artifact_source_uri: "file:///tmp/cli-model-#{suffix}",
          artifact_sha256: String.duplicate("a", 64),
          artifact_size_bytes: 1024,
          resident_memory_bytes: 2048,
          kv_cache_bytes_per_token: 16,
          prefill_workspace_bytes_per_token: 8,
          max_context_tokens: 32_768,
          default_parameters: %{"temperature" => 0.7},
          runtime_requirements: %{"adapter" => "mlx_lm", "min_agent_capability" => "mlx"}
        },
        overrides
      )

    case Models.create_model(attrs) do
      {:ok, model} -> model
      {:error, cs} -> raise "create_model! failed: #{inspect(cs.errors)}"
    end
  end

  defp create_request!(overrides) do
    suffix = System.unique_integer([:positive, :monotonic])

    attrs =
      Map.merge(
        %{
          public_id: "req_cli_#{suffix}",
          endpoint: :chat_completions,
          tenant_id: Ecto.UUID.generate(),
          requested_model: "test@main",
          state: :received,
          stream: true,
          payload_capture_mode: :metadata,
          sampling_params: %{"temperature" => 0.7},
          response_format: %{"type" => "text"},
          input_tokens: 0,
          output_tokens: 0,
          reserved_output_tokens: 128,
          timeout_at: ~U[2026-03-10 00:00:00.000000Z]
        },
        overrides
      )

    case Orchard.Requests.create_request(attrs) do
      {:ok, req} -> req
      {:error, cs} -> raise "create_request! failed: #{inspect(cs.errors)}"
    end
  end

  # -- Parsing and usage --

  describe "delete parsing" do
    test "missing identity shows usage" do
      assert {:error, msg, 1} = ModelsCmd.run(["delete"])
      assert msg =~ "missing model identity"
      assert msg =~ "orchardctl models delete <model_id@version>"
    end

    test "too many args shows usage" do
      assert {:error, msg, 1} = ModelsCmd.run(["delete", "a@b", "extra"])
      assert msg =~ "expected exactly one model identity"
      assert msg =~ "orchardctl models delete <model_id@version>"
    end

    test "identity without @ shows format error" do
      assert {:error, msg, 1} = ModelsCmd.run(["delete", "org/model"])
      assert msg =~ "expected model identity in the form"
    end

    test "identity with empty version shows format error" do
      assert {:error, msg, 1} = ModelsCmd.run(["delete", "org/model@"])
      assert msg =~ "expected model identity in the form"
    end

    test "identity with empty model_id shows format error" do
      assert {:error, msg, 1} = ModelsCmd.run(["delete", "@v1"])
      assert msg =~ "expected model identity in the form"
    end
  end

  describe "group usage" do
    test "models without subcommand includes delete" do
      assert {:error, msg, 1} = ModelsCmd.run([])
      assert msg =~ "<import|list|delete>"
    end
  end

  # -- DB-backed delete behavior --

  describe "delete execution" do
    test "deletes retired model" do
      model = create_model!(%{model_id: "org/deletable", version: "v1", state: :retired})

      assert {:ok, msg} = ModelsCmd.run(["delete", "org/deletable@v1"])
      assert msg == "Deleted org/deletable@v1"

      assert Models.get_model_by_identity("org/deletable", "v1") == nil
      assert Repo.get(Orchard.Models.Model, model.id) == nil
    end

    test "unknown model returns not found" do
      assert {:error, msg, 1} = ModelsCmd.run(["delete", "no-such/model@v1"])
      assert msg =~ "model not found"
      assert msg =~ "no-such/model@v1"
    end

    test "non-retired model returns not-retired error" do
      _model = create_model!(%{model_id: "org/active-model", version: "v1", state: :active})

      assert {:error, msg, 1} = ModelsCmd.run(["delete", "org/active-model@v1"])
      assert msg =~ "only retired models can be deleted"
      assert msg =~ "org/active-model@v1"
    end

    test "model with non-terminal requests returns in-use error" do
      model = create_model!(%{model_id: "org/busy-model", version: "v1", state: :retired})

      _running =
        create_request!(%{
          model_id: model.id,
          requested_model: "org/busy-model@v1",
          state: :running
        })

      assert {:error, msg, 1} = ModelsCmd.run(["delete", "org/busy-model@v1"])
      assert msg =~ "1 non-terminal request(s) still reference it"

      # Model still exists
      assert Models.get_model_by_identity("org/busy-model", "v1") != nil
    end

    test "already-deleted model returns not found" do
      model = create_model!(%{model_id: "org/gone-model", version: "v1", state: :retired})
      {:ok, _} = Models.delete_model(model.id)

      assert {:error, msg, 1} = ModelsCmd.run(["delete", "org/gone-model@v1"])
      assert msg =~ "model not found"
    end
  end
end
