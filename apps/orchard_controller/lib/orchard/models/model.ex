defmodule Orchard.Models.Model do
  @moduledoc """
  Ecto schema for imported model catalog entries.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states [:registered, :active, :deprecated, :retired]
  @formats ["mlx", "gguf"]

  schema "models" do
    field(:model_id, :string)
    field(:version, :string)
    field(:state, Ecto.Enum, values: @states)
    field(:format, :string)
    field(:capabilities, {:array, :string}, default: [])
    field(:tokenizer, :map, default: %{})
    field(:artifact_uri, :string)
    field(:artifact_sha256, :string)
    field(:artifact_size_bytes, :integer)
    field(:resident_memory_bytes, :integer)
    field(:kv_cache_bytes_per_token, :integer)
    field(:prefill_workspace_bytes_per_token, :integer)
    field(:max_context_tokens, :integer)
    field(:default_parameters, :map, default: %{})
    field(:runtime_requirements, :map, default: %{})

    has_many(:requests, Orchard.Requests.Request)

    timestamps(type: :utc_datetime_usec)
  end

  @spec states() :: [atom()]
  def states, do: @states

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(model, attrs) do
    model
    |> cast(attrs, [
      :model_id,
      :version,
      :state,
      :format,
      :capabilities,
      :tokenizer,
      :artifact_uri,
      :artifact_sha256,
      :artifact_size_bytes,
      :resident_memory_bytes,
      :kv_cache_bytes_per_token,
      :prefill_workspace_bytes_per_token,
      :max_context_tokens,
      :default_parameters,
      :runtime_requirements
    ])
    |> validate_required([
      :model_id,
      :version,
      :state,
      :format,
      :artifact_uri,
      :artifact_sha256,
      :artifact_size_bytes,
      :resident_memory_bytes,
      :kv_cache_bytes_per_token,
      :prefill_workspace_bytes_per_token,
      :max_context_tokens,
      :tokenizer,
      :runtime_requirements
    ])
    |> validate_inclusion(:format, @formats)
    |> validate_number(:artifact_size_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:resident_memory_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:kv_cache_bytes_per_token, greater_than_or_equal_to: 0)
    |> validate_number(:prefill_workspace_bytes_per_token, greater_than_or_equal_to: 0)
    |> validate_number(:max_context_tokens, greater_than: 0)
    |> validate_capabilities()
    |> unique_constraint([:model_id, :version])
  end

  defp validate_capabilities(%Ecto.Changeset{} = changeset) do
    capabilities = get_field(changeset, :capabilities)

    cond do
      is_nil(capabilities) ->
        add_error(changeset, :capabilities, "must contain non-empty strings")

      is_list(capabilities) and Enum.all?(capabilities, &(is_binary(&1) and &1 != "")) ->
        changeset

      true ->
        add_error(changeset, :capabilities, "must contain non-empty strings")
    end
  end
end
