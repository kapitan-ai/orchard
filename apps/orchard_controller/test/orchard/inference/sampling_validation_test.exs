defmodule Orchard.Inference.SamplingValidationTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.SamplingValidation

  describe "validate_temperature/1" do
    test "accepts native numeric values greater than or equal to zero" do
      assert :ok = SamplingValidation.validate_temperature(%{})
      assert :ok = SamplingValidation.validate_temperature(%{"temperature" => 0})
      assert :ok = SamplingValidation.validate_temperature(%{"temperature" => 0.7})
    end

    test "rejects negative and non-native-numeric values with the API error string" do
      assert {:error, :invalid_value, "temperature", "must be a non-negative number"} =
               SamplingValidation.validate_temperature(%{"temperature" => -0.1})

      assert {:error, :invalid_value, "temperature", "must be a non-negative number"} =
               SamplingValidation.validate_temperature(%{"temperature" => "0.7"})

      assert {:error, :invalid_value, "temperature", "must be a non-negative number"} =
               SamplingValidation.validate_temperature(%{"temperature" => nil})
    end
  end

  describe "validate_top_p/1" do
    test "accepts native numeric values in the OpenAI-compatible range" do
      assert :ok = SamplingValidation.validate_top_p(%{})
      assert :ok = SamplingValidation.validate_top_p(%{"top_p" => 0.1})
      assert :ok = SamplingValidation.validate_top_p(%{"top_p" => 1})
    end

    test "rejects out-of-range and non-native-numeric values with the API error string" do
      assert {:error, :invalid_value, "top_p", "must be between 0 (exclusive) and 1 (inclusive)"} =
               SamplingValidation.validate_top_p(%{"top_p" => 0})

      assert {:error, :invalid_value, "top_p", "must be between 0 (exclusive) and 1 (inclusive)"} =
               SamplingValidation.validate_top_p(%{"top_p" => 1.1})

      assert {:error, :invalid_value, "top_p", "must be between 0 (exclusive) and 1 (inclusive)"} =
               SamplingValidation.validate_top_p(%{"top_p" => "0.9"})

      assert {:error, :invalid_value, "top_p", "must be between 0 (exclusive) and 1 (inclusive)"} =
               SamplingValidation.validate_top_p(%{"top_p" => nil})
    end
  end

  describe "validate_positive_integer/2" do
    test "accepts native positive integers for any supplied field name" do
      assert :ok = SamplingValidation.validate_positive_integer(1, "max_tokens")
      assert :ok = SamplingValidation.validate_positive_integer(128, "max_output_tokens")
    end

    test "rejects non-positive and non-native-integer values using the supplied field name" do
      assert {:error, :invalid_value, "max_completion_tokens", "must be a positive integer"} =
               SamplingValidation.validate_positive_integer(0, "max_completion_tokens")

      assert {:error, :invalid_value, "max_output_tokens", "must be a positive integer"} =
               SamplingValidation.validate_positive_integer(1.5, "max_output_tokens")

      assert {:error, :invalid_value, "max_tokens", "must be a positive integer"} =
               SamplingValidation.validate_positive_integer("10", "max_tokens")

      assert {:error, :invalid_value, "max_tokens", "must be a positive integer"} =
               SamplingValidation.validate_positive_integer(nil, "max_tokens")
    end
  end
end
