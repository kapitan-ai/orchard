defmodule Orchard.Models.MemoryEstimator do
  @moduledoc """
  Derives static model-memory estimates from bundle metadata and decoded `config.json` data.
  """

  @type estimate_result :: {:ok, pos_integer()} | :unknown

  @safetensors_index_filename "model.safetensors.index.json"
  @max_resident_memory_bytes 9_223_372_036_854_775_807

  @dtype_bytes %{
    "float16" => 2,
    "torch.float16" => 2,
    "half" => 2,
    "fp16" => 2,
    "bfloat16" => 2,
    "torch.bfloat16" => 2,
    "bf16" => 2,
    "float32" => 4,
    "torch.float32" => 4,
    "fp32" => 4
  }

  @spec kv_cache_bytes_per_token(map()) :: estimate_result
  def kv_cache_bytes_per_token(config) when is_map(config) do
    config = estimation_config(config)

    with {:ok, layers} <- positive_integer(config, "num_hidden_layers"),
         {:ok, attention_heads} <- positive_integer(config, "num_attention_heads"),
         {:ok, kv_heads} <- kv_heads(config, attention_heads),
         {:ok, head_dim} <- head_dim(config, attention_heads),
         {:ok, dtype_bytes} <- dtype_bytes(config) do
      {:ok, layers * 2 * kv_heads * head_dim * dtype_bytes}
    else
      :error -> :unknown
    end
  end

  def kv_cache_bytes_per_token(_config), do: :unknown

  @spec resident_memory_bytes_from_bundle(String.t()) :: estimate_result
  def resident_memory_bytes_from_bundle(bundle_dir) when is_binary(bundle_dir) do
    case resident_memory_bytes_from_index(bundle_dir) do
      {:ok, _value} = result -> result
      :unknown -> resident_memory_bytes_from_safetensors(bundle_dir)
    end
  end

  def resident_memory_bytes_from_bundle(_bundle_dir), do: :unknown

  defp resident_memory_bytes_from_index(bundle_dir) do
    index_path = Path.join(bundle_dir, @safetensors_index_filename)

    with {:ok, json} <- File.read(index_path),
         {:ok, %{"metadata" => metadata}} when is_map(metadata) <- Jason.decode(json),
         {:ok, total_size} <- resident_memory_integer(metadata, "total_size") do
      {:ok, total_size}
    else
      _other -> :unknown
    end
  end

  defp resident_memory_bytes_from_safetensors(bundle_dir) do
    case safetensors_size_sum(bundle_dir) do
      {:ok, total_size, count} when count > 0 ->
        case resident_memory_integer(total_size) do
          {:ok, _value} = result -> result
          :error -> :unknown
        end

      {:ok, _total_size, _count} ->
        :unknown

      :unknown ->
        :unknown
    end
  end

  defp safetensors_size_sum(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce_while(entries, {:ok, 0, 0}, fn entry, {:ok, total_size, count} ->
          accumulate_safetensors_size(dir, entry, total_size, count)
        end)

      {:error, _reason} ->
        :unknown
    end
  end

  defp accumulate_safetensors_size(dir, entry, total_size, count) do
    path = Path.join(dir, entry)

    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} ->
        {:cont, add_safetensors_size(entry, size, total_size, count)}

      {:ok, %{type: :directory}} ->
        accumulate_safetensors_directory(path, total_size, count)

      {:ok, _stat} ->
        {:halt, :unknown}

      {:error, _reason} ->
        {:halt, :unknown}
    end
  end

  defp add_safetensors_size(entry, size, total_size, count) do
    if String.ends_with?(entry, ".safetensors") do
      {:ok, total_size + size, count + 1}
    else
      {:ok, total_size, count}
    end
  end

  defp accumulate_safetensors_directory(path, total_size, count) do
    case safetensors_size_sum(path) do
      {:ok, nested_size, nested_count} ->
        {:cont, {:ok, total_size + nested_size, count + nested_count}}

      :unknown ->
        {:halt, :unknown}
    end
  end

  defp resident_memory_integer(map, key) when is_map(map) and is_binary(key) do
    map
    |> Map.fetch(key)
    |> case do
      {:ok, value} -> resident_memory_integer(value)
      :error -> :error
    end
  end

  defp resident_memory_integer(value) do
    with {:ok, number} <- positive_integer(value),
         true <- number <= @max_resident_memory_bytes do
      {:ok, number}
    else
      _other -> :error
    end
  end

  defp estimation_config(config) do
    case Map.get(config, "text_config") do
      nested when is_map(nested) -> Map.merge(nested, config)
      _other -> config
    end
  end

  defp kv_heads(config, attention_heads) do
    case Map.fetch(config, "num_key_value_heads") do
      {:ok, value} -> positive_integer(value)
      :error -> {:ok, attention_heads}
    end
  end

  defp head_dim(config, attention_heads) do
    case Map.fetch(config, "head_dim") do
      {:ok, value} ->
        positive_integer(value)

      :error ->
        with {:ok, hidden_size} <- positive_integer(config, "hidden_size"),
             true <- rem(hidden_size, attention_heads) == 0 do
          {:ok, div(hidden_size, attention_heads)}
        else
          _ -> :error
        end
    end
  end

  defp dtype_bytes(config) do
    case Map.get(config, "torch_dtype") do
      nil ->
        {:ok, 2}

      dtype when is_binary(dtype) ->
        dtype
        |> String.trim()
        |> String.downcase()
        |> then(&Map.get(@dtype_bytes, &1))
        |> case do
          value when is_integer(value) -> {:ok, value}
          _ -> :error
        end

      _other ->
        :error
    end
  end

  defp positive_integer(map, key) when is_map(map) and is_binary(key) do
    map
    |> Map.fetch(key)
    |> case do
      {:ok, value} -> positive_integer(value)
      :error -> :error
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> :error
    end
  end

  defp positive_integer(_value), do: :error
end
