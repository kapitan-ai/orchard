defmodule Orchard.Models.HubClient do
  @moduledoc """
  Controller-local, synchronous Hugging Face Hub client for Model Hub browse/search/detail.

  This module reads only `:orchard_controller, :hf` config, performs direct HF REST
  requests via `Req`, and normalizes variable upstream payloads into stable,
  operator-safe Orchard maps.
  """

  @default_limit 20
  @default_retry_attempts 3
  @default_connect_timeout_ms 10_000
  @default_receive_timeout_ms 30_000
  @initial_backoff_ms 250
  @max_backoff_ms 2_000
  @reserved_req_option_keys [
    :method,
    :url,
    :headers,
    :params,
    :retry,
    :receive_timeout,
    :connect_options,
    :body,
    :json
  ]

  @type error_status :: :unauthorized | :not_found | :rate_limited | :unavailable | :error

  @type error_map :: %{
          status: error_status(),
          code: String.t(),
          message: String.t()
        }

  @type search_result :: %{
          repo_id: String.t(),
          author: String.t() | nil,
          downloads: non_neg_integer(),
          likes: non_neg_integer(),
          tags: [String.t()],
          pipeline_tag: String.t() | nil,
          library_name: String.t() | nil,
          used_storage_bytes: non_neg_integer() | nil,
          last_modified: String.t() | nil,
          gated: boolean()
        }

  @type detail_map :: %{
          repo_id: String.t(),
          revision_sha: String.t() | nil,
          author: String.t() | nil,
          downloads: non_neg_integer(),
          likes: non_neg_integer(),
          tags: [String.t()],
          pipeline_tag: String.t() | nil,
          library_name: String.t() | nil,
          used_storage_bytes: non_neg_integer() | nil,
          last_modified: String.t() | nil,
          gated: boolean(),
          metadata_summary: %{
            license: String.t() | nil,
            languages: [String.t()],
            base_models: [String.t()]
          },
          config_summary: %{
            model_type: String.t() | nil,
            architectures: [String.t()],
            context_window_tokens: non_neg_integer() | nil,
            quantization_bits: non_neg_integer() | nil
          },
          siblings: [%{path: String.t(), size_bytes: non_neg_integer() | nil}]
        }

  @spec search_models(String.t() | nil, []) :: {:ok, [search_result()]} | {:error, error_map()}
  def search_models(query, opts \\ [])

  def search_models(query, _opts) when not (is_nil(query) or is_binary(query)) do
    {:error, error(:error, "invalid_query", "Search query must be blank or text.")}
  end

  def search_models(_query, opts) when not is_list(opts) do
    {:error, error(:error, "invalid_options", "Hub client options are invalid.")}
  end

  def search_models(query, opts) do
    with :ok <- validate_options(opts),
         {:ok, body} <- request_json(["models"], search_params(query)) do
      case body do
        results when is_list(results) ->
          {:ok, results |> Enum.map(&normalize_search_result/1) |> Enum.reject(&is_nil/1)}

        _other ->
          {:error, error(:error, "hf_error", "Hugging Face request failed.")}
      end
    end
  end

  @spec get_model_detail(String.t()) :: {:ok, detail_map()} | {:error, error_map()}
  def get_model_detail(repo_id) when is_binary(repo_id) do
    with {:ok, normalized_repo_id, encoded_repo_id} <- normalize_and_encode_repo_id(repo_id),
         {:ok, body} <- request_json(["models", encoded_repo_id]) do
      case body do
        %{} = payload -> {:ok, normalize_detail(payload, normalized_repo_id)}
        _other -> {:error, error(:error, "hf_error", "Hugging Face request failed.")}
      end
    end
  end

  def get_model_detail(_repo_id) do
    {:error, error(:error, "invalid_repo_id", "Model repository id is invalid.")}
  end

  defp validate_options([]), do: :ok

  defp validate_options(_opts) do
    {:error, error(:error, "invalid_options", "Hub client options are invalid.")}
  end

  defp search_params(query) do
    params = [
      filter: "mlx",
      pipeline_tag: "text-generation",
      sort: "downloads",
      direction: "-1",
      limit: @default_limit
    ]

    case normalize_non_empty_string(query) do
      nil -> params
      trimmed_query -> params ++ [search: trimmed_query]
    end
  end

  defp normalize_and_encode_repo_id(repo_id) do
    trimmed = String.trim(repo_id)

    with true <- trimmed != "",
         segments <- String.split(trimmed, "/", trim: true),
         true <- length(segments) >= 2,
         true <- Enum.all?(segments, &valid_repo_segment?/1) do
      encoded =
        Enum.map_join(segments, "/", fn segment ->
          URI.encode(segment, &URI.char_unreserved?/1)
        end)

      {:ok, trimmed, encoded}
    else
      _other -> {:error, error(:error, "invalid_repo_id", "Model repository id is invalid.")}
    end
  end

  defp valid_repo_segment?(segment) when is_binary(segment) do
    trimmed = String.trim(segment)
    trimmed != "" and trimmed not in [".", ".."]
  end

  defp request_json(path_segments, params \\ []) do
    config = hf_config()
    api_base_url = resolve_api_base_url(config)
    connect_timeout = Keyword.get(config, :connect_timeout_ms, @default_connect_timeout_ms)
    receive_timeout = Keyword.get(config, :receive_timeout_ms, @default_receive_timeout_ms)

    max_attempts =
      max(
        normalize_non_negative_integer(
          Keyword.get(config, :retry_attempts),
          @default_retry_attempts
        ),
        1
      )

    req_options = config |> Keyword.get(:req_options, []) |> sanitize_req_options()

    base_opts = [
      method: :get,
      url: build_api_url(api_base_url, path_segments),
      headers: auth_headers(config),
      params: params,
      connect_options: [timeout: connect_timeout],
      receive_timeout: receive_timeout,
      retry: false
    ]

    do_request(Keyword.merge(base_opts, req_options), 1, max_attempts)
  rescue
    _error ->
      {:error, error(:error, "hf_error", "Hugging Face request failed.")}
  end

  defp do_request(req_opts, attempt, max_attempts) do
    case Req.request(req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        if retryable_status?(status) and attempt < max_attempts do
          backoff(attempt)
          do_request(req_opts, attempt + 1, max_attempts)
        else
          {:error, error_for_status(status)}
        end

      {:error, %Req.TransportError{}} ->
        if attempt < max_attempts do
          backoff(attempt)
          do_request(req_opts, attempt + 1, max_attempts)
        else
          {:error, error(:unavailable, "hf_unavailable", "Hugging Face is unavailable.")}
        end

      {:error, _reason} ->
        {:error, error(:error, "hf_error", "Hugging Face request failed.")}
    end
  end

  defp retryable_status?(429), do: true
  defp retryable_status?(status) when is_integer(status) and status >= 500, do: true
  defp retryable_status?(_status), do: false

  defp error_for_status(status) when status in [401, 403] do
    error(:unauthorized, "hf_unauthorized", "Hugging Face access denied.")
  end

  defp error_for_status(404) do
    error(:not_found, "hf_not_found", "Hugging Face resource not found.")
  end

  defp error_for_status(429) do
    error(:rate_limited, "hf_rate_limited", "Hugging Face rate limit exceeded.")
  end

  defp error_for_status(status) when is_integer(status) and status >= 500 do
    error(:unavailable, "hf_unavailable", "Hugging Face is unavailable.")
  end

  defp error_for_status(_status) do
    error(:error, "hf_error", "Hugging Face request failed.")
  end

  defp error(status, code, message) do
    %{status: status, code: code, message: message}
  end

  defp auth_headers(config) do
    case normalize_non_empty_string(Keyword.get(config, :token)) do
      nil -> []
      token -> [{"authorization", "Bearer #{token}"}]
    end
  end

  defp sanitize_req_options(req_options) when is_list(req_options) do
    Enum.reject(req_options, fn
      {key, _value} -> key in @reserved_req_option_keys
      _other -> false
    end)
  end

  defp sanitize_req_options(_req_options), do: []

  defp build_api_url(api_base_url, path_segments) do
    String.trim_trailing(api_base_url, "/") <> "/" <> Enum.join(path_segments, "/")
  end

  defp resolve_api_base_url(config) do
    normalize_non_empty_string(Keyword.get(config, :api_base_url)) ||
      derive_api_base_url(Keyword.get(config, :base_url)) ||
      "https://huggingface.co/api"
  end

  defp derive_api_base_url(base_url) do
    case normalize_non_empty_string(base_url) do
      nil -> nil
      normalized -> String.trim_trailing(normalized, "/") <> "/api"
    end
  end

  defp hf_config do
    Application.get_env(:orchard_controller, :hf, [])
  end

  defp backoff(attempt) do
    delay_ms = min(@initial_backoff_ms * Integer.pow(2, max(attempt - 1, 0)), @max_backoff_ms)
    Process.sleep(delay_ms)
  end

  defp normalize_search_result(%{} = payload) do
    case normalize_repo_id_from_payload(payload) do
      nil -> nil
      repo_id -> normalize_top_level_fields(payload, repo_id)
    end
  end

  defp normalize_search_result(_payload), do: nil

  defp normalize_detail(%{} = payload, requested_repo_id) do
    repo_id = normalize_repo_id_from_payload(payload) || requested_repo_id
    tags = normalize_string_list(Map.get(payload, "tags"))
    config = Map.get(payload, "config")

    normalize_top_level_fields(payload, repo_id)
    |> Map.merge(%{
      revision_sha: normalize_non_empty_string(Map.get(payload, "sha")),
      metadata_summary: normalize_metadata_summary(Map.get(payload, "cardData")),
      config_summary: normalize_config_summary(config, tags, repo_id),
      siblings: normalize_siblings(Map.get(payload, "siblings"))
    })
  end

  defp normalize_top_level_fields(payload, repo_id) do
    %{
      repo_id: repo_id,
      author: normalize_author(payload, repo_id),
      downloads: normalize_non_negative_integer(Map.get(payload, "downloads"), 0),
      likes: normalize_non_negative_integer(Map.get(payload, "likes"), 0),
      tags: normalize_string_list(Map.get(payload, "tags")),
      pipeline_tag: normalize_non_empty_string(Map.get(payload, "pipeline_tag")),
      library_name: normalize_non_empty_string(Map.get(payload, "library_name")),
      used_storage_bytes: normalize_non_negative_integer(Map.get(payload, "usedStorage")),
      last_modified: normalize_non_empty_string(Map.get(payload, "lastModified")),
      gated: normalize_gated(Map.get(payload, "gated"))
    }
  end

  defp normalize_author(payload, repo_id) do
    normalize_non_empty_string(Map.get(payload, "author")) || repo_owner(repo_id)
  end

  defp normalize_repo_id_from_payload(payload) do
    normalize_non_empty_string(Map.get(payload, "id")) ||
      normalize_non_empty_string(Map.get(payload, "modelId"))
  end

  defp repo_owner(repo_id) when is_binary(repo_id) do
    case String.split(repo_id, "/", parts: 2) do
      [owner, _rest] when owner != "" -> owner
      _other -> nil
    end
  end

  defp repo_owner(_repo_id), do: nil

  defp normalize_metadata_summary(%{} = card_data) do
    %{
      license: normalize_non_empty_string(Map.get(card_data, "license")),
      languages: normalize_string_or_list(Map.get(card_data, "language")),
      base_models: normalize_string_or_list(Map.get(card_data, "base_model"))
    }
  end

  defp normalize_metadata_summary(_card_data) do
    %{license: nil, languages: [], base_models: []}
  end

  defp normalize_config_summary(%{} = config, tags, repo_id) do
    %{
      model_type: normalize_non_empty_string(Map.get(config, "model_type")),
      architectures: normalize_string_list(Map.get(config, "architectures")),
      context_window_tokens: normalize_context_window(config),
      quantization_bits: normalize_quantization_bits(config, tags, repo_id)
    }
  end

  defp normalize_config_summary(_config, tags, repo_id) do
    %{
      model_type: nil,
      architectures: [],
      context_window_tokens: nil,
      quantization_bits: infer_quantization_bits(tags, repo_id)
    }
  end

  defp normalize_context_window(config) do
    [
      Map.get(config, "max_position_embeddings"),
      Map.get(config, "n_positions"),
      Map.get(config, "max_sequence_length")
    ]
    |> Enum.find_value(&normalize_positive_integer/1)
  end

  defp normalize_quantization_bits(config, tags, repo_id) do
    case get_in(config, ["quantization", "bits"]) |> normalize_positive_integer() do
      nil -> infer_quantization_bits(tags, repo_id)
      bits -> bits
    end
  end

  defp infer_quantization_bits(tags, repo_id) do
    ([repo_id] ++ tags)
    |> Enum.find_value(fn candidate ->
      value = String.downcase(candidate || "")

      cond do
        String.contains?(value, ["2-bit", "2bit"]) -> 2
        String.contains?(value, ["4-bit", "4bit"]) -> 4
        String.contains?(value, ["8-bit", "8bit"]) -> 8
        true -> nil
      end
    end)
  end

  defp normalize_siblings(siblings) when is_list(siblings) do
    siblings
    |> Enum.map(&normalize_sibling/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.path)
    |> Enum.sort_by(& &1.path)
  end

  defp normalize_siblings(_siblings), do: []

  defp normalize_sibling(%{} = sibling) do
    case normalize_non_empty_string(Map.get(sibling, "rfilename") || Map.get(sibling, "path")) do
      nil ->
        nil

      path ->
        %{path: path, size_bytes: normalize_non_negative_integer(Map.get(sibling, "size"))}
    end
  end

  defp normalize_sibling(_sibling), do: nil

  defp normalize_string_or_list(value) when is_binary(value) do
    case normalize_non_empty_string(value) do
      nil -> []
      normalized -> [normalized]
    end
  end

  defp normalize_string_or_list(value) when is_list(value), do: normalize_string_list(value)
  defp normalize_string_or_list(_value), do: []

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_non_empty_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_values), do: []

  defp normalize_non_empty_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_non_empty_string(_value), do: nil

  defp normalize_gated(nil), do: false
  defp normalize_gated(false), do: false
  defp normalize_gated(_value), do: true

  defp normalize_non_negative_integer(value, default \\ nil)

  defp normalize_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp normalize_non_negative_integer(value, default) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> default
    end
  end

  defp normalize_non_negative_integer(_value, default), do: default

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> nil
    end
  end

  defp normalize_positive_integer(_value), do: nil
end
