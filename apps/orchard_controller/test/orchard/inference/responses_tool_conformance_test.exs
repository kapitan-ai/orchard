defmodule Orchard.Inference.ResponsesToolConformanceTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.{
    ChatRequestValidator,
    ResponsesRequestNormalizer,
    ResponsesRequestValidator
  }

  @tool %{
    "type" => "function",
    "name" => "read_file",
    "description" => "Read a client file",
    "strict" => true,
    "parameters" => %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"],
      "additionalProperties" => false
    }
  }
  @params %{"model" => "test@v1", "input" => "Read the file", "tools" => [@tool]}
  @call %{
    "type" => "function_call",
    "id" => "fc_7",
    "call_id" => "call_z",
    "name" => "read_file",
    "arguments" => "{\"path\":\"a.txt\"}"
  }
  @result %{"type" => "function_call_output", "call_id" => "call_z", "output" => "exact\nresult"}

  test "SPEC §7.2.5 client cache hint is typed but carries no canonical cache authority" do
    opts = [public_id: "resp_fixed", internal_id: "00000000-0000-4000-a000-000000000001"]
    assert {:ok, expected} = ResponsesRequestNormalizer.normalize(@params, opts)

    for hint <- ["client-session", nil] do
      params = Map.put(@params, "prompt_cache_key", hint)
      assert {:ok, _} = ResponsesRequestValidator.validate(params)
      assert {:ok, ^expected} = ResponsesRequestNormalizer.normalize(params, opts)
    end

    assert {:error, :invalid_value, "prompt_cache_key", _} =
             ResponsesRequestValidator.validate(Map.put(@params, "prompt_cache_key", %{}))
  end

  test "SPEC §7.2.5 flattened schema and named choice normalize without changing Chat" do
    params = Map.put(@params, "tool_choice", %{"type" => "function", "name" => "read_file"})
    assert {:ok, ^params} = ResponsesRequestValidator.validate(params)
    assert {:ok, canonical} = ResponsesRequestNormalizer.normalize(params)

    assert canonical.tooling.requested_tools == [
             %{"type" => "function", "function" => Map.delete(@tool, "type")}
           ]

    assert canonical.tooling.tool_choice == %{
             "type" => "function",
             "function" => %{"name" => "read_file"}
           }

    chat = %{
      "model" => "test@v1",
      "messages" => [%{"role" => "user", "content" => "hi"}],
      "tools" => [@tool]
    }

    assert {:error, _, _, _} = ChatRequestValidator.validate(chat)
    nested = %{chat | "tools" => canonical.tooling.requested_tools}
    assert {:ok, _} = ChatRequestValidator.validate(nested)
    assert {:ok, _} = ResponsesRequestValidator.validate(%{@params | "tools" => nested["tools"]})
  end

  test "SPEC §7.2.5 strict false and null are preserved, not defaulted" do
    for strict <- [false, nil] do
      params = %{@params | "tools" => [Map.put(@tool, "strict", strict)]}
      assert {:ok, _} = ResponsesRequestValidator.validate(params)
      assert {:ok, canonical} = ResponsesRequestNormalizer.normalize(params)
      assert get_in(hd(canonical.tooling.requested_tools), ["function", "strict"]) == strict
    end
  end

  test "SPEC §7.2.5 refs remain unresolved until preparation" do
    ref = %{"type" => "function", "ref" => "tool://lookup@v2"}
    params = %{@params | "tools" => [@tool, ref]}
    assert {:ok, _} = ResponsesRequestValidator.validate(params)
    assert {:ok, canonical} = ResponsesRequestNormalizer.normalize(params)
    assert List.last(canonical.tooling.requested_tools) == ref
    assert canonical.tooling.tools == []
  end

  test "SPEC §7.2.5 malformed, unknown, mixed, duplicate and unknown-choice tools fail closed" do
    for tool <- [
          Map.put(@tool, "function", %{"name" => "other"}),
          Map.put(@tool, "ref", "tool://read_file@v1"),
          Map.put(@tool, "strict", "true"),
          Map.put(@tool, "parameters", []),
          Map.put(@tool, "description", 7),
          Map.put(@tool, "extra", true),
          Map.put(@tool, "name", ""),
          %{"type" => "web_search"},
          %{"type" => "function", "ref" => "tool://bad"}
        ] do
      assert {:error, _, _} =
               error_shape(ResponsesRequestValidator.validate(%{@params | "tools" => [tool]}))
    end

    assert {:error, :invalid_value, "tools", _} =
             ResponsesRequestValidator.validate(%{@params | "tools" => [@tool, @tool]})

    for choice <- [
          %{"type" => "function", "name" => "unknown"},
          %{"type" => "function", "name" => "read_file", "function" => %{"name" => "read_file"}}
        ] do
      assert {:error, :invalid_value, "tool_choice", _} =
               ResponsesRequestValidator.validate(Map.put(@params, "tool_choice", choice))
    end
  end

  test "SPEC §7.2.5 mixed text, multiple calls and out-of-order results retain IDs and order" do
    second = %{@call | "id" => "fc_9", "call_id" => "call_a", "arguments" => "{}"}

    text = %{
      "id" => "msg_3",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "Reading"}]
    }

    input = [
      text,
      @call,
      second,
      %{@result | "call_id" => "call_a", "output" => "second"},
      Map.put(@result, "id", "result_8")
    ]

    params = %{@params | "input" => input}
    assert {:ok, _} = ResponsesRequestValidator.validate(params)
    assert {:ok, canonical} = ResponsesRequestNormalizer.normalize(params)
    assert [message, first_call, second_call, second_result, first_result] = canonical.input_items

    assert message == %{
             "responses_item_id" => "msg_3",
             "role" => "assistant",
             "content" => [%{"type" => "text", "text" => "Reading"}]
           }

    assert first_call["tool_calls"] == [
             %{
               "id" => "call_z",
               "responses_item_id" => "fc_7",
               "type" => "function",
               "function" => %{"name" => "read_file", "arguments" => @call["arguments"]}
             }
           ]

    assert hd(second_call["tool_calls"])["id"] == "call_a"
    assert hd(second_call["tool_calls"])["responses_item_id"] == "fc_9"
    assert second_result == %{"role" => "tool", "tool_call_id" => "call_a", "content" => "second"}

    assert first_result == %{
             "responses_item_id" => "result_8",
             "role" => "tool",
             "tool_call_id" => "call_z",
             "content" => "exact\nresult"
           }
  end

  test "SPEC §7.2.5 malformed history cannot reach normalization or dispatch" do
    for input <- [
          [@result],
          [@result, @call],
          [@call, @call],
          [@call, @result, @result],
          [%{@call | "arguments" => "{"}],
          [%{@call | "arguments" => "[]"}],
          [%{@call | "name" => ""}],
          [Map.put(@call, "status", "in_progress")],
          [Map.put(@call, "unknown", true)],
          [@call, Map.put(@result, "id", 7)],
          [%{"id" => %{}, "role" => "assistant", "content" => "hi"}],
          [%{"status" => "in_progress", "role" => "assistant", "content" => "hi"}],
          [%{"type" => "reasoning", "role" => "assistant", "content" => "hidden"}]
        ] do
      assert {:error, :invalid_value, _, _} =
               ResponsesRequestValidator.validate(%{@params | "input" => input})
    end
  end

  defp error_shape({:error, kind, field, _reason}), do: {:error, kind, field}
  defp error_shape(value), do: value
end
