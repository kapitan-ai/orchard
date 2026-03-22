defmodule Orchard.Inference.MessageValidation do
  @moduledoc false

  @chat_roles MapSet.new(["system", "developer", "user", "assistant", "tool"])
  @responses_roles MapSet.new(["system", "developer", "user", "assistant"])

  @spec validate_chat_messages(list()) ::
          :ok | {:error, atom(), String.t()} | {:error, atom(), String.t(), String.t()}
  def validate_chat_messages(messages) when is_list(messages) do
    validate_messages(messages,
      field: "messages",
      roles: @chat_roles,
      allow_nil_content?: true,
      allowed_part_types: ["text"],
      unsupported_part_types: ["image_url"]
    )
  end

  @spec validate_responses_input_items(list()) ::
          :ok | {:error, atom(), String.t()} | {:error, atom(), String.t(), String.t()}
  def validate_responses_input_items(messages) when is_list(messages) do
    validate_messages(messages,
      field: "input",
      roles: @responses_roles,
      allow_nil_content?: false,
      allowed_part_types: ["text", "input_text"],
      unsupported_part_types: ["image_url", "input_image", "image", "file", "input_file"]
    )
  end

  defp validate_messages(messages, opts) do
    field = Keyword.fetch!(opts, :field)
    roles = Keyword.fetch!(opts, :roles)
    allow_nil_content? = Keyword.fetch!(opts, :allow_nil_content?)
    allowed_part_types = Keyword.fetch!(opts, :allowed_part_types)
    unsupported_part_types = Keyword.fetch!(opts, :unsupported_part_types)

    messages
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {message, idx}, :ok ->
      case validate_message(
             message,
             idx,
             field,
             roles,
             allow_nil_content?,
             allowed_part_types,
             unsupported_part_types
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_message(
         message,
         idx,
         field,
         roles,
         allow_nil_content?,
         allowed_part_types,
         unsupported_part_types
       )
       when is_map(message) do
    role = Map.get(message, "role")

    cond do
      is_nil(role) ->
        {:error, :invalid_value, "#{field}[#{idx}].role", "is required"}

      not MapSet.member?(roles, role) ->
        {:error, :invalid_value, "#{field}[#{idx}].role", "unsupported role: #{inspect(role)}"}

      true ->
        validate_message_content(
          Map.get(message, "content"),
          idx,
          field,
          allow_nil_content?,
          allowed_part_types,
          unsupported_part_types
        )
    end
  end

  defp validate_message(
         _message,
         idx,
         field,
         _roles,
         _allow_nil_content?,
         _allowed_part_types,
         _unsupported_part_types
       ) do
    {:error, :invalid_value, "#{field}[#{idx}]", "must be an object"}
  end

  defp validate_message_content(
         nil,
         _idx,
         _field,
         true,
         _allowed_part_types,
         _unsupported_part_types
       ),
       do: :ok

  defp validate_message_content(
         content,
         _idx,
         _field,
         _allow_nil_content?,
         _allowed_part_types,
         _unsupported_part_types
       )
       when is_binary(content), do: :ok

  defp validate_message_content(
         nil,
         idx,
         field,
         false,
         _allowed_part_types,
         _unsupported_part_types
       ) do
    {:error, :invalid_value, "#{field}[#{idx}].content",
     "must be a string or array of text parts"}
  end

  defp validate_message_content(
         content,
         idx,
         field,
         _allow_nil_content?,
         allowed_part_types,
         unsupported_part_types
       )
       when is_list(content) do
    content
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {part, part_idx}, :ok ->
      case validate_content_part(
             part,
             idx,
             part_idx,
             field,
             allowed_part_types,
             unsupported_part_types
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_message_content(
         _content,
         idx,
         field,
         _allow_nil_content?,
         _allowed_part_types,
         _unsupported_part_types
       ) do
    {:error, :invalid_value, "#{field}[#{idx}].content",
     "must be a string or array of text parts"}
  end

  defp validate_content_part(
         %{"type" => type, "text" => text},
         msg_idx,
         part_idx,
         field,
         allowed_part_types,
         _unsupported_part_types
       ) do
    if type in allowed_part_types and is_binary(text) do
      :ok
    else
      {:error, :invalid_value, "#{field}[#{msg_idx}].content[#{part_idx}]",
       "must be a text content part object"}
    end
  end

  defp validate_content_part(
         %{"type" => type},
         msg_idx,
         part_idx,
         field,
         _allowed_part_types,
         unsupported_part_types
       ) do
    if type in unsupported_part_types do
      {:error, :unsupported_parameter, "#{field}[#{msg_idx}].content[#{part_idx}].type=#{type}"}
    else
      {:error, :invalid_value, "#{field}[#{msg_idx}].content[#{part_idx}].type",
       "unsupported content type: #{inspect(type)}"}
    end
  end

  defp validate_content_part(
         _part,
         msg_idx,
         part_idx,
         field,
         _allowed_part_types,
         _unsupported_part_types
       ) do
    {:error, :invalid_value, "#{field}[#{msg_idx}].content[#{part_idx}]",
     "must be a text content part object"}
  end
end
