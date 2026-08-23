defmodule Orchard.SentryContext do
  @moduledoc """
  Privacy-preserving Sentry enrichment boundary for Orchard crash events.
  """

  require Logger

  @warning_key {__MODULE__, :sdk_warning_logged?}
  @redacted "[redacted]"

  @type source :: map() | struct() | nil

  @spec controller_enabled?() :: boolean()
  def controller_enabled? do
    master_enabled?() and config_value(:controller_enabled?, master_enabled?())
  end

  @spec node_agent_enabled?() :: boolean()
  def node_agent_enabled? do
    master_enabled?() and config_value(:node_agent_enabled?, master_enabled?())
  end

  @spec telemetry_breadcrumbs_enabled?() :: boolean()
  def telemetry_breadcrumbs_enabled? do
    master_enabled?() and config_value(:telemetry_breadcrumbs_enabled?, false)
  end

  @spec hash_id(binary() | nil) :: String.t() | nil
  def hash_id(nil), do: nil

  def hash_id(value) when is_binary(value) do
    case hash_secret() do
      nil ->
        nil

      secret ->
        :hmac
        |> :crypto.mac(:sha256, secret, value)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)
    end
  end

  @spec build_caller_extra(source()) :: map()
  def build_caller_extra(source) do
    %{}
    |> put_hashed(:orchard_tenant_hash, field(source, :tenant_id))
    |> put_plain(:orchard_principal_type, field(source, :principal_type))
    |> put_hashed(:orchard_principal_hash, field(source, :principal_id))
    |> put_hashed(:orchard_api_key_hash, field(source, :api_key_id))
  end

  @spec build_request_extra(source(), source()) :: map()
  def build_request_extra(db_request, canonical) do
    model_ref = field(canonical, :model_ref)

    %{
      orchard_request_id: coalesce(field(canonical, :public_id), field(db_request, :public_id)),
      orchard_db_request_id: field(db_request, :public_id),
      orchard_endpoint: coalesce(field(canonical, :endpoint), field(db_request, :endpoint)),
      orchard_stream: coalesce(field(canonical, :stream?), field(db_request, :stream)),
      orchard_tooling: tooling?(field(canonical, :tooling)),
      orchard_model_id: field(model_ref, :model_id),
      orchard_model_version: field(model_ref, :version)
    }
    |> compact_nil_values()
  end

  @spec build_dispatch_extra(source(), keyword() | map()) :: map()
  def build_dispatch_extra(metrics, opts \\ []) do
    opts = Map.new(opts)
    node_id = coalesce(option(opts, :node_id), field(metrics, :node_id))

    %{
      orchard_node_hash: hash_id(node_id),
      orchard_scheduler_strategy:
        coalesce(option(opts, :scheduler_strategy), field(metrics, :scheduler_strategy)),
      orchard_target_host_sanitized: sanitized_target(opts),
      orchard_model_already_loaded: field(metrics, :model_already_loaded),
      orchard_ensure_model_loaded_ms: field(metrics, :ensure_model_loaded_ms),
      orchard_accepted_to_first_delta_ms: field(metrics, :accepted_to_first_delta_ms),
      orchard_accepted_to_terminal_ms: field(metrics, :accepted_to_terminal_ms),
      orchard_event_count: field(metrics, :event_count),
      orchard_anomaly: field(metrics, :anomaly),
      orchard_conformance_defect: field(metrics, :conformance_defect)
    }
    |> compact_absent_values()
  end

  @spec build_dispatch_tags(source(), keyword() | map()) :: map()
  def build_dispatch_tags(metrics, opts \\ []) do
    opts = Map.new(opts)

    %{
      orchard_app: "controller",
      orchard_surface: "api",
      orchard_endpoint: option(opts, :endpoint),
      stream: option(opts, :stream),
      tooling: option(opts, :tooling),
      scheduler_strategy:
        coalesce(option(opts, :scheduler_strategy), field(metrics, :scheduler_strategy)),
      failure_category:
        option(opts, :failure_category)
        |> coalesce(field(metrics, :failure_category))
        |> coalesce(field(metrics, :outcome)),
      terminal_source: coalesce(option(opts, :terminal_source), field(metrics, :terminal_source))
    }
    |> compact_absent_values()
    |> normalize_tags()
  end

  @spec build_node_request_extra(source()) :: map()
  def build_node_request_extra(execute_request) do
    %{
      orchard_request_id: field(execute_request, :request_id),
      orchard_model_id: field(execute_request, :model_id),
      orchard_model_version: field(execute_request, :version),
      orchard_model_backend: field(execute_request, :model_backend)
    }
    |> compact_nil_values()
  end

  @spec put_extra(map()) :: :ok
  def put_extra(attrs) when is_map(attrs), do: call_context(:set_extra_context, attrs)
  def put_extra(_attrs), do: :ok

  @spec put_tags(map()) :: :ok
  def put_tags(attrs) when is_map(attrs),
    do: call_context(:set_tags_context, normalize_tags(attrs))

  def put_tags(_attrs), do: :ok

  @spec add_breadcrumb(keyword()) :: :ok
  def add_breadcrumb(attrs), do: call_context(:add_breadcrumb, attrs)

  @spec clear_all() :: :ok
  def clear_all do
    context_module = Module.concat([Sentry, Context])

    if Code.ensure_loaded?(context_module) do
      context_module.clear_all()
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @spec breadcrumb_context_present?() :: boolean()
  def breadcrumb_context_present? do
    context_module = Module.concat([Sentry, Context])

    if master_enabled?() and Code.ensure_loaded?(context_module) do
      context = context_module.get_all()
      present?(Map.get(context.extra, :orchard_request_id))
    else
      false
    end
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp put_hashed(acc, key, value) do
    case hash_id(value) do
      nil -> acc
      hashed -> Map.put(acc, key, hashed)
    end
  end

  defp put_plain(acc, _key, nil), do: acc

  defp put_plain(acc, key, value) when is_atom(value),
    do: Map.put(acc, key, Atom.to_string(value))

  defp put_plain(acc, key, value) when is_binary(value), do: Map.put(acc, key, value)
  defp put_plain(acc, _key, _value), do: acc

  defp tooling?(nil), do: false

  defp tooling?(tooling) do
    non_empty_list?(field(tooling, :tools)) or non_empty_list?(field(tooling, :requested_tools)) or
      present?(field(tooling, :tool_choice))
  end

  defp non_empty_list?(value), do: is_list(value) and value != []

  defp sanitized_target(opts) do
    if present?(option(opts, :target_host)) or present?(option(opts, :target)) or
         present?(option(opts, :target_host_sanitized)) do
      @redacted
    end
  end

  defp call_context(function, payload) do
    if master_enabled?() do
      try do
        apply(Module.concat([Sentry, Context]), function, [payload])
        :ok
      rescue
        _exception ->
          warn_once()
          :ok
      catch
        _kind, _reason ->
          warn_once()
          :ok
      end
    else
      :ok
    end
  end

  defp warn_once do
    unless :persistent_term.get(@warning_key, false) do
      :persistent_term.put(@warning_key, true)
      Logger.warning("Sentry enrichment context call failed; continuing without enrichment")
    end
  end

  defp master_enabled?, do: config_value(:enabled?, false)

  defp config_value(key, default) do
    :orchard_shared
    |> Application.get_env(:sentry_enrichment, [])
    |> fetch_config_value(key, default)
  end

  defp fetch_config_value(config, key, default) when is_map(config),
    do: Map.get(config, key, default)

  defp fetch_config_value(config, key, default) when is_list(config),
    do: Keyword.get(config, key, default)

  defp fetch_config_value(_config, _key, default), do: default

  defp hash_secret do
    case config_value(:hash_secret, nil) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _other ->
        nil
    end
  end

  defp field(nil, _key), do: nil

  defp field(source, key) when is_map(source), do: fetch_key(source, key)

  defp option(opts, key), do: fetch_key(opts, key)

  defp fetch_key(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp coalesce(nil, fallback), do: fallback
  defp coalesce(value, _fallback), do: value

  defp compact_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp compact_absent_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) or value == :na or value == :none end)
  end

  defp normalize_tags(tags) do
    tags
    |> compact_absent_values()
    |> Map.new(fn {key, value} -> {key, normalize_tag_value(value)} end)
  end

  defp normalize_tag_value(value) when is_binary(value), do: value
  defp normalize_tag_value(value) when is_boolean(value), do: to_string(value)
  defp normalize_tag_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_tag_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_tag_value(value) when is_float(value), do: Float.to_string(value)
  defp normalize_tag_value(_value), do: "redacted"

  defp present?(value), do: not (is_nil(value) or value == "" or value == :na or value == :none)
end
