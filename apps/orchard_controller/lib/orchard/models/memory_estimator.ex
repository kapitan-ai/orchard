defmodule Orchard.Models.MemoryEstimator do
  @moduledoc """
  Derives static model-memory estimates from decoded `config.json` data.
  """

  @type estimate_result :: {:ok, pos_integer()} | :unknown

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
