defmodule Orchard.ObservabilityProbe do
  @moduledoc """
  Versioned Phase 0 acceptance probe for the streaming Responses API.

  The probe emits one sanitized JSON result. It never includes request input,
  response content, credentials, tenant identifiers, DSNs, or exception detail.
  """

  @schema_version 1
  @config_keys ~w(
    schema_version
    probe_id
    endpoint_kind
    endpoint_url
    stream
    model_env_var
    credential_env_var
    connect_timeout_ms
    request_timeout_ms
    terminal_validation
    cadence_notes
  )
  @result_keys ~w(
    schema_version
    probe_id
    started_at
    finished_at
    outcome
    classification
    public_request_id
    terminal_count
    terminal_state
    http_status
    latency_ms
  )
  @classifications ~w(
    completed
    response_failed
    http_error
    transport_error
    invalid_stream
    terminal_validation_failed
    invalid_config
  )
  @terminal_states ~w(completed failed incomplete cancelled timed_out interrupted)
  @forbidden_result_key_fragments ~w(
    prompt
    response
    credential
    secret
    token
    tenant
    dsn
    stack
    exception
  )
  @probe_input "Reply with exactly: orchard-probe-ok"

  @type validation_error :: {:invalid, String.t()}

  @spec main([String.t()]) :: no_return()
  def main([config_path]) do
    case run(config_path) do
      {:ok, result} ->
        IO.puts(encode_result!(result))
        System.halt(if(result["outcome"] == "pass", do: 0, else: 1))

      {:error, probe_id, reason} ->
        now = timestamp()

        result = %{
          "schema_version" => @schema_version,
          "probe_id" => probe_id,
          "started_at" => now,
          "finished_at" => now,
          "outcome" => "fail",
          "classification" => "invalid_config",
          "public_request_id" => nil,
          "terminal_count" => nil,
          "terminal_state" => nil,
          "http_status" => nil,
          "latency_ms" => 0
        }

        IO.puts(:stderr, "observability probe refused configuration: #{reason}")
        IO.puts(encode_result!(result))
        System.halt(2)
    end
  end

  def main(_args) do
    IO.puts(:stderr, "usage: smoke-observability-probe.sh CONFIG.json")
    System.halt(64)
  end

  @spec validate_config(term()) :: {:ok, map()} | {:error, validation_error()}
  def validate_config(config) when is_map(config) do
    with :ok <- exact_keys(config, @config_keys, "config"),
         :ok <- equals(config, "schema_version", @schema_version),
         :ok <- non_empty_string(config, "probe_id"),
         :ok <- equals(config, "endpoint_kind", "responses"),
         :ok <- responses_url(config["endpoint_url"]),
         :ok <- equals(config, "stream", true),
         :ok <- env_name(config, "model_env_var"),
         :ok <- env_name(config, "credential_env_var"),
         :ok <- positive_integer(config, "connect_timeout_ms"),
         :ok <- positive_integer(config, "request_timeout_ms"),
         :ok <- member(config, "terminal_validation", ~w(http_only controller_local)),
         :ok <- non_empty_string(config, "cadence_notes") do
      {:ok, config}
    else
      {:error, _reason} = error -> error
    end
  end

  def validate_config(_config), do: invalid("config must be a JSON object")

  @spec validate_result(term()) :: {:ok, map()} | {:error, validation_error()}
  def validate_result(result) when is_map(result) do
    with :ok <- reject_forbidden_result_keys(result),
         :ok <- exact_keys(result, @result_keys, "result"),
         :ok <- equals(result, "schema_version", @schema_version),
         :ok <- non_empty_string(result, "probe_id"),
         :ok <- timestamp_field(result, "started_at"),
         :ok <- timestamp_field(result, "finished_at"),
         :ok <- member(result, "outcome", ~w(pass fail)),
         :ok <- member(result, "classification", @classifications),
         :ok <- nullable_string(result, "public_request_id"),
         :ok <- nullable_non_negative_integer(result, "terminal_count"),
         :ok <- nullable_member(result, "terminal_state", @terminal_states),
         :ok <- nullable_http_status(result["http_status"]),
         :ok <- non_negative_integer(result, "latency_ms") do
      {:ok, result}
    else
      {:error, _reason} = error -> error
    end
  end

  def validate_result(_result), do: invalid("result must be a JSON object")

  @spec encode_result!(map()) :: String.t()
  def encode_result!(result) do
    case validate_result(result) do
      {:ok, safe_result} -> Jason.encode!(safe_result)
      {:error, {:invalid, reason}} -> raise ArgumentError, "unsafe probe result: #{reason}"
    end
  end

  @spec classify_http_result(non_neg_integer(), binary()) :: map()
  def classify_http_result(status, body) when status == 200 and is_binary(body) do
    terminals = terminal_events(body)

    case terminals do
      [%{"type" => "response.completed", "response" => response}] ->
        terminal_classification(response, "completed", "pass", 1)

      [%{"type" => "response.failed", "response" => response}] ->
        terminal_classification(response, "response_failed", "fail", 1)

      _events ->
        classification("invalid_stream", "fail", nil, length(terminals), nil)
    end
  end

  def classify_http_result(_status, _body),
    do: classification("http_error", "fail", nil, nil, nil)

  @spec validate_terminal_record(struct(), [struct()]) ::
          {:ok, %{terminal_count: 1, terminal_state: String.t()}}
          | {:error, %{terminal_count: non_neg_integer(), terminal_state: String.t() | nil}}
  def validate_terminal_record(request, events) do
    terminal_events =
      Enum.filter(events, fn event ->
        event.event_type == "state_transition" and to_string(event.state) in @terminal_states
      end)

    terminal_state = request.state && to_string(request.state)

    case terminal_events do
      [event] when event.state == request.state ->
        {:ok, %{terminal_count: 1, terminal_state: terminal_state}}

      _events ->
        {:error, %{terminal_count: length(terminal_events), terminal_state: terminal_state}}
    end
  end

  defp run(config_path) do
    with {:ok, config} <- load_config(config_path),
         {:ok, model} <- required_env(config["model_env_var"]),
         {:ok, credential} <- required_env(config["credential_env_var"]),
         :ok <- maybe_start_repo(config["terminal_validation"]) do
      {:ok, execute(config, model, credential)}
    else
      {:error, {:invalid, reason}} -> {:error, "invalid", reason}
      {:error, _reason} -> {:error, "invalid", "runtime prerequisite unavailable"}
    end
  end

  defp load_config(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, decoded} <- Jason.decode(bytes),
         {:ok, config} <- validate_config(decoded) do
      {:ok, config}
    else
      {:error, %Jason.DecodeError{}} -> invalid("config is not valid JSON")
      {:error, reason} when is_atom(reason) -> invalid("cannot read config: #{reason}")
      {:error, _reason} = error -> error
    end
  end

  defp execute(config, model, credential) do
    started_at = timestamp()
    started_native = System.monotonic_time(:millisecond)

    http_result = request(config, model, credential)
    latency_ms = System.monotonic_time(:millisecond) - started_native

    {http_status, classified} =
      case http_result do
        {:ok, status, body} -> {status, classify_http_result(status, body)}
        {:error, _reason} -> {nil, classification("transport_error", "fail", nil, nil, nil)}
      end

    classified = maybe_validate_terminal(config, classified)

    Map.merge(classified, %{
      "schema_version" => @schema_version,
      "probe_id" => config["probe_id"],
      "started_at" => started_at,
      "finished_at" => timestamp(),
      "http_status" => http_status,
      "latency_ms" => latency_ms
    })
  end

  defp request(config, model, credential) do
    :ok = ensure_http_apps()

    headers = [
      {~c"authorization", String.to_charlist("Bearer #{credential}")},
      {~c"accept", ~c"text/event-stream"}
    ]

    body = Jason.encode!(%{"model" => model, "input" => @probe_input, "stream" => true})
    request = {String.to_charlist(config["endpoint_url"]), headers, ~c"application/json", body}

    http_options = [
      connect_timeout: config["connect_timeout_ms"],
      timeout: config["request_timeout_ms"]
    ]

    case :httpc.request(:post, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        {:ok, status, response_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_http_apps do
    with {:ok, _apps} <- Application.ensure_all_started(:inets),
         {:ok, _apps} <- Application.ensure_all_started(:ssl) do
      :ok
    end
  end

  defp maybe_start_repo("http_only"), do: :ok

  defp maybe_start_repo("controller_local") do
    with {:ok, _apps} <- Application.ensure_all_started(:ecto_sql) do
      case Orchard.Repo.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_validate_terminal(%{"terminal_validation" => "http_only"}, classified),
    do: classified

  defp maybe_validate_terminal(_config, %{"public_request_id" => public_id} = classified)
       when is_binary(public_id) do
    case Orchard.Requests.get_request_by_public_id(public_id) do
      nil ->
        terminal_validation_failure(classified, 0, nil)

      request ->
        case validate_terminal_record(request, Orchard.Requests.list_request_events(request)) do
          {:ok, validation} ->
            classified
            |> Map.put("terminal_count", validation.terminal_count)
            |> Map.put("terminal_state", validation.terminal_state)

          {:error, validation} ->
            terminal_validation_failure(
              classified,
              validation.terminal_count,
              validation.terminal_state
            )
        end
    end
  rescue
    _error -> terminal_validation_failure(classified, 0, nil)
  end

  defp maybe_validate_terminal(_config, classified), do: classified

  defp terminal_validation_failure(classified, count, state) do
    classified
    |> Map.put("outcome", "fail")
    |> Map.put("classification", "terminal_validation_failed")
    |> Map.put("terminal_count", count)
    |> Map.put("terminal_state", state)
  end

  defp terminal_events(body) do
    body
    |> String.split(~r/\r?\n\r?\n/, trim: true)
    |> Enum.flat_map(&decode_terminal_event/1)
  end

  defp decode_terminal_event(block) do
    event_type = sse_field(block, "event")
    data = sse_field(block, "data")

    if event_type in ["response.completed", "response.failed"] and is_binary(data) do
      case Jason.decode(data) do
        {:ok, %{"type" => ^event_type} = event} -> [event]
        _invalid -> []
      end
    else
      []
    end
  end

  defp sse_field(block, field) do
    prefix = field <> ":"

    block
    |> String.split(~r/\r?\n/)
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, prefix) do
        line |> String.replace_prefix(prefix, "") |> String.trim_leading()
      end
    end)
  end

  defp terminal_classification(response, classification_name, outcome, count) do
    classification(
      classification_name,
      outcome,
      response["id"],
      count,
      response["status"]
    )
  end

  defp classification(name, outcome, public_id, terminal_count, terminal_state) do
    %{
      "outcome" => outcome,
      "classification" => name,
      "public_request_id" => public_id,
      "terminal_count" => terminal_count,
      "terminal_state" => terminal_state
    }
  end

  defp required_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _missing -> invalid("required environment variable #{name} is not set")
    end
  end

  defp exact_keys(map, expected, label) do
    actual = map |> Map.keys() |> Enum.sort()

    if actual == Enum.sort(expected) do
      :ok
    else
      invalid("#{label} fields do not match schema version #{@schema_version}")
    end
  end

  defp reject_forbidden_result_keys(result) do
    forbidden =
      Enum.find(Map.keys(result), fn key ->
        normalized = key |> to_string() |> String.downcase()
        Enum.any?(@forbidden_result_key_fragments, &String.contains?(normalized, &1))
      end)

    if forbidden do
      invalid("result contains forbidden field #{forbidden}")
    else
      :ok
    end
  end

  defp equals(map, key, expected) do
    if map[key] == expected, do: :ok, else: invalid("#{key} must equal #{inspect(expected)}")
  end

  defp non_empty_string(map, key) do
    if is_binary(map[key]) and String.trim(map[key]) != "" do
      :ok
    else
      invalid("#{key} must be a non-empty string")
    end
  end

  defp nullable_string(map, key) do
    if is_nil(map[key]) or (is_binary(map[key]) and map[key] != "") do
      :ok
    else
      invalid("#{key} must be null or a non-empty string")
    end
  end

  defp env_name(map, key) do
    if is_binary(map[key]) and Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, map[key]) do
      :ok
    else
      invalid("#{key} must name an uppercase environment variable")
    end
  end

  defp positive_integer(map, key) do
    if is_integer(map[key]) and map[key] > 0 do
      :ok
    else
      invalid("#{key} must be a positive integer")
    end
  end

  defp non_negative_integer(map, key) do
    if is_integer(map[key]) and map[key] >= 0 do
      :ok
    else
      invalid("#{key} must be a non-negative integer")
    end
  end

  defp nullable_non_negative_integer(map, key) do
    if is_nil(map[key]) or (is_integer(map[key]) and map[key] >= 0) do
      :ok
    else
      invalid("#{key} must be null or a non-negative integer")
    end
  end

  defp member(map, key, values) do
    if map[key] in values, do: :ok, else: invalid("#{key} has an unsupported value")
  end

  defp nullable_member(map, key, values) do
    if is_nil(map[key]) or map[key] in values do
      :ok
    else
      invalid("#{key} has an unsupported value")
    end
  end

  defp nullable_http_status(nil), do: :ok

  defp nullable_http_status(status) when is_integer(status) and status >= 100 and status <= 599,
    do: :ok

  defp nullable_http_status(_status), do: invalid("http_status must be null or 100..599")

  defp timestamp_field(map, key) do
    case DateTime.from_iso8601(map[key] || "") do
      {:ok, _datetime, 0} -> :ok
      _invalid -> invalid("#{key} must be an ISO 8601 UTC timestamp")
    end
  end

  defp responses_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and
         uri.path == "/v1/responses" and is_nil(uri.query) and is_nil(uri.fragment) do
      :ok
    else
      invalid("endpoint_url must be an HTTP(S) /v1/responses URL without query or fragment")
    end
  end

  defp responses_url(_url), do: invalid("endpoint_url must be a string")

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  defp invalid(reason), do: {:error, {:invalid, reason}}
end
