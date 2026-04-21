defmodule Orchard.Models.MemoryEstimatorTest do
  use ExUnit.Case, async: true

  alias Orchard.Models.MemoryEstimator

  setup do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("memory_estimator_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

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

  describe "resident_memory_bytes_from_bundle/1 for SPEC.md §6.4" do
    test "prefers safetensors index metadata total_size over file-size fallback", ctx do
      write_safetensors(ctx.tmp_dir, "model.safetensors", "small")
      write_safetensors_index(ctx.tmp_dir, %{"metadata" => %{"total_size" => 6_442_450_944}})

      assert {:ok, 6_442_450_944} =
               MemoryEstimator.resident_memory_bytes_from_bundle(ctx.tmp_dir)
    end

    test "accepts clean decimal string total_size from safetensors index", ctx do
      write_safetensors_index(ctx.tmp_dir, %{"metadata" => %{"total_size" => " 2048 "}})

      assert {:ok, 2048} = MemoryEstimator.resident_memory_bytes_from_bundle(ctx.tmp_dir)
    end

    test "falls back to safetensors regular file sizes when index is missing", ctx do
      File.mkdir_p!(Path.join(ctx.tmp_dir, "nested"))
      write_safetensors(ctx.tmp_dir, "model-00001-of-00002.safetensors", String.duplicate("a", 7))
      write_safetensors(ctx.tmp_dir, "nested/model-00002-of-00002.safetensors", "bbb")
      File.write!(Path.join(ctx.tmp_dir, "notes.txt"), String.duplicate("x", 100))

      assert {:ok, 10} = MemoryEstimator.resident_memory_bytes_from_bundle(ctx.tmp_dir)
    end

    test "falls back to safetensors regular file sizes when index is malformed", ctx do
      File.write!(Path.join(ctx.tmp_dir, "model.safetensors.index.json"), "not json")
      write_safetensors(ctx.tmp_dir, "model.safetensors", "weights")

      assert {:ok, 7} = MemoryEstimator.resident_memory_bytes_from_bundle(ctx.tmp_dir)
    end

    test "returns :unknown for unusable index metadata without fallback files", ctx do
      invalid_total_sizes = [
        0,
        -1,
        1.5,
        true,
        "12.0",
        "12 bytes",
        "",
        9_223_372_036_854_775_808,
        "9223372036854775808"
      ]

      Enum.each(invalid_total_sizes, fn total_size ->
        bundle_dir = Path.join(ctx.tmp_dir, "case_#{System.unique_integer([:positive])}")
        File.mkdir_p!(bundle_dir)
        write_safetensors_index(bundle_dir, %{"metadata" => %{"total_size" => total_size}})

        assert :unknown = MemoryEstimator.resident_memory_bytes_from_bundle(bundle_dir)
      end)
    end

    test "falls back to safetensors file sizes when index total_size is oversized", ctx do
      write_safetensors_index(ctx.tmp_dir, %{
        "metadata" => %{"total_size" => "9223372036854775808"}
      })

      write_safetensors(ctx.tmp_dir, "model.safetensors", "abc")

      assert {:ok, 3} = MemoryEstimator.resident_memory_bytes_from_bundle(ctx.tmp_dir)
    end

    test "returns :unknown when safetensors fallback totals zero bytes", ctx do
      write_safetensors(ctx.tmp_dir, "model.safetensors", "")

      assert :unknown = MemoryEstimator.resident_memory_bytes_from_bundle(ctx.tmp_dir)
    end

    test "returns :unknown when no resident-memory source is usable", ctx do
      File.write!(Path.join(ctx.tmp_dir, "readme.md"), "no weights here")

      assert :unknown = MemoryEstimator.resident_memory_bytes_from_bundle(ctx.tmp_dir)
    end

    test "returns :unknown when safetensors fallback encounters unsupported entries", ctx do
      write_safetensors(ctx.tmp_dir, "model.safetensors", "weights")
      File.ln_s!("model.safetensors", Path.join(ctx.tmp_dir, "linked.safetensors"))

      assert :unknown = MemoryEstimator.resident_memory_bytes_from_bundle(ctx.tmp_dir)
    end
  end

  defp write_safetensors(dir, relative_path, content) do
    path = Path.join(dir, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp write_safetensors_index(dir, data) do
    File.write!(Path.join(dir, "model.safetensors.index.json"), Jason.encode!(data))
  end
end
