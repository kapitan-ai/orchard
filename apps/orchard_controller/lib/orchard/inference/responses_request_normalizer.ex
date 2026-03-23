defmodule Orchard.Inference.ResponsesRequestNormalizer do
  @moduledoc """
  Normalizes bounded `/v1/responses` params into an `Orchard.CanonicalRequest`.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.ChatRequestNormalizer

  @spec normalize(map(), keyword()) :: {:ok, CanonicalRequest.t()}
  def normalize(params, opts \\ []) when is_map(params) do
    public_id = Keyword.get(opts, :public_id, "resp_" <> Ecto.UUID.generate())
    internal_id = Keyword.get(opts, :internal_id, Ecto.UUID.generate())

    normalizer_opts =
      opts
      |> Keyword.take([:tenant_id, :principal_id, :api_key_id])
      |> Keyword.put(:internal_id, internal_id)
      |> Keyword.put(:public_id, public_id)

    {:ok, %CanonicalRequest{} = canonical} =
      params
      |> build_chat_params()
      |> ChatRequestNormalizer.normalize(normalizer_opts)

    {:ok, %{canonical | endpoint: :responses}}
  end

  defp build_chat_params(params) do
    %{"messages" => build_messages(params)}
    |> put_optional("stream", Map.get(params, "stream"))
    |> put_optional("temperature", Map.get(params, "temperature"))
    |> put_optional("top_p", Map.get(params, "top_p"))
    |> put_optional("metadata", normalize_metadata(Map.get(params, "metadata")))
    |> put_optional("max_completion_tokens", Map.get(params, "max_output_tokens"))
    |> Map.put("model", Map.fetch!(params, "model"))
  end

  defp build_messages(params) do
    instructions_message(params) ++ normalize_input(Map.fetch!(params, "input"))
  end

  defp instructions_message(%{"instructions" => instructions}) when is_binary(instructions) do
    [%{"role" => "system", "content" => instructions}]
  end

  defp instructions_message(_params), do: []

  defp normalize_input(input) when is_binary(input) do
    [%{"role" => "user", "content" => input}]
  end

  defp normalize_input(input) when is_list(input) do
    Enum.map(input, fn item ->
      %{
        "role" => Map.get(item, "role"),
        "content" => normalize_content(Map.get(item, "content"))
      }
    end)
  end

  defp normalize_content(content) when is_binary(content), do: content

  defp normalize_content(content) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "input_text", "text" => text} -> %{"type" => "text", "text" => text}
      %{"type" => "text", "text" => text} -> %{"type" => "text", "text" => text}
    end)
  end

  defp normalize_metadata(nil), do: %{}
  defp normalize_metadata(metadata), do: metadata

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
