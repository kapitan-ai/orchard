defmodule Orchard.Tokenizer.CallerStrings do
  @moduledoc """
  Walks caller-authored strings before chat-template rendering.
  """

  @schema_named_collections ~w($defs definitions dependentSchemas patternProperties properties)

  @schema_keywords ~w(
    $defs additionalItems additionalProperties allOf anyOf const contains default definitions
    dependentSchemas description else enum examples exclusiveMaximum exclusiveMinimum format if items
    maximum maxItems maxLength maxProperties minimum minItems minLength minProperties multipleOf
    not oneOf pattern patternProperties prefixItems properties propertyNames required then title type
    unevaluatedItems unevaluatedProperties
  )

  @type provenance_path :: String.t()
  @type caller_string :: {provenance_path(), String.t()}

  @spec walk_caller_strings([map()], [map()], map() | String.t() | nil) :: [caller_string()]
  def walk_caller_strings(input_items, tools, tool_choice) do
    message_strings(input_items) ++ tool_strings(tools) ++ tool_choice_strings(tool_choice)
  end

  defp message_strings(input_items) when is_list(input_items) do
    input_items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> message_item_strings(item, index) end)
  end

  defp message_strings(_input_items), do: []

  defp message_item_strings(item, index) when is_map(item) do
    message_role_string(item, index) ++
      content_strings(item, index) ++
      message_tool_call_strings(item, index) ++ tool_call_id_string(item, index)
  end

  defp message_item_strings(_item, _index), do: []

  defp message_role_string(item, index) do
    case string_field(item, :role, "messages[#{index}]") do
      nil -> []
      caller_string -> [caller_string]
    end
  end

  defp content_strings(item, index) do
    case fetch_field(item, :content) do
      content when is_binary(content) ->
        [{"messages[#{index}].content", content}]

      parts when is_list(parts) ->
        parts
        |> Enum.with_index()
        |> Enum.flat_map(fn {part, part_index} ->
          content_part_strings(part, index, part_index)
        end)

      _other ->
        []
    end
  end

  defp content_part_strings(part, message_index, part_index) when is_map(part) do
    case fetch_field(part, :text) do
      text when is_binary(text) ->
        [{"messages[#{message_index}].content[#{part_index}].text", text}]

      _other ->
        []
    end
  end

  defp content_part_strings(_part, _message_index, _part_index), do: []

  defp message_tool_call_strings(item, message_index) do
    case fetch_field(item, :tool_calls) do
      tool_calls when is_list(tool_calls) ->
        tool_calls
        |> Enum.with_index()
        |> Enum.flat_map(fn {tool_call, call_index} ->
          tool_call_function_strings(tool_call, message_index, call_index)
        end)

      _other ->
        []
    end
  end

  defp tool_call_function_strings(tool_call, message_index, call_index) when is_map(tool_call) do
    function = fetch_field(tool_call, :function)
    call_base = "messages[#{message_index}].tool_calls[#{call_index}]"
    function_base = call_base <> ".function"

    [
      string_field(tool_call, :id, call_base),
      string_field(function, :name, function_base),
      string_field(function, :arguments, function_base)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp tool_call_function_strings(_tool_call, _message_index, _call_index), do: []

  defp tool_call_id_string(item, index) do
    case fetch_field(item, :tool_call_id) do
      tool_call_id when is_binary(tool_call_id) ->
        [{"messages[#{index}].tool_call_id", tool_call_id}]

      _other ->
        []
    end
  end

  defp tool_strings(tools) when is_list(tools) do
    tools
    |> Enum.with_index()
    |> Enum.flat_map(fn {tool, index} -> tool_entry_strings(tool, index) end)
  end

  defp tool_strings(_tools), do: []

  defp tool_entry_strings(tool, index) when is_map(tool) do
    function = fetch_field(tool, :function)
    base = "tools[#{index}].function"

    [
      string_field(tool, :type, "tools[#{index}]"),
      string_field(function, :name, base),
      string_field(function, :description, base)
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(schema_strings(fetch_field(function, :parameters), "#{base}.parameters"))
  end

  defp tool_entry_strings(_tool, _index), do: []

  defp tool_choice_strings(tool_choice) when is_binary(tool_choice) do
    [{"tool_choice", tool_choice}]
  end

  defp tool_choice_strings(%{} = tool_choice) do
    function = fetch_field(tool_choice, :function)

    [
      string_field(tool_choice, :type, "tool_choice"),
      string_field(function, :name, "tool_choice.function")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp tool_choice_strings(_tool_choice), do: []

  defp schema_strings(schema, path), do: schema_strings(schema, path, nil)

  defp schema_strings(%{} = schema, path, _key_context) do
    schema
    |> schema_entries()
    |> Enum.with_index()
    |> Enum.flat_map(fn {{raw_key, value}, index} ->
      schema_entry_strings(raw_key, value, path, index)
    end)
  end

  defp schema_strings(values, path, "enum") when is_list(values), do: enum_strings(values, path)

  defp schema_strings(value, path, _key_context) when is_binary(value), do: [{path, value}]

  defp schema_strings(values, path, key_context) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      schema_strings(value, "#{path}[#{index}]", key_context)
    end)
  end

  defp schema_strings(_value, _path, _key_context), do: []

  defp schema_entry_strings(raw_key, value, path, index) do
    key = key_name(raw_key)
    child_path = schema_child_path(path, key, index)

    case known_schema_entry_strings(key, value, child_path) do
      nil ->
        unknown_key_string(raw_key, key, child_path) ++ schema_strings(value, child_path, key)

      caller_strings ->
        caller_strings
    end
  end

  defp known_schema_entry_strings(key, value, path)
       when key in ["description", "title"] and is_binary(value),
       do: [{path, value}]

  defp known_schema_entry_strings("enum", value, path) when is_list(value),
    do: enum_strings(value, path)

  defp known_schema_entry_strings(key, value, path)
       when key in @schema_named_collections and is_map(value),
       do: named_schema_collection_strings(value, path)

  defp known_schema_entry_strings("required", value, path) when is_list(value),
    do: required_strings(value, path)

  defp known_schema_entry_strings(_key, _value, _path), do: nil

  defp named_schema_collection_strings(schemas, path) do
    schemas
    |> schema_entries()
    |> Enum.with_index()
    |> Enum.flat_map(fn {{raw_key, value}, index} ->
      child_path = "#{path}[#{index}]"
      property_key_string(raw_key, child_path) ++ schema_strings(value, child_path)
    end)
  end

  defp enum_strings(values, path) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {value, index} when is_binary(value) -> [{"#{path}[#{index}]", value}]
      {_value, _index} -> []
    end)
  end

  defp required_strings(values, path) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {value, index} when is_binary(value) -> [{"#{path}[#{index}]", value}]
      {_value, _index} -> []
    end)
  end

  defp string_field(%{} = map, field, base_path) do
    case fetch_field(map, field) do
      value when is_binary(value) -> {"#{base_path}.#{field}", value}
      _other -> nil
    end
  end

  defp string_field(_map, _field, _base_path), do: nil

  defp fetch_field(%{} = map, field) when is_atom(field) do
    case Map.fetch(map, field) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(field))
    end
  end

  defp fetch_field(_map, _field), do: nil

  defp schema_entries(schema) do
    Enum.sort_by(schema, fn {key, _value} -> key_name(key) end)
  end

  defp property_key_string(raw_key, path) when is_binary(raw_key) or is_atom(raw_key) do
    [{"#{path}.__key__", key_name(raw_key)}]
  end

  defp property_key_string(_raw_key, _path), do: []

  defp unknown_key_string(raw_key, key, path) do
    if schema_keyword?(key) do
      []
    else
      property_key_string(raw_key, path)
    end
  end

  defp schema_child_path(path, key, index) do
    if schema_keyword?(key) do
      child_path(path, key)
    else
      "#{path}.fields[#{index}]"
    end
  end

  defp schema_keyword?(key), do: key in @schema_keywords

  defp child_path(path, key), do: path <> "." <> key

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(key), do: inspect(key)
end
