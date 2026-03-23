defmodule Orchard.TestSupport.ModelRequestFixtures do
  @moduledoc """
  Shared test fixtures for model and request creation.

  Provides valid default attribute builders and bang-style creators that
  generate unique identifiers per call to avoid collisions in async tests.

  ## Usage

      import Orchard.TestSupport.ModelRequestFixtures

      test "example" do
        {:ok, model} = Orchard.Models.create_model(model_attrs())
        request = create_request!(%{state: :running})
      end
  """

  alias Orchard.Models
  alias Orchard.Models.Importer
  alias Orchard.Requests

  @doc """
  Returns a valid attribute map for `Orchard.Models.create_model/1`.

  Each call generates a unique `model_id` and `artifact_uri` to avoid
  uniqueness collisions. Override any field via the `overrides` map.
  """
  def model_attrs(overrides \\ %{}) do
    suffix = unique_suffix()

    Map.merge(
      %{
        model_id: "mlx-community/phi-3-#{suffix}",
        version: "main",
        state: :registered,
        format: "mlx",
        capabilities: ["chat"],
        tokenizer: %{"kind" => "huggingface_tokenizer_json", "path" => "tokenizer.json"},
        artifact_uri: "file:///tmp/phi-3-#{suffix}",
        artifact_source_uri: "file:///tmp/phi-3-#{suffix}",
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

  @doc """
  Creates a model via `Orchard.Models.create_model/1` and returns the
  struct, raising on validation failure.
  """
  def create_model!(overrides \\ %{}) do
    attrs = model_attrs(overrides)

    case Models.create_model(attrs) do
      {:ok, model} -> model
      {:error, changeset} -> raise "create_model! failed: #{inspect(changeset.errors)}"
    end
  end

  @doc """
  Returns a valid attribute map for `Orchard.Requests.create_request/1`.

  Represents an early-lifecycle request row (before model resolution and
  canonicalization). Each call generates a unique `public_id`.
  """
  def request_attrs(overrides \\ %{}) do
    suffix = unique_suffix()

    Map.merge(
      %{
        public_id: "req_#{suffix}",
        endpoint: :chat_completions,
        tenant_id: Ecto.UUID.generate(),
        requested_model: "mlx-community/phi-3-#{suffix}@main",
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
  end

  @doc """
  Creates a request via `Orchard.Requests.create_request/1` and returns the
  struct, raising on validation failure.
  """
  def create_request!(overrides \\ %{}) do
    attrs = request_attrs(overrides)

    case Requests.create_request(attrs) do
      {:ok, request} -> request
      {:error, changeset} -> raise "create_request! failed: #{inspect(changeset.errors)}"
    end
  end

  @doc """
  Creates the canonical artifact directory for a model with a sentinel file.

  Returns the artifact directory path.
  """
  def materialize_artifact_dir!(%Models.Model{} = model, artifacts_root) do
    dir = Importer.artifact_destination_path(artifacts_root, model.model_id, model.version)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "manifest.json"), "{\"sentinel\": true}")
    dir
  end

  defp unique_suffix do
    System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
  end
end
