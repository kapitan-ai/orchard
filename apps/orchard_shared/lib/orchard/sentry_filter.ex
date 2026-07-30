defmodule Orchard.SentryFilter do
  @moduledoc """
  Shared Sentry event scrubber for Orchard.

  Operates on generic maps and structs so orchard_shared does not need a Sentry compile dependency.

  Two scrubbing paths exist. Structurally detected `Sentry.Event` structs are rebuilt from an
  empty struct, so only allowlisted fields reach the envelope and every retained diagnostic must
  pass a validator chosen by its key; a newly allowlisted key without a validator stays filtered.
  Every other map or struct keeps the recursive denylist scrub, which Orchard also uses for local
  CLI status snapshots. Both paths fail closed: a raised or thrown scrubbing failure reduces the
  payload to validated identity plus fixed markers rather than passing the original through.
  """

  @filtered "[Filtered]"
  @redacted "[redacted]"

  @allowed_http_methods MapSet.new(~w(CONNECT DELETE GET HEAD OPTIONS PATCH POST PUT TRACE))
  @safe_frame_keys MapSet.new(~w(module function filename lineno colno in_app))
  @first_party_app_source_roots [
    orchard_controller: "apps/orchard_controller/lib/",
    orchard_node_agent: "apps/orchard_node_agent/lib/",
    orchard_shared: "apps/orchard_shared/lib/",
    orchard_cli: "apps/orchard_cli/lib/"
  ]
  @first_party_source_roots Keyword.values(@first_party_app_source_roots)
  @app_relative_source_root "lib/"

  @safe_event_tag_keys ~w(
    orchard_app orchard_version orchard_build_channel build_sha build_date
    orchard_surface orchard_endpoint stream tooling scheduler_strategy
    failure_category terminal_source orchard_license_state
    orchard_tracking_program orchard_tracking_reference worker_backend
  )

  @safe_event_extra_keys ~w(
    request_id worker_model model_backend orchard_tenant_hash
    orchard_principal_type orchard_principal_hash orchard_api_key_hash
    orchard_request_id orchard_db_request_id orchard_endpoint orchard_stream
    orchard_tooling orchard_model_id orchard_model_version orchard_node_hash
    orchard_scheduler_strategy orchard_target_host_sanitized
    orchard_model_already_loaded orchard_ensure_model_loaded_ms
    orchard_accepted_to_first_delta_ms orchard_accepted_to_terminal_ms
    orchard_event_count orchard_anomaly orchard_model_backend
    orchard_license_state orchard_license_id orchard_machine_id_hash
    orchard_max_machines orchard_expires_at orchard_tracking_program
    orchard_tracking_reference orchard_build_channel orchard_build_ref
    sentry_filter_failed
  )

  @safe_breadcrumb_data_keys ~w(
    auth_mechanism reason endpoint stream tooling model_id model_version
    orchard_request_id scheduler_strategy node_hash target_host_sanitized
    already_loaded ensure_model_loaded_ms accepted_to_first_delta_ms
    terminal_source duration_ms backend adapter outcome source_scheme preload
    worker_started waiter_count replied_waiter_count incoming_model_id
    incoming_version victim_model_id victim_version max_loaded_models
    reserved_model_count_before cancel_reason rpc_result stop_result skip_rpc
  )

  @sensitive_keys MapSet.new([
                    "messages",
                    "content",
                    "prompt",
                    "input",
                    "rendered_prompt",
                    "metadata",
                    "abs_path",
                    "certificate",
                    "filename",
                    "fingerprint",
                    "key",
                    "source_url",
                    "url",
                    "raw_url",
                    "request_url",
                    "query_string",
                    "path",
                    "node_id",
                    "orchard_node_id",
                    "machine_id",
                    "orchard_machine_id",
                    "local_node_fingerprint",
                    "node_fingerprint",
                    "token",
                    "token_prefix",
                    "access_token",
                    "refresh_token",
                    "api_key",
                    "api_key_hash",
                    "api_key_prefix",
                    "apikey",
                    "key_prefix",
                    "x_api_key",
                    "api_key_id",
                    "tenant_id",
                    "principal_id",
                    "secret",
                    "client_secret",
                    "secret_access_key",
                    "secret_hash",
                    "password",
                    "authorization",
                    "authorization_header",
                    "bearer",
                    "cookie",
                    "cookies",
                    "email",
                    "ip_address",
                    "licensee",
                    "license_certificate",
                    "machine_certificate",
                    "activation_key",
                    "license_key",
                    "keygen_admin_token",
                    "orchard_keygen_admin_token",
                    "keygen_public_key",
                    "keygen_private_key",
                    "private_key",
                    "certificate_pem",
                    "private_key_pem",
                    "key_pem",
                    "signing_key",
                    "public_key",
                    "certfile",
                    "keyfile",
                    "bundle_path",
                    "node_identity_path",
                    "models_root",
                    "worker_log_dir",
                    "artifact_uri"
                  ])

  @safe_token_keys MapSet.new([
                     "input_tokens",
                     "output_tokens",
                     "total_tokens",
                     "prompt_tokens",
                     "completion_tokens",
                     "max_tokens",
                     "token_usage"
                   ])

  @safe_correlation_hash_keys MapSet.new([
                                "orchard_api_key_hash",
                                "orchard_tenant_hash",
                                "orchard_principal_hash",
                                "orchard_node_hash",
                                "orchard_machine_id_hash",
                                "node_hash"
                              ])

  @redacted_diagnostic_keys MapSet.new(~w(orchard_target_host_sanitized target_host_sanitized))
  @boolean_diagnostic_keys MapSet.new(~w(
                               stream tooling orchard_stream orchard_tooling
                               orchard_model_already_loaded already_loaded preload worker_started
                               skip_rpc sentry_filter_failed
                             ))
  @integer_diagnostic_keys MapSet.new(~w(
                               orchard_event_count orchard_max_machines waiter_count
                               replied_waiter_count max_loaded_models reserved_model_count_before
                             ))
  @number_diagnostic_keys MapSet.new(~w(
                              orchard_ensure_model_loaded_ms orchard_accepted_to_first_delta_ms
                              orchard_accepted_to_terminal_ms ensure_model_loaded_ms
                              accepted_to_first_delta_ms duration_ms
                            ))
  @namespaced_identifier_keys MapSet.new(
                                ~w(worker_model orchard_model_id model_id incoming_model_id victim_model_id)
                              )
  @identifier_diagnostic_keys MapSet.new(~w(
                                  orchard_app orchard_version orchard_build_channel orchard_surface
                                  orchard_endpoint scheduler_strategy failure_category terminal_source
                                  orchard_license_state orchard_tracking_program
                                  orchard_tracking_reference worker_backend request_id model_backend
                                  orchard_principal_type orchard_request_id orchard_db_request_id
                                  orchard_model_version orchard_scheduler_strategy orchard_anomaly
                                  orchard_model_backend orchard_license_id orchard_build_ref
                                  auth_mechanism reason endpoint model_version terminal_source backend
                                  adapter outcome source_scheme incoming_version victim_version
                                  cancel_reason rpc_result stop_result
                                ))
  @diagnostic_key_groups [
    {@safe_correlation_hash_keys, :correlation_hash},
    {@redacted_diagnostic_keys, :redacted},
    {@boolean_diagnostic_keys, :boolean},
    {@integer_diagnostic_keys, :integer},
    {@number_diagnostic_keys, :number},
    {@namespaced_identifier_keys, :namespaced_identifier},
    {@identifier_diagnostic_keys, :identifier}
  ]

  @spec filter(map() | struct()) :: map() | struct()
  def filter(event) when is_map(event) do
    if sentry_event?(event), do: scrub_sentry_event(event), else: scrub_nested(event)
  rescue
    _exception -> fail_closed(event)
  catch
    _kind, _reason -> fail_closed(event)
  end

  def filter(other), do: other

  @spec request_context(term()) :: %{optional(:method) => String.t()}
  def request_context(method) do
    case normalize_http_method(method) do
      nil -> %{}
      safe_method -> %{method: safe_method}
    end
  end

  defp sentry_event?(%{__struct__: module}) when is_atom(module) do
    Module.split(module) == ["Sentry", "Event"]
  rescue
    _exception -> false
  end

  defp sentry_event?(_event), do: false

  defp scrub_sentry_event(%{__struct__: module} = event) do
    event_map = Map.from_struct(event)

    module
    |> struct()
    |> Map.from_struct()
    |> Map.merge(%{
      event_id: safe_event_id(Map.get(event_map, :event_id)),
      timestamp: safe_timestamp(Map.get(event_map, :timestamp)),
      level: safe_event_level(Map.get(event_map, :level)),
      platform: :elixir,
      release: safe_release(Map.get(event_map, :release)),
      environment: safe_identifier(Map.get(event_map, :environment)),
      sdk: nil,
      source: Map.get(event_map, :source),
      original_exception: Map.get(event_map, :original_exception),
      breadcrumbs: scrub_event_breadcrumbs(Map.get(event_map, :breadcrumbs)),
      contexts: %{},
      exception: scrub_event_exceptions(Map.get(event_map, :exception)),
      extra: scrub_allowlisted_map(Map.get(event_map, :extra), @safe_event_extra_keys),
      fingerprint: [],
      message: scrub_event_message(Map.get(event_map, :message)),
      modules: %{},
      request: scrub_event_request(Map.get(event_map, :request)),
      server_name: @redacted,
      tags: scrub_allowlisted_map(Map.get(event_map, :tags), @safe_event_tag_keys),
      threads: nil,
      user: %{}
    })
    |> then(&struct(module, &1))
  end

  defp scrub_event_message(nil), do: nil

  defp scrub_event_message(%{__struct__: module}) when is_atom(module) do
    base = struct(module)

    if Map.has_key?(base, :formatted) do
      struct(module, formatted: @filtered)
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp scrub_event_message(_message), do: nil

  defp scrub_event_exceptions(exceptions) when is_list(exceptions) do
    Enum.flat_map(exceptions, fn exception ->
      case scrub_event_exception(exception) do
        nil -> []
        safe_exception -> [safe_exception]
      end
    end)
  end

  defp scrub_event_exceptions(_exceptions), do: []

  defp scrub_event_exception(%{__struct__: module} = exception) when is_atom(module) do
    exception_map = Map.from_struct(exception)
    base = struct(module)

    base
    |> Map.from_struct()
    |> maybe_put_if_present(base, :type, safe_diagnostic_name(Map.get(exception_map, :type)))
    |> maybe_put_if_present(base, :value, @filtered)
    |> maybe_put_if_present(base, :module, safe_diagnostic_name(Map.get(exception_map, :module)))
    |> maybe_put_if_present(
      base,
      :stacktrace,
      scrub_stacktrace(Map.get(exception_map, :stacktrace))
    )
    |> maybe_put_if_present(base, :mechanism, nil)
    |> then(&struct(module, &1))
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp scrub_event_exception(_exception), do: nil

  defp scrub_stacktrace(%{__struct__: module} = stacktrace) when is_atom(module) do
    base = struct(module)

    if Map.has_key?(base, :frames) do
      struct(module, frames: scrub_interface_frames(Map.get(stacktrace, :frames)))
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp scrub_stacktrace(stacktrace) when is_map(stacktrace) do
    cond do
      Map.has_key?(stacktrace, :frames) ->
        %{frames: scrub_frames(Map.get(stacktrace, :frames))}

      Map.has_key?(stacktrace, "frames") ->
        %{"frames" => scrub_frames(Map.get(stacktrace, "frames"))}

      true ->
        nil
    end
  end

  defp scrub_stacktrace(_stacktrace), do: nil

  defp scrub_event_breadcrumbs(breadcrumbs) when is_list(breadcrumbs) do
    Enum.flat_map(breadcrumbs, fn breadcrumb ->
      case scrub_event_breadcrumb(breadcrumb) do
        nil -> []
        safe_breadcrumb -> [safe_breadcrumb]
      end
    end)
  end

  defp scrub_event_breadcrumbs(_breadcrumbs), do: []

  defp scrub_event_breadcrumb(%{__struct__: module} = breadcrumb) when is_atom(module) do
    breadcrumb_map = Map.from_struct(breadcrumb)
    category = safe_breadcrumb_category(Map.get(breadcrumb_map, :category))
    message = safe_breadcrumb_message(Map.get(breadcrumb_map, :message))

    if category && message do
      base = struct(module)

      base
      |> Map.from_struct()
      |> maybe_put_if_present(base, :category, category)
      |> maybe_put_if_present(base, :message, message)
      |> maybe_put_if_present(
        base,
        :level,
        safe_breadcrumb_level(Map.get(breadcrumb_map, :level))
      )
      |> maybe_put_if_present(
        base,
        :data,
        scrub_allowlisted_map(Map.get(breadcrumb_map, :data), @safe_breadcrumb_data_keys)
      )
      |> maybe_put_if_present(
        base,
        :timestamp,
        safe_timestamp(Map.get(breadcrumb_map, :timestamp))
      )
      |> then(&struct(module, &1))
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp scrub_event_breadcrumb(_breadcrumb), do: nil

  defp scrub_allowlisted_map(value, allowed_keys) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, acc ->
      normalized_key = normalize_key(key)

      if normalized_key in allowed_keys do
        Map.put(acc, key, safe_diagnostic_value(normalized_key, nested_value))
      else
        acc
      end
    end)
  end

  defp scrub_allowlisted_map(_value, _allowed_keys), do: %{}

  defp safe_diagnostic_value(key, value) do
    key
    |> diagnostic_value_type()
    |> scrub_diagnostic_value(value)
  end

  defp diagnostic_value_type("build_date"), do: :date
  defp diagnostic_value_type("orchard_expires_at"), do: :timestamp
  defp diagnostic_value_type("build_sha"), do: :sha

  defp diagnostic_value_type(key) do
    Enum.find_value(@diagnostic_key_groups, :unknown, fn {keys, type} ->
      if MapSet.member?(keys, key), do: type
    end)
  end

  defp scrub_diagnostic_value(:correlation_hash, value), do: scrub_correlation_hash(value)
  defp scrub_diagnostic_value(:redacted, value), do: safe_redacted_value(value)
  defp scrub_diagnostic_value(:boolean, value), do: safe_boolean(value)
  defp scrub_diagnostic_value(:integer, value), do: safe_non_negative_integer(value)
  defp scrub_diagnostic_value(:number, value), do: safe_non_negative_number(value)
  defp scrub_diagnostic_value(:date, value), do: safe_date(value)
  defp scrub_diagnostic_value(:timestamp, value), do: safe_timestamp(value)
  defp scrub_diagnostic_value(:sha, value), do: safe_sha(value)

  defp scrub_diagnostic_value(:namespaced_identifier, value),
    do: safe_namespaced_identifier(value)

  defp scrub_diagnostic_value(:identifier, value), do: safe_identifier(value)
  defp scrub_diagnostic_value(:unknown, _value), do: @filtered

  defp safe_redacted_value(@redacted), do: @redacted
  defp safe_redacted_value(_value), do: @filtered

  defp safe_boolean(value) when is_boolean(value), do: value
  defp safe_boolean(value) when value in ["true", "false"], do: value
  defp safe_boolean(_value), do: @filtered

  defp safe_non_negative_integer(value)
       when is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991,
       do: value

  defp safe_non_negative_integer(_value), do: @filtered

  defp safe_non_negative_number(value)
       when is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991,
       do: value

  defp safe_non_negative_number(value)
       when is_float(value) and value >= 0.0 and value <= 1.0e15,
       do: value

  defp safe_non_negative_number(_value), do: @filtered

  defp safe_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> value
      {:error, _reason} -> @filtered
    end
  end

  defp safe_date(_value), do: @filtered

  defp safe_sha(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{7,40}\z/, value), do: value, else: @filtered
  end

  defp safe_sha(_value), do: @filtered

  defp safe_identifier(value) when is_atom(value),
    do: value |> Atom.to_string() |> safe_identifier()

  defp safe_identifier(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= 160 and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.+-]{0,159}\z/, value) and
         not ip_address?(value) do
      value
    else
      @filtered
    end
  end

  defp safe_identifier(_value), do: @filtered

  defp safe_namespaced_identifier(value) when is_atom(value),
    do: value |> Atom.to_string() |> safe_namespaced_identifier()

  defp safe_namespaced_identifier(value) when is_binary(value) do
    segments = String.split(value, "/", trim: false)

    if String.valid?(value) and byte_size(value) <= 160 and length(segments) <= 4 and
         not path_like_identifier?(value, segments) and
         Enum.all?(segments, &Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.+-]{0,95}\z/, &1)) do
      value
    else
      @filtered
    end
  end

  defp safe_namespaced_identifier(_value), do: @filtered

  defp path_like_identifier?(value, segments) do
    String.starts_with?(value, ["/", "~", "./", "../"]) or
      String.contains?(value, ["\\", "://"]) or
      List.first(segments) in [
        "Users",
        "Library",
        "Applications",
        "Volumes",
        "private",
        "tmp",
        "var",
        "etc",
        "home",
        "apps",
        "deps",
        "_build"
      ]
  end

  defp ip_address?(value) do
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(value)))
  rescue
    _exception -> false
  end

  defp safe_release(value) when is_binary(value) do
    if Regex.match?(
         ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}@[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\+(?:[0-9a-f]{7}|unknown)\z/,
         value
       ) do
      value
    else
      @filtered
    end
  end

  defp safe_release(_value), do: @filtered

  defp safe_diagnostic_name(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= 200 and
         Regex.match?(~r/\A[A-Za-z0-9_.:!?-]+\z/, value) do
      value
    else
      @filtered
    end
  end

  defp safe_diagnostic_name(nil), do: nil

  defp safe_diagnostic_name(value) when is_atom(value),
    do: value |> Atom.to_string() |> safe_diagnostic_name()

  defp safe_diagnostic_name(_value), do: @filtered

  defp safe_breadcrumb_category(value) when is_binary(value) do
    if byte_size(value) <= 96 and Regex.match?(~r/\Aorchard\.[a-z0-9_.-]+\z/, value), do: value
  end

  defp safe_breadcrumb_category(_value), do: nil

  defp safe_breadcrumb_message(value) when is_binary(value) do
    if byte_size(value) <= 96 and Regex.match?(~r/\A[a-z0-9_.-]+\z/, value), do: value
  end

  defp safe_breadcrumb_message(_value), do: nil

  defp safe_breadcrumb_level(value)
       when value in [
              :debug,
              :info,
              :warning,
              :error,
              :fatal,
              "debug",
              "info",
              "warning",
              "error",
              "fatal"
            ],
       do: value

  defp safe_breadcrumb_level(_value), do: nil

  defp safe_event_id(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{32}\z/, value), do: value
  end

  defp safe_event_id(_value), do: nil

  defp safe_event_level(value)
       when value in [
              :fatal,
              :error,
              :warning,
              :info,
              :debug,
              "fatal",
              "error",
              "warning",
              "info",
              "debug"
            ],
       do: value

  defp safe_event_level(_value), do: nil

  defp safe_timestamp(value)
       when is_integer(value) and value >= 0 and value <= 253_402_300_799,
       do: value

  defp safe_timestamp(value)
       when is_float(value) and value >= 0.0 and value <= 253_402_300_799.0,
       do: value

  defp safe_timestamp(value) when is_binary(value) do
    if byte_size(value) <= 64 and valid_iso8601_timestamp?(value), do: value
  end

  defp safe_timestamp(_value), do: nil

  defp valid_iso8601_timestamp?(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value)) or
      match?({:ok, _naive_datetime}, NaiveDateTime.from_iso8601(value))
  end

  defp maybe_put_if_present(map, allowed_keys, key, value) do
    if Map.has_key?(allowed_keys, key), do: Map.put(map, key, value), else: map
  end

  defp fail_closed(%{__struct__: module} = event) when is_atom(module) do
    if sentry_event?(event) do
      fail_closed_sentry_event(event, module)
    else
      fail_closed_struct(event, module)
    end
  rescue
    _exception -> fail_closed_map(event)
  catch
    _kind, _reason -> fail_closed_map(event)
  end

  defp fail_closed(event) when is_map(event), do: fail_closed_map(event)

  defp fail_closed_sentry_event(event, module) do
    event_map = Map.from_struct(event)

    safe_values = %{
      event_id: safe_event_id(Map.get(event_map, :event_id)),
      timestamp: safe_timestamp(Map.get(event_map, :timestamp)),
      level: safe_event_level(Map.get(event_map, :level)),
      platform: :elixir,
      release: safe_release(Map.get(event_map, :release)),
      environment: safe_identifier(Map.get(event_map, :environment)),
      sdk: nil,
      source: Map.get(event_map, :source)
    }

    module
    |> struct()
    |> Map.from_struct()
    |> Map.merge(safe_values)
    |> Map.merge(%{
      breadcrumbs: [],
      contexts: %{},
      exception: [],
      extra: %{sentry_filter_failed: true},
      fingerprint: [],
      message: nil,
      modules: %{},
      request: nil,
      server_name: @redacted,
      tags: %{},
      threads: nil,
      user: %{}
    })
    |> then(&struct(module, &1))
  end

  defp fail_closed_struct(event, module) do
    base = struct(module)
    allowed_keys = base |> Map.from_struct() |> Map.keys() |> MapSet.new()

    safe_values =
      event
      |> Map.from_struct()
      |> Map.take([:event_id, :timestamp, :level, :platform, :release, :environment])
      |> Map.take(MapSet.to_list(allowed_keys))

    base
    |> Map.from_struct()
    |> Map.merge(safe_values)
    |> maybe_put_allowed(allowed_keys, :message, @filtered)
    |> maybe_put_allowed(allowed_keys, :server_name, @redacted)
    |> maybe_put_allowed(allowed_keys, :user, %{})
    |> maybe_put_allowed(allowed_keys, :extra, %{sentry_filter_failed: true})
    |> then(&struct(module, &1))
  end

  defp fail_closed_map(event) when is_map(event) do
    event
    |> Map.take(["event_id", :event_id, "timestamp", :timestamp, "level", :level])
    |> Map.merge(%{message: @filtered, server_name: @redacted, user: %{}})
  end

  defp maybe_put_allowed(map, allowed_keys, key, value) do
    if MapSet.member?(allowed_keys, key), do: Map.put(map, key, value), else: map
  end

  defp scrub_nested(value) when is_list(value), do: Enum.map(value, &scrub_nested/1)
  defp scrub_nested(value) when is_struct(value), do: scrub_struct(value)
  defp scrub_nested(value) when is_map(value), do: scrub_map(value)
  defp scrub_nested(value), do: value

  defp scrub_struct(%{__struct__: module} = value) do
    value
    |> Map.from_struct()
    |> scrub_map()
    |> then(&struct(module, &1))
  end

  defp scrub_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, acc ->
      normalized_key = normalize_key(key)
      Map.put(acc, key, scrub_value(normalized_key, nested_value))
    end)
  end

  defp scrub_value("server_name", _value), do: @redacted
  defp scrub_value("user", value), do: scrub_user(value)
  defp scrub_value("request", value), do: scrub_request(value)
  defp scrub_value("frames", value), do: scrub_frames(value)
  defp scrub_value("headers", value), do: scrub_headers(value)
  defp scrub_value("modules", _value), do: %{}
  defp scrub_value("fingerprint", value) when is_list(value), do: []

  defp scrub_value(normalized_key, _value)
       when normalized_key in ["cookie", "cookies"],
       do: @filtered

  defp scrub_value(normalized_key, value) when is_binary(normalized_key) do
    cond do
      safe_correlation_hash_key?(normalized_key) ->
        scrub_correlation_hash(value)

      sensitive_key?(normalized_key) or sensitive_suffix?(normalized_key) ->
        @filtered

      true ->
        scrub_nested(value)
    end
  end

  defp scrub_value(_normalized_key, value), do: scrub_nested(value)

  defp scrub_event_request(%{__struct__: module} = request) when is_atom(module) do
    base = struct(module)
    method = request |> Map.from_struct() |> request_method()

    if Map.has_key?(base, :method) do
      struct(module, method: method)
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp scrub_event_request(_request), do: nil

  defp scrub_request(%{__struct__: module} = request) when is_atom(module) do
    scrub_event_request(request) || %{}
  end

  defp scrub_request(request) when is_map(request) do
    method = request_method(request)

    cond do
      is_nil(method) -> %{}
      Map.has_key?(request, :method) -> %{method: method}
      Map.has_key?(request, "method") -> %{"method" => method}
      true -> %{}
    end
  end

  defp scrub_request(_request), do: %{}

  defp request_method(request) do
    request
    |> request_method_value()
    |> normalize_http_method()
  end

  defp request_method_value(request) do
    case Map.fetch(request, :method) do
      {:ok, method} when not is_nil(method) -> method
      _missing_or_nil -> Map.get(request, "method")
    end
  end

  defp normalize_http_method(method) when is_binary(method) do
    if MapSet.member?(@allowed_http_methods, method), do: method
  end

  defp normalize_http_method(_method), do: nil

  defp scrub_interface_frames(frames) when is_list(frames) do
    Enum.flat_map(frames, fn frame ->
      case rebuild_frame(frame) do
        {:ok, %{__struct__: _module} = safe_frame} -> [safe_frame]
        _dropped -> []
      end
    end)
  end

  defp scrub_interface_frames(_frames), do: []

  defp scrub_frames(frames) when is_list(frames), do: Enum.map(frames, &scrub_frame/1)
  defp scrub_frames(_frames), do: []

  defp scrub_frame(frame) do
    case rebuild_frame(frame) do
      {:ok, safe_frame} -> safe_frame
      :error -> %{}
    end
  end

  defp rebuild_frame(%{__struct__: module} = frame) when is_atom(module) do
    base = struct(module)

    safe_values =
      frame
      |> Map.from_struct()
      |> scrub_frame_map()

    rebuilt =
      base
      |> Map.from_struct()
      |> Map.merge(safe_values)
      |> then(&struct(module, &1))

    {:ok, rebuilt}
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp rebuild_frame(frame) when is_map(frame), do: {:ok, scrub_frame_map(frame)}
  defp rebuild_frame(_frame), do: :error

  defp scrub_frame_map(frame) do
    source_root = frame_source_root(frame)

    Enum.reduce(frame, %{}, fn {key, value}, acc ->
      normalized_key = normalize_key(key)

      if MapSet.member?(@safe_frame_keys, normalized_key) do
        Map.put(acc, key, scrub_frame_value(normalized_key, value, source_root))
      else
        acc
      end
    end)
  end

  defp frame_source_root(frame) do
    case Map.fetch(frame, :module) do
      {:ok, module} when not is_nil(module) -> first_party_source_root(module)
      _missing_or_nil -> frame |> Map.get("module") |> first_party_source_root()
    end
  end

  defp first_party_source_root(module) when is_atom(module) and not is_nil(module) do
    case :application.get_application(module) do
      {:ok, app} -> Keyword.get(@first_party_app_source_roots, app)
      _unowned -> nil
    end
  end

  defp first_party_source_root(_module), do: nil

  defp scrub_frame_value("module", value, _source_root), do: safe_frame_module(value)
  defp scrub_frame_value("function", value, _source_root), do: safe_frame_function(value)
  defp scrub_frame_value("filename", value, source_root), do: scrub_filename(value, source_root)

  defp scrub_frame_value("lineno", value, _source_root),
    do: safe_frame_location(value, 10_000_000)

  defp scrub_frame_value("colno", value, _source_root), do: safe_frame_location(value, 1_000_000)
  defp scrub_frame_value("in_app", value, _source_root) when is_boolean(value), do: value
  defp scrub_frame_value("in_app", _value, _source_root), do: nil

  defp safe_frame_module(value) when is_atom(value) do
    case safe_frame_module(Atom.to_string(value)) do
      @filtered -> @filtered
      _safe_name -> value
    end
  end

  defp safe_frame_module(value) when is_binary(value) do
    if byte_size(value) <= 200 and Regex.match?(~r/\A[A-Za-z0-9_.]+\z/, value) do
      value
    else
      @filtered
    end
  end

  defp safe_frame_module(_value), do: @filtered

  defp safe_frame_function(value) when is_atom(value),
    do: value |> Atom.to_string() |> safe_frame_function()

  defp safe_frame_function(value) when is_binary(value) do
    if byte_size(value) <= 200 and
         Regex.match?(~r/\A[A-Za-z0-9_!?@.:+\-][A-Za-z0-9_!?@.:+\-\/]*\/[0-9]{1,3}\z/, value) do
      value
    else
      @filtered
    end
  end

  defp safe_frame_function(_value), do: @filtered

  defp safe_frame_location(value, maximum)
       when is_integer(value) and value >= 1 and value <= maximum,
       do: value

  defp safe_frame_location(_value, _maximum), do: nil

  defp scrub_filename(filename, source_root) when is_binary(filename) do
    with true <- String.valid?(filename),
         true <- byte_size(filename) <= 512,
         false <- Regex.match?(~r/[\x00-\x1F\x7F]/, filename),
         false <- String.contains?(filename, ["\\", "://"]),
         {:ok, relative} <- first_party_relative_path(filename, source_root),
         true <- safe_relative_source_path?(relative) do
      relative
    else
      _unsafe -> @filtered
    end
  end

  defp scrub_filename(_filename, _source_root), do: @filtered

  defp first_party_relative_path(filename, source_root) do
    case repo_relative_source_path(filename) do
      {:ok, relative} -> {:ok, relative}
      :error -> app_relative_source_path(filename, source_root)
    end
  end

  defp repo_relative_source_path(filename) do
    Enum.find_value(@first_party_source_roots, :error, fn root ->
      cond do
        String.starts_with?(filename, root) ->
          {:ok, filename}

        Path.type(filename) == :absolute and String.contains?(filename, "/" <> root) ->
          [_prefix, suffix] = String.split(filename, "/" <> root, parts: 2)
          {:ok, root <> suffix}

        true ->
          false
      end
    end)
  end

  defp app_relative_source_path(_filename, nil), do: :error

  defp app_relative_source_path(filename, source_root) do
    if String.starts_with?(filename, @app_relative_source_root) do
      {:ok, String.replace_prefix(filename, @app_relative_source_root, source_root)}
    else
      :error
    end
  end

  defp safe_relative_source_path?(path) do
    segments = String.split(path, "/", trim: false)

    Enum.all?(segments, &(&1 not in ["", ".", ".."])) and
      Path.extname(path) in [".ex", ".exs"] and
      Enum.any?(@first_party_source_roots, &String.starts_with?(path, &1))
  end

  defp scrub_correlation_hash(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{16}\z/, value), do: value, else: @filtered
  end

  defp scrub_correlation_hash(_value), do: @filtered

  defp safe_correlation_hash_key?(key), do: MapSet.member?(@safe_correlation_hash_keys, key)

  defp scrub_user(value) when is_nil(value) or value == %{}, do: value

  defp scrub_user(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> scrub_user()
    |> then(&struct(value.__struct__, &1))
  end

  defp scrub_user(value) when is_map(value),
    do: Map.new(value, fn {key, _value} -> {key, @filtered} end)

  defp scrub_user(_value), do: @filtered

  defp scrub_headers(value) when is_map(value),
    do: Map.new(value, fn {key, _value} -> {key, @filtered} end)

  defp scrub_headers(value) when is_list(value), do: []
  defp scrub_headers(_value), do: %{}

  defp sensitive_key?(key) do
    MapSet.member?(@sensitive_keys, key) or
      String.ends_with?(key, "_secret") or
      String.ends_with?(key, "_password") or
      (String.ends_with?(key, "_token") and not MapSet.member?(@safe_token_keys, key))
  end

  defp sensitive_suffix?(key) do
    Enum.any?(
      [
        "_certificate",
        "_certificate_pem",
        "_certificate_chain",
        "_private_key",
        "_private_key_pem",
        "_public_key",
        "_signing_key",
        "_key_pem",
        "_keyfile",
        "_certfile",
        "_fingerprint",
        "_machine_id",
        "_path",
        "_dir",
        "_root",
        "_uri",
        "_pem",
        "_cert"
      ],
      &String.ends_with?(key, &1)
    ) or key in ["pem", "cert", "certificate_chain"]
  end

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()

  defp normalize_key(key) when is_binary(key) do
    key
    |> Macro.underscore()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp normalize_key(_key), do: nil
end
