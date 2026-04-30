defmodule Orchard.Tokenizer.CompatibilityCache do
  @moduledoc """
  Runtime compatibility verdict cache keyed by bundle and catalog hashes.
  """

  use GenServer

  @table :orchard_tokenizer_compatibility_cache

  @type cache_key :: {String.t(), String.t()}
  @type compatibility_metadata :: %{
          required(:template_compatible) => boolean(),
          optional(:sentinel_preflight_validated) => boolean()
        }
  @type compatibility_verdict ::
          :unknown
          | {:compatible, compatibility_metadata()}
          | {:incompatible, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec get(String.t(), String.t()) :: compatibility_verdict()
  def get(bundle_sha256, catalog_sha256)
      when is_binary(bundle_sha256) and is_binary(catalog_sha256) do
    case :ets.lookup(@table, {bundle_sha256, catalog_sha256}) do
      [{_key, verdict}] -> verdict
      [] -> :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  @spec put_compatible(String.t(), String.t(), compatibility_metadata()) :: :ok
  def put_compatible(
        bundle_sha256,
        catalog_sha256,
        %{template_compatible: template_compatible} = metadata
      )
      when is_binary(bundle_sha256) and is_binary(catalog_sha256) and
             is_boolean(template_compatible) do
    compatible_metadata = normalize_compatible_metadata!(metadata, template_compatible)

    GenServer.call(
      __MODULE__,
      {:put, {bundle_sha256, catalog_sha256}, {:compatible, compatible_metadata}}
    )
  end

  defp normalize_compatible_metadata!(
         %{sentinel_preflight_validated: sentinel_preflight_validated},
         template_compatible
       )
       when is_boolean(sentinel_preflight_validated) do
    %{
      template_compatible: template_compatible,
      sentinel_preflight_validated: sentinel_preflight_validated
    }
  end

  defp normalize_compatible_metadata!(
         %{sentinel_preflight_validated: value},
         _template_compatible
       ) do
    raise ArgumentError,
          "sentinel_preflight_validated must be a boolean, got: #{inspect(value)}"
  end

  defp normalize_compatible_metadata!(_metadata, template_compatible) do
    %{template_compatible: template_compatible}
  end

  @spec put_incompatible(String.t(), String.t(), term()) :: :ok
  def put_incompatible(bundle_sha256, catalog_sha256, reason)
      when is_binary(bundle_sha256) and is_binary(catalog_sha256) do
    GenServer.call(__MODULE__, {:put, {bundle_sha256, catalog_sha256}, {:incompatible, reason}})
  end

  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, key, verdict}, _from, state) do
    true = :ets.insert(@table, {key, verdict})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
