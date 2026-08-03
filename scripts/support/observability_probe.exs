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
  @terminal_classifications ~w(completed response_failed)
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
  @probe_id_re ~r/^probe_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
  @public_id_re ~r/^resp_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
  @durable_terminal_states ~w(completed failed cancelled timed_out interrupted)

  @type validation_error :: {:invalid, String.t()}

  @spec main([String.t()]) :: no_return()
  def main([config_path]) do
    case run(config_path) do
      {:ok, result} ->
        IO.puts(encode_result!(result))
        System.halt(if(result["outcome"] == "pass", do: 0, else: 1))

      {:error, probe_id, reason} ->
        now = timestamp()

        safe_probe_id = if match_probe_id?(probe_id), do: probe_id, else: nil

        result = %{
          "schema_version" => @schema_version,
          "probe_id" => safe_probe_id,
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
         :ok <- probe_id_value(config["probe_id"]),
         :ok <- equals(config, "endpoint_kind", "responses"),
         :ok <- responses_url(config["endpoint_url"]),
         :ok <- equals(config, "stream", true),
         :ok <- env_name(config, "model_env_var"),
         :ok <- env_name(config, "credential_env_var"),
         :ok <- distinct_env_vars(config),
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
         :ok <- result_probe_id(result),
         :ok <- timestamp_field(result, "started_at"),
         :ok <- timestamp_field(result, "finished_at"),
         :ok <- member(result, "outcome", ~w(pass fail)),
         :ok <- member(result, "classification", @classifications),
         :ok <- nullable_public_request_id(result["public_request_id"]),
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

  @spec classify_http_result(non_neg_integer(), list(), binary()) :: map()
  def classify_http_result(200, headers, body) when is_list(headers) and is_binary(body) do
    if single_event_stream_content_type?(headers) do
      classify_stream_body(body)
    else
      classification("invalid_stream", "fail", nil, nil, nil)
    end
  end

  def classify_http_result(_status, _headers, _body),
    do: classification("http_error", "fail", nil, nil, nil)

  defp classify_stream_body(body) do
    case parse_terminals(body) do
      {:ok, [%{"type" => "response.completed", "response" => response}]} ->
        terminal_classification(response, "completed", "pass", 1)

      {:ok, [%{"type" => "response.failed", "response" => response}]} ->
        terminal_classification(response, "response_failed", "fail", 1)

      {:ok, terminals} ->
        classification("invalid_stream", "fail", nil, length(terminals), nil)

      {:error, terminal_count} ->
        classification("invalid_stream", "fail", nil, terminal_count, nil)
    end
  end

  @spec validate_terminal_record(struct(), [struct()]) ::
          {:ok, %{terminal_count: 1, terminal_state: String.t()}}
          | {:error, %{terminal_count: non_neg_integer(), terminal_state: String.t() | nil}}
  def validate_terminal_record(request, events) do
    terminal_events =
      Enum.filter(events, fn event ->
        event.event_type == "state_transition" and
          to_string(event.state) in @durable_terminal_states
      end)

    terminal_state = request.state && to_string(request.state)

    case terminal_events do
      [event] when event.state == request.state ->
        {:ok, %{terminal_count: 1, terminal_state: terminal_state}}

      _events ->
        {:error, %{terminal_count: length(terminal_events), terminal_state: terminal_state}}
    end
  end

  @spec reconcile_terminal_result(map(), struct() | map(), [struct() | map()]) :: map()
  def reconcile_terminal_result(classified, request, events) do
    public_id = classified["public_request_id"]

    if match_public_id?(public_id) do
      reconcile_terminal_record(classified, validate_terminal_record(request, events))
    else
      terminal_validation_failure(classified, 0, nil)
    end
  end

  defp reconcile_terminal_record(classified, {:ok, validation}) do
    if sse_and_durable_agree?(
         classified["classification"],
         classified["terminal_state"],
         validation.terminal_state
       ) do
      classified
      |> Map.put("terminal_count", validation.terminal_count)
      |> Map.put("terminal_state", validation.terminal_state)
    else
      terminal_validation_failure(
        classified,
        validation.terminal_count,
        validation.terminal_state
      )
    end
  end

  defp reconcile_terminal_record(classified, {:error, validation}) do
    terminal_validation_failure(classified, validation.terminal_count, validation.terminal_state)
  end

  @spec validate_resolved_values(term(), term()) :: :ok | {:error, validation_error()}
  def validate_resolved_values(model, credential) do
    with :ok <- valid_model_value(model),
         :ok <- valid_credential_value(credential) do
      :ok
    end
  end

  @spec build_http_options(map()) :: {:ok, keyword()} | {:error, validation_error()}
  def build_http_options(config), do: build_http_options(config, &:public_key.cacerts_get/0)

  @spec build_http_options(map(), (-> list())) :: {:ok, keyword()} | {:error, validation_error()}
  def build_http_options(config, load_cacerts) do
    uri = URI.parse(config["endpoint_url"])

    options = [
      connect_timeout: config["connect_timeout_ms"],
      timeout: config["request_timeout_ms"],
      autoredirect: false
    ]

    if uri.scheme == "https" do
      with {:ok, cacerts} <- host_cacerts(load_cacerts) do
        ssl_options = [
          verify: :verify_peer,
          cacerts: cacerts,
          server_name_indication: String.to_charlist(uri.host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]

        {:ok, Keyword.put(options, :ssl, ssl_options)}
      end
    else
      {:ok, options}
    end
  end

  defp host_cacerts(load_cacerts) do
    case load_cacerts.() do
      [_certificate | _rest] = cacerts -> {:ok, cacerts}
      _empty_or_invalid -> invalid("host system CA store is unavailable")
    end
  catch
    :error, _reason -> invalid("host system CA store is unavailable")
  end

  defp run(config_path) do
    case load_config(config_path) do
      {:ok, config} -> run_validated_config(config)
      {:error, {:invalid, reason}} -> {:error, nil, reason}
    end
  end

  defp run_validated_config(config) do
    probe_id = config["probe_id"]

    with {:ok, model} <- required_env(config["model_env_var"]),
         {:ok, credential} <- required_env(config["credential_env_var"]),
         :ok <- validate_resolved_values(model, credential),
         :ok <- ensure_http_apps(),
         {:ok, http_options} <- build_http_options(config),
         :ok <- start_terminal_validation_repo(config["terminal_validation"]) do
      {:ok, execute(config, model, credential, http_options)}
    else
      {:error, {:invalid, reason}} -> {:error, probe_id, reason}
      {:error, _reason} -> {:error, probe_id, "runtime prerequisite unavailable"}
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

  defp execute(config, model, credential, http_options) do
    started_at = timestamp()
    started_native = System.monotonic_time(:millisecond)

    http_result = request(config, model, credential, http_options)
    latency_ms = System.monotonic_time(:millisecond) - started_native

    {http_status, classified} =
      case http_result do
        {:ok, status, headers, body} ->
          {schema_http_status(status), classify_http_result(status, headers, body)}

        {:error, _reason} ->
          {nil, classification("transport_error", "fail", nil, nil, nil)}
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

  defp request(config, model, credential, http_options) do
    headers = [
      {~c"authorization", String.to_charlist("Bearer #{credential}")},
      {~c"accept", ~c"text/event-stream"}
    ]

    body = Jason.encode!(%{"model" => model, "input" => @probe_input, "stream" => true})
    request = {String.to_charlist(config["endpoint_url"]), headers, ~c"application/json", body}

    case :httpc.request(:post, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok, status, response_headers, response_body}

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

  @spec start_terminal_validation_repo(String.t(), (keyword() -> term())) ::
          :ok | {:error, term()}
  def start_terminal_validation_repo(terminal_validation, start_repo \\ &Orchard.Repo.start_link/1)

  def start_terminal_validation_repo("http_only", _start_repo), do: :ok

  def start_terminal_validation_repo("controller_local", start_repo) do
    with {:ok, _apps} <- Application.ensure_all_started(:ecto_sql) do
      # Stdout carries the probe result JSON, so Repo query logs would corrupt it
      # and echo bound identifiers such as tenant IDs.
      case start_repo.(log: false) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_validate_terminal(%{"terminal_validation" => "http_only"}, classified),
    do: classified

  defp maybe_validate_terminal(%{"terminal_validation" => "controller_local"}, classified) do
    public_id = classified["public_request_id"]

    validate_controller_local_result(
      classified,
      fn -> Orchard.Requests.get_request_by_public_id(public_id) end,
      &Orchard.Requests.list_request_events/1
    )
  end

  defp maybe_validate_terminal(_config, classified), do: classified

  @spec validate_controller_local_result(
          map(),
          (-> struct() | map() | nil),
          (struct() | map() -> list())
        ) :: map()
  def validate_controller_local_result(classified, lookup, list_events) do
    cond do
      not observed_terminal?(classified["classification"]) ->
        classified

      not match_public_id?(classified["public_request_id"]) ->
        terminal_validation_failure(classified, 0, nil)

      true ->
        reconcile_durable_terminal(classified, lookup, list_events)
    end
  end

  defp observed_terminal?(classification), do: classification in @terminal_classifications

  defp reconcile_durable_terminal(classified, lookup, list_events) do
    case lookup.() do
      nil -> terminal_validation_failure(classified, 0, nil)
      request -> reconcile_terminal_result(classified, request, list_events.(request))
    end
  rescue
    _error in [
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Ecto.QueryError,
      Postgrex.Error
    ] ->
      terminal_validation_failure(classified, 0, nil)
  catch
    :exit, _reason -> terminal_validation_failure(classified, 0, nil)
  end

  defp sse_and_durable_agree?("completed", "completed", "completed"), do: true

  defp sse_and_durable_agree?("response_failed", "failed", durable_state),
    do: durable_state in ~w(failed cancelled timed_out interrupted)

  defp sse_and_durable_agree?("response_failed", "incomplete", durable_state),
    do: durable_state in ~w(cancelled timed_out interrupted)

  defp sse_and_durable_agree?(_classification, _http_state, _durable_state), do: false

  defp terminal_validation_failure(classified, count, state) do
    safe_state = if is_binary(state) and state in @terminal_states, do: state, else: nil

    classified
    |> Map.put("outcome", "fail")
    |> Map.put("classification", "terminal_validation_failed")
    |> Map.put("terminal_count", count)
    |> Map.put("terminal_state", safe_state)
  end

  defp parse_terminals(body) do
    if String.valid?(body) do
      body
      |> String.split(~r/\r?\n\r?\n/, trim: true)
      |> Enum.reduce({[], 0, false}, &collect_terminal/2)
      |> finish_terminal_parse()
    else
      {:error, nil}
    end
  end

  defp collect_terminal(block, {events, count, invalid?}) do
    case decode_terminal_event(block) do
      {:ok, :ignore} -> {events, count, invalid?}
      {:ok, event} -> {[event | events], count + 1, invalid?}
      {:error, :invalid_stream} -> {events, count + 1, true}
    end
  end

  defp finish_terminal_parse({_events, count, true}), do: {:error, count}
  defp finish_terminal_parse({events, _count, false}), do: {:ok, Enum.reverse(events)}

  defp decode_terminal_event(block) do
    event_types = sse_fields(block, "event")
    data_fields = sse_fields(block, "data")
    decoded = decode_single_data(data_fields)
    decoded_type = decoded_type(decoded)

    if terminal_candidate?(event_types, decoded_type, data_fields) do
      validate_terminal_candidate(event_types, data_fields, decoded)
    else
      {:ok, :ignore}
    end
  end

  defp decode_single_data([data]), do: Jason.decode(data)
  defp decode_single_data(_data_fields), do: {:error, :invalid_data_fields}

  defp decoded_type({:ok, %{"type" => type}}) when is_binary(type), do: type
  defp decoded_type(_decoded), do: nil

  defp terminal_candidate?(event_types, decoded_type, data_fields) do
    Enum.any?(event_types, &terminal_event?/1) or terminal_event?(decoded_type) or
      Enum.any?(data_fields, &terminal_json?/1)
  end

  defp terminal_json?(data) do
    case Jason.decode(data) do
      {:ok, %{"type" => type}} -> terminal_event?(type)
      _invalid -> false
    end
  end

  defp terminal_event?(type), do: type in ["response.completed", "response.failed"]

  defp validate_terminal_candidate([event_type], [_data], {:ok, event}) when is_map(event) do
    with ^event_type <- event["type"],
         response when is_map(response) <- event["response"],
         true <- match_public_id?(response["id"]),
         true <- valid_terminal_status?(event_type, response["status"]) do
      {:ok, event}
    else
      _invalid -> {:error, :invalid_stream}
    end
  end

  defp validate_terminal_candidate(_event_types, _data_fields, _decoded),
    do: {:error, :invalid_stream}

  defp valid_terminal_status?("response.completed", "completed"), do: true
  defp valid_terminal_status?("response.failed", status), do: status in ["failed", "incomplete"]
  defp valid_terminal_status?(_event_type, _status), do: false

  defp sse_fields(block, field) do
    prefix = field <> ":"

    block
    |> String.split(~r/\r?\n/)
    |> Enum.flat_map(fn line ->
      cond do
        line == field ->
          [""]

        String.starts_with?(line, prefix) ->
          [line |> String.replace_prefix(prefix, "") |> String.trim_leading()]

        true ->
          []
      end
    end)
  end

  defp terminal_classification(response, classification_name, outcome, count)
       when is_map(response) do
    id = response["id"]
    status = response["status"]

    if match_public_id?(id) and is_binary(status) and status != "" do
      classification(classification_name, outcome, id, count, status)
    else
      classification("invalid_stream", "fail", nil, nil, nil)
    end
  end

  defp terminal_classification(_response, _classification_name, _outcome, _count) do
    classification("invalid_stream", "fail", nil, nil, nil)
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

  defp single_event_stream_content_type?(headers) do
    values =
      Enum.flat_map(headers, fn
        {name, value} ->
          if normalized_header(name) == "content-type", do: [normalized_header(value)], else: []

        _invalid_header ->
          []
      end)

    case values do
      [value] when is_binary(value) -> valid_event_stream_content_type?(value)
      _missing_or_ambiguous -> false
    end
  end

  defp normalized_header(value) when is_binary(value), do: value |> String.downcase()

  defp normalized_header(value) when is_list(value) do
    if List.ascii_printable?(value), do: value |> List.to_string() |> String.downcase()
  end

  defp normalized_header(_value), do: nil

  defp valid_event_stream_content_type?(value) do
    String.valid?(value) and not String.contains?(value, ",") and
      not contains_control_character?(value) and
      value
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> Kernel.==("text/event-stream")
  end

  defp schema_http_status(status) when is_integer(status) and status in 100..599, do: status
  defp schema_http_status(_status), do: nil

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
    with value when is_binary(value) <- map[key],
         {:ok, _datetime, 0} <- DateTime.from_iso8601(value) do
      :ok
    else
      _invalid -> invalid("#{key} must be an ISO 8601 UTC timestamp")
    end
  end

  defp responses_url(url) when is_binary(url) do
    with :ok <- raw_authority(url),
         {:ok, uri} <- parse_uri(url) do
      validate_responses_uri(uri)
    end
  end

  defp responses_url(_url), do: invalid("endpoint_url must be a string")

  defp raw_authority(url) do
    case Regex.run(~r/\Ahttps?:\/\/([^\/?#]*)/, url, capture: :all_but_first) do
      [authority] -> validate_raw_authority(authority)
      _invalid -> invalid("endpoint_url must have a valid HTTP(S) authority")
    end
  end

  defp validate_raw_authority(authority) do
    cond do
      String.contains?(authority, "@") ->
        invalid("endpoint_url must not include userinfo")

      authority == "" or Regex.match?(~r/[\x00-\x20\x7f]/, authority) ->
        invalid("endpoint_url authority is invalid")

      String.starts_with?(authority, "[") ->
        validate_bracketed_authority(authority)

      String.contains?(authority, ["[", "]"]) ->
        invalid("endpoint_url IPv6 authority is invalid")

      true ->
        validate_host_port(authority)
    end
  end

  defp validate_bracketed_authority(authority) do
    case Regex.run(~r/^\[([^\]]+)\](?::(.+))?$/, authority, capture: :all_but_first) do
      [host] -> validate_ipv6_host(host)
      [host, port] -> with :ok <- validate_ipv6_host(host), do: validate_raw_port(port)
      _invalid -> invalid("endpoint_url IPv6 authority is invalid")
    end
  end

  defp validate_ipv6_host(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} when tuple_size(address) == 8 -> :ok
      _invalid -> invalid("endpoint_url IPv6 authority is invalid")
    end
  end

  defp validate_host_port(authority) do
    case String.split(authority, ":", parts: 3) do
      [host] when host != "" -> :ok
      [host, port] when host != "" -> validate_raw_port(port)
      _invalid -> invalid("endpoint_url authority is invalid")
    end
  end

  defp validate_raw_port(port) do
    if Regex.match?(~r/^\d+$/, port) do
      case Integer.parse(port) do
        {number, ""} when number in 1..65_535 -> :ok
        _invalid -> invalid("endpoint_url port must be between 1 and 65535")
      end
    else
      invalid("endpoint_url port must be numeric")
    end
  end

  defp parse_uri(url) do
    {:ok, URI.parse(url)}
  rescue
    _error in ArgumentError -> invalid("endpoint_url authority is invalid")
  end

  defp validate_responses_uri(uri) do
    cond do
      not is_nil(uri.userinfo) ->
        invalid("endpoint_url must not include userinfo")

      uri.path != "/v1/responses" or not is_nil(uri.query) or not is_nil(uri.fragment) ->
        invalid("endpoint_url must be an HTTP(S) /v1/responses URL without query or fragment")

      uri.scheme == "https" and is_binary(uri.host) and uri.host != "" ->
        :ok

      uri.scheme == "http" and loopback_host?(uri.host) ->
        :ok

      uri.scheme == "http" ->
        invalid("endpoint_url must use HTTPS except for loopback")

      true ->
        invalid("endpoint_url must be an HTTP(S) /v1/responses URL without query or fragment")
    end
  end

  defp loopback_host?(host) when host in ["127.0.0.1", "localhost", "::1"], do: true
  defp loopback_host?(_host), do: false

  defp probe_id_value(value) do
    if match_probe_id?(value), do: :ok, else: invalid("probe_id must match probe_<uuid>")
  end

  defp result_probe_id(%{"classification" => "invalid_config", "probe_id" => nil}), do: :ok
  defp result_probe_id(result), do: probe_id_value(result["probe_id"])

  defp match_probe_id?(value) when is_binary(value), do: Regex.match?(@probe_id_re, value)
  defp match_probe_id?(_value), do: false

  defp match_public_id?(value) when is_binary(value), do: Regex.match?(@public_id_re, value)
  defp match_public_id?(_value), do: false

  defp nullable_public_request_id(nil), do: :ok

  defp nullable_public_request_id(value) do
    if match_public_id?(value), do: :ok, else: invalid("public_request_id must match resp_<uuid>")
  end

  defp valid_model_value(model) do
    if is_binary(model) and String.valid?(model) and byte_size(model) in 1..512 and
         not contains_control_character?(model) do
      :ok
    else
      invalid("resolved model value is invalid")
    end
  end

  defp valid_credential_value(credential) do
    if is_binary(credential) and byte_size(credential) in 1..4096 and
         credential
         |> :binary.bin_to_list()
         |> Enum.all?(&(&1 in 33..126)) do
      :ok
    else
      invalid("resolved credential value is invalid")
    end
  end

  defp contains_control_character?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.any?(&(&1 < 32 or &1 == 127))
  end

  defp distinct_env_vars(config) do
    if config["model_env_var"] == config["credential_env_var"] do
      invalid("model_env_var and credential_env_var must differ")
    else
      :ok
    end
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  defp invalid(reason), do: {:error, {:invalid, reason}}
end
