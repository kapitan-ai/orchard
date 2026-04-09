defmodule Orchard.Inference.ResponsesRequestValidatorTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.ResponsesRequestValidator

  @valid_params %{
    "model" => "llama-3.1-8b-instruct@mlx-q4-v1",
    "input" => "Hello"
  }

  test "accepts minimal valid request" do
    assert {:ok, _} = ResponsesRequestValidator.validate(@valid_params)
  end

  test "accepts supported optional fields" do
    params =
      Map.merge(@valid_params, %{
        "instructions" => "Be concise",
        "temperature" => 0.7,
        "top_p" => 0.9,
        "max_output_tokens" => 128,
        "metadata" => %{"request_id" => "abc"},
        "store" => true
      })

    assert {:ok, _} = ResponsesRequestValidator.validate(params)
  end

  test "accepts array input items with text content parts" do
    params = %{
      @valid_params
      | "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "Hello"}]
          }
        ]
    }

    assert {:ok, _} = ResponsesRequestValidator.validate(params)
  end

  test "rejects missing model" do
    assert {:error, :missing_required_field, "model"} =
             ResponsesRequestValidator.validate(Map.delete(@valid_params, "model"))
  end

  test "rejects missing input" do
    assert {:error, :missing_required_field, "input"} =
             ResponsesRequestValidator.validate(Map.delete(@valid_params, "input"))
  end

  test "rejects malformed model values" do
    assert {:error, :invalid_value, "model", _} =
             ResponsesRequestValidator.validate(Map.put(@valid_params, "model", 123))

    assert {:error, :invalid_value, "model", _} =
             ResponsesRequestValidator.validate(Map.put(@valid_params, "model", ""))

    assert {:error, :invalid_value, "model", _} =
             ResponsesRequestValidator.validate(Map.put(@valid_params, "model", "foo@"))
  end

  test "accepts stream: true" do
    assert {:ok, _} = ResponsesRequestValidator.validate(Map.put(@valid_params, "stream", true))
  end

  test "accepts stream: false" do
    assert {:ok, _} = ResponsesRequestValidator.validate(Map.put(@valid_params, "stream", false))
  end

  test "rejects non-boolean stream" do
    assert {:error, :invalid_value, "stream", _} =
             ResponsesRequestValidator.validate(Map.put(@valid_params, "stream", "yes"))

    assert {:error, :invalid_value, "stream", _} =
             ResponsesRequestValidator.validate(Map.put(@valid_params, "stream", 1))
  end

  test "accepts tools and tool_choice" do
    params =
      Map.merge(@valid_params, %{
        "tools" => [%{"type" => "function", "function" => %{"name" => "lookup_weather"}}],
        "tool_choice" => "auto"
      })

    assert {:ok, _} = ResponsesRequestValidator.validate(params)
  end

  test "accepts nil tool_choice" do
    assert {:ok, _} =
             ResponsesRequestValidator.validate(Map.put(@valid_params, "tool_choice", nil))
  end

  test "rejects duplicate tool names" do
    params =
      Map.put(@valid_params, "tools", [
        %{"type" => "function", "function" => %{"name" => "lookup_weather"}},
        %{"type" => "function", "function" => %{"name" => "lookup_weather"}}
      ])

    assert {:error, :invalid_value, "tools", _} = ResponsesRequestValidator.validate(params)
  end

  test "rejects required tool_choice with empty tools" do
    params = Map.merge(@valid_params, %{"tools" => [], "tool_choice" => "required"})
    assert {:error, :invalid_value, "tool_choice", _} = ResponsesRequestValidator.validate(params)
  end

  test "rejects named tool_choice when tool is missing" do
    params =
      Map.merge(@valid_params, %{
        "tools" => [%{"type" => "function", "function" => %{"name" => "lookup_weather"}}],
        "tool_choice" => %{"type" => "function", "function" => %{"name" => "lookup_news"}}
      })

    assert {:error, :invalid_value, "tool_choice", _} = ResponsesRequestValidator.validate(params)
  end

  test "rejects non-function tools" do
    params =
      Map.put(@valid_params, "tools", [
        %{"type" => "web_search", "function" => %{"name" => "lookup_weather"}}
      ])

    assert {:error, :unsupported_parameter, "tools"} = ResponsesRequestValidator.validate(params)
  end

  test "rejects object input shape" do
    assert {:error, :invalid_value, "input", _} =
             ResponsesRequestValidator.validate(
               Map.put(@valid_params, "input", %{"text" => "hello"})
             )
  end

  test "rejects unsupported roles" do
    params = %{
      @valid_params
      | "input" => [%{"role" => "tool", "content" => "Hello"}]
    }

    assert {:error, :invalid_value, "input[0].role", _} =
             ResponsesRequestValidator.validate(params)
  end

  test "rejects nil content in array input items" do
    params = %{
      @valid_params
      | "input" => [%{"role" => "assistant", "content" => nil}]
    }

    assert {:error, :invalid_value, "input[0].content", _} =
             ResponsesRequestValidator.validate(params)
  end

  test "rejects image content parts" do
    params = %{
      @valid_params
      | "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "image_url", "image_url" => %{"url" => "http://..."}}]
          }
        ]
    }

    assert {:error, :unsupported_parameter, "input[0].content[0].type=image_url"} =
             ResponsesRequestValidator.validate(params)
  end

  test "rejects invalid scalar fields" do
    assert {:error, :invalid_value, "temperature", _} =
             ResponsesRequestValidator.validate(Map.put(@valid_params, "temperature", -1))

    assert {:error, :invalid_value, "top_p", _} =
             ResponsesRequestValidator.validate(Map.put(@valid_params, "top_p", 0))

    assert {:error, :invalid_value, "max_output_tokens", _} =
             ResponsesRequestValidator.validate(Map.put(@valid_params, "max_output_tokens", 0))

    assert {:error, :invalid_value, "metadata", _} =
             ResponsesRequestValidator.validate(Map.put(@valid_params, "metadata", "bad"))

    assert {:error, :invalid_value, "store", _} =
             ResponsesRequestValidator.validate(Map.put(@valid_params, "store", "yes"))
  end
end
