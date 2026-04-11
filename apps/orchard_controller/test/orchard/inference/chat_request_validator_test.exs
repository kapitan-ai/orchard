defmodule Orchard.Inference.ChatRequestValidatorTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.ChatRequestValidator

  @valid_params %{
    "model" => "llama-3.1-8b-instruct@mlx-q4-v1",
    "messages" => [
      %{"role" => "user", "content" => "Hello"}
    ]
  }

  describe "supported fields" do
    test "accepts minimal valid request" do
      assert {:ok, _} = ChatRequestValidator.validate(@valid_params)
    end

    test "accepts all supported optional fields" do
      params =
        Map.merge(@valid_params, %{
          "temperature" => 0.7,
          "top_p" => 0.9,
          "max_tokens" => 100,
          "stop" => ["\n"],
          "stream" => true,
          "user" => "user-123",
          "metadata" => %{"key" => "value"},
          "tools" => [%{"type" => "function", "function" => %{"name" => "f"}}],
          "tool_choice" => "auto",
          "response_format" => %{"type" => "json_object"},
          "seed" => 42
        })

      assert {:ok, _} = ChatRequestValidator.validate(params)
    end

    test "rejects unsupported fields" do
      params = Map.put(@valid_params, "frequency_penalty", 0.5)

      assert {:error, :unsupported_parameter, "frequency_penalty"} =
               ChatRequestValidator.validate(params)
    end
  end

  describe "required fields" do
    test "rejects missing model" do
      params = Map.delete(@valid_params, "model")
      assert {:error, :missing_required_field, "model"} = ChatRequestValidator.validate(params)
    end

    test "rejects missing messages" do
      params = Map.delete(@valid_params, "messages")
      assert {:error, :missing_required_field, "messages"} = ChatRequestValidator.validate(params)
    end
  end

  describe "explicitly rejected parameters" do
    test "rejects n != 1" do
      params = Map.put(@valid_params, "n", 2)
      assert {:error, :unsupported_parameter, "n"} = ChatRequestValidator.validate(params)
    end

    test "rejects modalities" do
      params = Map.put(@valid_params, "modalities", ["text", "audio"])

      assert {:error, :unsupported_parameter, "modalities"} =
               ChatRequestValidator.validate(params)
    end

    test "rejects audio" do
      params = Map.put(@valid_params, "audio", %{})
      assert {:error, :unsupported_parameter, "audio"} = ChatRequestValidator.validate(params)
    end

    test "rejects logprobs" do
      params = Map.put(@valid_params, "logprobs", true)
      assert {:error, :unsupported_parameter, "logprobs"} = ChatRequestValidator.validate(params)
    end

    test "rejects top_logprobs" do
      params = Map.put(@valid_params, "top_logprobs", 5)

      assert {:error, :unsupported_parameter, "top_logprobs"} =
               ChatRequestValidator.validate(params)
    end

    test "rejects parallel_tool_calls=true" do
      params = Map.put(@valid_params, "parallel_tool_calls", true)

      assert {:error, :unsupported_parameter, "parallel_tool_calls"} =
               ChatRequestValidator.validate(params)
    end

    test "rejects json_schema response format" do
      params = Map.put(@valid_params, "response_format", %{"type" => "json_schema"})
      assert {:error, :unsupported_parameter, _} = ChatRequestValidator.validate(params)
    end
  end

  describe "message validation" do
    test "accepts supported roles" do
      for role <- ["system", "developer", "user", "assistant", "tool"] do
        params = %{@valid_params | "messages" => [%{"role" => role, "content" => "hi"}]}
        assert {:ok, _} = ChatRequestValidator.validate(params)
      end
    end

    test "rejects unsupported roles" do
      params = %{@valid_params | "messages" => [%{"role" => "admin", "content" => "hi"}]}

      assert {:error, :invalid_value, "messages[0].role", _} =
               ChatRequestValidator.validate(params)
    end

    test "accepts string content" do
      params = %{@valid_params | "messages" => [%{"role" => "user", "content" => "Hello"}]}
      assert {:ok, _} = ChatRequestValidator.validate(params)
    end

    test "accepts array of text parts" do
      params = %{
        @valid_params
        | "messages" => [
            %{
              "role" => "user",
              "content" => [%{"type" => "text", "text" => "Hello"}]
            }
          ]
      }

      assert {:ok, _} = ChatRequestValidator.validate(params)
    end

    test "rejects image_url content parts" do
      params = %{
        @valid_params
        | "messages" => [
            %{
              "role" => "user",
              "content" => [%{"type" => "image_url", "image_url" => %{"url" => "http://..."}}]
            }
          ]
      }

      assert {:error, :unsupported_parameter, _} = ChatRequestValidator.validate(params)
    end

    test "accepts nil content for assistant messages" do
      params = %{
        @valid_params
        | "messages" => [
            %{"role" => "user", "content" => "hi"},
            %{"role" => "assistant", "content" => nil}
          ]
      }

      assert {:ok, _} = ChatRequestValidator.validate(params)
    end
  end

  describe "tooling validation" do
    test "accepts nil tool_choice" do
      params = Map.put(@valid_params, "tool_choice", nil)
      assert {:ok, _} = ChatRequestValidator.validate(params)
    end

    test "accepts registry ref tools" do
      params =
        Map.put(@valid_params, "tools", [
          %{"type" => "function", "ref" => "tool://lookup_weather@2026-04-09"}
        ])

      assert {:ok, _} = ChatRequestValidator.validate(params)
    end

    test "accepts named tool_choice when refs are present" do
      params =
        Map.merge(@valid_params, %{
          "tools" => [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-09"}],
          "tool_choice" => %{"type" => "function", "function" => %{"name" => "lookup_weather"}}
        })

      assert {:ok, _} = ChatRequestValidator.validate(params)
    end

    test "rejects duplicate tool names" do
      params =
        Map.put(@valid_params, "tools", [
          %{"type" => "function", "function" => %{"name" => "lookup_weather"}},
          %{"type" => "function", "function" => %{"name" => "lookup_weather"}}
        ])

      assert {:error, :invalid_value, "tools", _} = ChatRequestValidator.validate(params)
    end

    test "rejects duplicate identical refs" do
      params =
        Map.put(@valid_params, "tools", [
          %{"type" => "function", "ref" => "tool://lookup_weather@2026-04-09"},
          %{"type" => "function", "ref" => "tool://lookup_weather@2026-04-09"}
        ])

      assert {:error, :invalid_value, "tools", _} = ChatRequestValidator.validate(params)
    end

    test "rejects same-name multi-version refs" do
      params =
        Map.put(@valid_params, "tools", [
          %{"type" => "function", "ref" => "tool://lookup_weather@2026-04-09"},
          %{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}
        ])

      assert {:error, :invalid_value, "tools", _} = ChatRequestValidator.validate(params)
    end

    test "rejects mixed function and ref tool entries" do
      params =
        Map.put(@valid_params, "tools", [
          %{
            "type" => "function",
            "function" => %{"name" => "lookup_weather"},
            "ref" => "tool://lookup_weather@2026-04-09"
          }
        ])

      assert {:error, :invalid_value, "tools", _} = ChatRequestValidator.validate(params)
    end

    test "rejects invalid ref syntax" do
      params =
        Map.put(@valid_params, "tools", [
          %{"type" => "function", "ref" => "tool://lookup_weather"}
        ])

      assert {:error, :invalid_value, "tools", _} = ChatRequestValidator.validate(params)
    end

    test "rejects required tool_choice with empty tools" do
      params = Map.merge(@valid_params, %{"tools" => [], "tool_choice" => "required"})
      assert {:error, :invalid_value, "tool_choice", _} = ChatRequestValidator.validate(params)
    end

    test "rejects named tool_choice when inline tool is missing and refs are absent" do
      params =
        Map.merge(@valid_params, %{
          "tools" => [%{"type" => "function", "function" => %{"name" => "lookup_weather"}}],
          "tool_choice" => %{"type" => "function", "function" => %{"name" => "lookup_news"}}
        })

      assert {:error, :invalid_value, "tool_choice", _} = ChatRequestValidator.validate(params)
    end

    test "rejects non-function tools" do
      params =
        Map.put(@valid_params, "tools", [
          %{"type" => "web_search", "function" => %{"name" => "lookup_weather"}}
        ])

      assert {:error, :unsupported_parameter, "tools"} =
               ChatRequestValidator.validate(params)
    end
  end

  describe "optional field validation" do
    test "rejects non-boolean stream" do
      params = Map.put(@valid_params, "stream", "yes")
      assert {:error, :invalid_value, "stream", _} = ChatRequestValidator.validate(params)
    end

    test "rejects negative temperature" do
      params = Map.put(@valid_params, "temperature", -0.5)
      assert {:error, :invalid_value, "temperature", _} = ChatRequestValidator.validate(params)
    end

    test "rejects top_p out of range" do
      params = Map.put(@valid_params, "top_p", 0)
      assert {:error, :invalid_value, "top_p", _} = ChatRequestValidator.validate(params)
    end

    test "rejects both max_tokens and max_completion_tokens" do
      params = Map.merge(@valid_params, %{"max_tokens" => 100, "max_completion_tokens" => 200})
      assert {:error, :invalid_value, "max_tokens", _} = ChatRequestValidator.validate(params)
    end

    test "rejects non-positive max_tokens" do
      params = Map.put(@valid_params, "max_tokens", 0)
      assert {:error, :invalid_value, "max_tokens", _} = ChatRequestValidator.validate(params)
    end

    test "rejects non-integer seed" do
      params = Map.put(@valid_params, "seed", 1.5)
      assert {:error, :invalid_value, "seed", _} = ChatRequestValidator.validate(params)
    end
  end
end
