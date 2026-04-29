defmodule Orchard.Tokenizer.ControlTokenDetector do
  @moduledoc """
  Detects control-token literals in caller-authored strings.
  """

  alias Orchard.PathUtils

  @singleton_keys ~w(bos_token eos_token pad_token unk_token cls_token sep_token mask_token)

  @type catalog :: [String.t()]
  @type caller_string :: {String.t(), String.t()}
  @type diagnostic :: {:tokenizer_config, term()}
  @type hit :: {String.t(), String.t(), non_neg_integer()}

  @spec partial_catalog(String.t()) :: {:ok, catalog(), [diagnostic()]} | {:error, term()}
  def partial_catalog(tokenizer_path) when is_binary(tokenizer_path) do
    with {:ok, tokenizer} <- read_json_object(tokenizer_path) do
      {tokenizer_config, diagnostics} = read_tokenizer_config(tokenizer_path)

      catalog =
        tokenizer
        |> added_tokens()
        |> Kernel.++(config_singletons(tokenizer_config))
        |> Kernel.++(additional_special_tokens(tokenizer_config))
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, catalog, diagnostics}
    end
  end

  def partial_catalog(tokenizer_path), do: {:error, {:invalid_tokenizer_path, tokenizer_path}}

  @spec detect(catalog(), [caller_string()]) :: [hit()]
  def detect(catalog, caller_strings) when is_list(catalog) and is_list(caller_strings) do
    catalog
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn literal -> detect_literal(literal, caller_strings) end)
    |> Enum.sort_by(fn {path, _literal, byte_offset} -> {path, byte_offset} end)
  end

  defp read_tokenizer_config(tokenizer_path) do
    tokenizer_dir = Path.dirname(tokenizer_path)
    config_path = Path.join(tokenizer_dir, "tokenizer_config.json")

    case PathUtils.resolve_realpath(tokenizer_dir) do
      {:ok, real_tokenizer_dir} ->
        read_tokenizer_config(config_path, real_tokenizer_dir)

      {:error, reason} ->
        {%{}, [{:tokenizer_config, {:json_read_failed, "tokenizer_config.json", reason}}]}
    end
  end

  defp read_tokenizer_config(config_path, real_tokenizer_dir) do
    case PathUtils.resolve_realpath(config_path) do
      {:ok, real_config_path} ->
        read_confined_tokenizer_config(real_config_path, real_tokenizer_dir)

      {:error, :enoent} ->
        {%{}, []}

      {:error, reason} ->
        {%{}, [{:tokenizer_config, {:json_read_failed, "tokenizer_config.json", reason}}]}
    end
  end

  defp read_confined_tokenizer_config(real_config_path, real_tokenizer_dir) do
    if confined_to_directory?(real_config_path, real_tokenizer_dir) do
      read_optional_config_object(real_config_path)
    else
      {%{}, [{:tokenizer_config, {:asset_escapes_tokenizer_root, "tokenizer_config.json"}}]}
    end
  end

  defp read_optional_config_object(path) do
    case read_json_object(path) do
      {:ok, object} -> {object, []}
      {:error, reason} -> {%{}, [{:tokenizer_config, reason}]}
    end
  end

  defp confined_to_directory?(path, real_root) do
    case Path.relative_to(path, real_root) do
      <<"..", _rest::binary>> -> false
      ^path -> false
      _relative_path -> true
    end
  end

  defp read_json_object(path) do
    case File.read(path) do
      {:ok, contents} -> decode_json_object(contents, path)
      {:error, reason} -> {:error, {:json_read_failed, Path.basename(path), reason}}
    end
  end

  defp decode_json_object(contents, path) do
    case Jason.decode(contents) do
      {:ok, %{} = object} -> {:ok, object}
      {:ok, _other} -> {:error, {:invalid_json_object, Path.basename(path)}}
      {:error, %Jason.DecodeError{}} -> {:error, {:invalid_json, Path.basename(path)}}
    end
  end

  defp added_tokens(%{"added_tokens" => added_tokens}) when is_list(added_tokens) do
    Enum.flat_map(added_tokens, fn
      %{"content" => content, "special" => true} when is_binary(content) -> [content]
      _other -> []
    end)
  end

  defp added_tokens(_tokenizer), do: []

  defp config_singletons(config) do
    Enum.flat_map(@singleton_keys, fn key -> token_content(Map.get(config, key)) end)
  end

  defp additional_special_tokens(%{"additional_special_tokens" => tokens}) when is_list(tokens) do
    Enum.flat_map(tokens, &token_content/1)
  end

  defp additional_special_tokens(_config), do: []

  defp token_content(content) when is_binary(content), do: [content]
  defp token_content(%{"content" => content}) when is_binary(content), do: [content]
  defp token_content(_content), do: []

  defp detect_literal(literal, caller_strings) do
    Enum.flat_map(caller_strings, fn
      {path, value} when is_binary(path) and is_binary(value) ->
        value
        |> :binary.matches(literal)
        |> Enum.map(fn {byte_offset, _length} -> {path, literal, byte_offset} end)

      _other ->
        []
    end)
  end
end
