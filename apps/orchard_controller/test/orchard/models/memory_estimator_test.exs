defmodule Orchard.Models.MemoryEstimatorTest do
  use ExUnit.Case, async: true

  alias Orchard.Models.MemoryEstimator

  describe "kv_cache_bytes_per_token/1" do
    test "derives bytes/token for a gpt-oss-like config" do
      config = %{
        "num_hidden_layers" => 24,
        "num_attention_heads" => 64,
        "num_key_value_heads" => 16,
        "head_dim" => 32,
        "torch_dtype" => "float16"
      }

      assert {:ok, 49_152} = MemoryEstimator.kv_cache_bytes_per_token(config)
    end

    test "falls back to num_attention_heads when num_key_value_heads is missing" do
      config = %{
        "num_hidden_layers" => 2,
        "num_attention_heads" => 8,
        "head_dim" => 16,
        "torch_dtype" => "float16"
      }

      assert {:ok, 1_024} = MemoryEstimator.kv_cache_bytes_per_token(config)
    end

    test "falls back to hidden_size / num_attention_heads when head_dim is missing" do
      config = %{
        "num_hidden_layers" => 3,
        "num_attention_heads" => 6,
        "num_key_value_heads" => 6,
        "hidden_size" => 192,
        "torch_dtype" => "float32"
      }

      assert {:ok, 4_608} = MemoryEstimator.kv_cache_bytes_per_token(config)
    end

    test "defaults to 2 bytes when torch_dtype is missing" do
      config = %{
        "num_hidden_layers" => 2,
        "num_attention_heads" => 8,
        "num_key_value_heads" => 8,
        "head_dim" => 16
      }

      assert {:ok, 1_024} = MemoryEstimator.kv_cache_bytes_per_token(config)
    end

    test "supports common dtype aliases case-insensitively" do
      config = %{
        "num_hidden_layers" => 2,
        "num_attention_heads" => 8,
        "num_key_value_heads" => 8,
        "head_dim" => 16,
        "torch_dtype" => " BF16 "
      }

      assert {:ok, 1_024} = MemoryEstimator.kv_cache_bytes_per_token(config)
    end

    test "falls back to nested text_config when shape fields are absent at top level" do
      config = %{
        "model_type" => "gemma3",
        "text_config" => %{
          "num_hidden_layers" => 24,
          "num_attention_heads" => 64,
          "num_key_value_heads" => 16,
          "head_dim" => 32,
          "torch_dtype" => "fp16"
        }
      }

      assert {:ok, 49_152} = MemoryEstimator.kv_cache_bytes_per_token(config)
    end

    test "returns :unknown when required dimensions are missing" do
      config = %{
        "num_attention_heads" => 8,
        "head_dim" => 16,
        "torch_dtype" => "float16"
      }

      assert :unknown = MemoryEstimator.kv_cache_bytes_per_token(config)
    end

    test "returns :unknown for unsupported dtype" do
      config = %{
        "num_hidden_layers" => 2,
        "num_attention_heads" => 8,
        "num_key_value_heads" => 8,
        "head_dim" => 16,
        "torch_dtype" => "float8"
      }

      assert :unknown = MemoryEstimator.kv_cache_bytes_per_token(config)
    end

    test "returns :unknown for malformed numeric strings in required fields" do
      invalid_configs = [
        %{
          "num_hidden_layers" => "24.0",
          "num_attention_heads" => 64,
          "num_key_value_heads" => 16,
          "head_dim" => 32,
          "torch_dtype" => "float16"
        },
        %{
          "num_hidden_layers" => 24,
          "num_attention_heads" => "sixty-four",
          "num_key_value_heads" => 16,
          "head_dim" => 32,
          "torch_dtype" => "float16"
        },
        %{
          "num_hidden_layers" => 24,
          "num_attention_heads" => 64,
          "num_key_value_heads" => "16heads",
          "head_dim" => 32,
          "torch_dtype" => "float16"
        },
        %{
          "num_hidden_layers" => 24,
          "num_attention_heads" => 64,
          "num_key_value_heads" => 16,
          "head_dim" => "32 tokens",
          "torch_dtype" => "float16"
        }
      ]

      Enum.each(invalid_configs, fn config ->
        assert :unknown = MemoryEstimator.kv_cache_bytes_per_token(config)
      end)
    end
  end
end
