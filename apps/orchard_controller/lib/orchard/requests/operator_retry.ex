defmodule Orchard.Requests.OperatorRetry do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias Orchard.CanonicalRequest
  alias Orchard.Governance.Tenant

  alias Orchard.Inference.{
    ChatResponseSerializer,
    RequestOrchestrator,
    ResponsesSerializer
  }

  alias Orchard.Models.{Access, Model}
  alias Orchard.Repo
  alias Orchard.Requests
  alias Orchard.Requests.{CapturePolicy, Request}

  @max_retries 3
  @retryable_states [:failed, :cancelled, :timed_out, :interrupted]
  @canonical_keys ~w(
    internal_id
    public_id
    endpoint
    tenant_id
    principal_type
    principal_id
    service_account_id
    api_key_id
    model_ref
    input_items
    rendered_prompt
    input_token_count
    store
    stream
    stream_include_usage
    sampling
    response_format
    tooling
    metadata
    admission
    resolved_policy
  )
  @sampling_keys ~w(temperature top_p max_output_tokens stop seed)
  @response_format_keys ~w(type)
  @tooling_keys ~w(tools requested_tools tool_choice registry_snapshot execution_snapshot)
  @resolved_policy_keys ~w(
    quota_id
    routing_policy_id
    allowed_pool_ids
    max_active_requests
    residency_preference
  )

  @type reservation :: %{
          request: Request.t(),
          canonical: CanonicalRequest.t(),
          model: Model.t()
        }

  @type retry_error ::
          :operator_retry_limit_reached
          | :request_not_found
          | :retry_dispatch_incomplete
          | :retry_source_not_authorized
          | :retry_source_not_eligible
          | :retry_source_unavailable

  @spec retry(String.t(), keyword()) :: {:ok, Request.t()} | {:error, retry_error()}
  def retry(public_id, dispatch_opts \\ []) do
    with {:ok, reservation} <- reserve(public_id) do
      dispatch(reservation, dispatch_opts)
    end
  end

  @spec reserve(String.t()) :: {:ok, reservation()} | {:error, retry_error()}
  def reserve(public_id) when is_binary(public_id) do
    Repo.transaction(fn -> reserve_locked(public_id) end)
    |> unwrap_reservation()
  end

  def reserve(_public_id), do: {:error, :request_not_found}

  defp reserve_locked(public_id) do
    with {:ok, source} <- lock_source(public_id),
         :ok <- ensure_retryable(source),
         {:ok, original} <- lock_original(source),
         {:ok, tenant} <- lock_tenant(source.tenant_id),
         {:ok, model} <- fetch_active_source_model(source),
         {:ok, routing_opts} <- authorize_current_access(source, model),
         {:ok, canonical} <- rebuild_legacy_canonical(source, model, routing_opts),
         :ok <- ensure_dispatchable_canonical(canonical),
         :ok <- ensure_retry_capacity(original.id),
         {:ok, request, persisted_canonical} <-
           create_descendant(source, original, tenant, model, canonical) do
      %{request: request, canonical: persisted_canonical, model: model}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_source(public_id) do
    request =
      Request
      |> where([request], request.public_id == ^public_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case request do
      %Request{} = request -> {:ok, request}
      nil -> {:error, :request_not_found}
    end
  end

  defp ensure_retryable(%Request{state: state}) when state not in @retryable_states,
    do: {:error, :retry_source_not_eligible}

  defp ensure_retryable(%Request{
         payload_capture_mode: :full,
         canonical_request: canonical_request
       })
       when is_map(canonical_request),
       do: :ok

  defp ensure_retryable(%Request{}), do: {:error, :retry_source_unavailable}

  defp lock_original(%Request{retry_of_request_id: nil} = source), do: {:ok, source}

  defp lock_original(%Request{retry_of_request_id: original_id}) do
    original =
      Request
      |> where([request], request.id == ^original_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case original do
      %Request{} = original -> {:ok, original}
      nil -> {:error, :retry_source_unavailable}
    end
  end

  defp lock_tenant(tenant_id) do
    tenant =
      Tenant
      |> where([tenant], tenant.id == ^tenant_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case tenant do
      %Tenant{} = tenant -> {:ok, tenant}
      nil -> {:error, :retry_source_unavailable}
    end
  end

  defp fetch_active_source_model(%Request{model_id: model_id}) when is_binary(model_id) do
    case Repo.get(Model, model_id) do
      %Model{state: :active} = model -> {:ok, model}
      %Model{} -> {:error, :retry_source_not_authorized}
      nil -> {:error, :retry_source_unavailable}
    end
  end

  defp fetch_active_source_model(%Request{}), do: {:error, :retry_source_unavailable}

  defp authorize_current_access(%Request{tenant_id: tenant_id}, %Model{id: model_id}) do
    case Access.authorize(tenant_id, model_id) do
      {:ok, _routing_opts} = authorized -> authorized
      {:error, :model_not_authorized} -> {:error, :retry_source_not_authorized}
    end
  end

  defp rebuild_legacy_canonical(source, model, routing_opts) do
    canonical = source.canonical_request

    with :ok <- ensure_omitted_legacy_contract(canonical),
         :ok <- ensure_source_identity(canonical, source, model),
         {:ok, attrs} <- decode_canonical_attrs(canonical, source) do
      attrs
      |> apply_current_access(routing_opts)
      |> build_canonical()
    end
  end

  defp apply_current_access(attrs, routing_opts) do
    %{
      attrs
      | admission: current_admission(attrs.admission, routing_opts),
        resolved_policy: current_resolved_policy(attrs.resolved_policy, routing_opts)
    }
  end

  defp current_admission(admission, routing_opts) do
    %{
      admission
      | queue_wait_ms: narrower_budget(admission.queue_wait_ms, routing_opts[:queue_wait_ms]),
        max_cold_start_ms:
          narrower_budget(admission.max_cold_start_ms, routing_opts[:max_cold_start_ms])
    }
  end

  defp current_resolved_policy(resolved_policy, routing_opts) do
    %{
      resolved_policy
      | routing_policy_id: routing_opts[:routing_policy_id],
        allowed_pool_ids: Keyword.get(routing_opts, :allowed_pool_ids, []),
        residency_preference:
          Keyword.get(
            routing_opts,
            :residency_preference,
            resolved_policy.residency_preference
          )
    }
  end

  defp narrower_budget(retained, current) when is_integer(current) and current >= 0,
    do: min(retained, current)

  defp narrower_budget(retained, _current), do: retained

  defp ensure_omitted_legacy_contract(canonical) when is_map(canonical) do
    if Map.has_key?(canonical, "reasoning") do
      {:error, :retry_source_unavailable}
    else
      :ok
    end
  end

  defp ensure_omitted_legacy_contract(_canonical), do: {:error, :retry_source_unavailable}

  defp ensure_source_identity(canonical, source, model) do
    model_ref = Map.get(canonical, "model_ref")

    if source_identity_matches?(canonical, model_ref, source, model) do
      :ok
    else
      {:error, :retry_source_unavailable}
    end
  end

  defp source_identity_matches?(canonical, model_ref, source, model) when is_map(model_ref) do
    source_attributes_match?(canonical, source) and
      model_reference_matches?(model_ref, source, model)
  end

  defp source_identity_matches?(_canonical, _model_ref, _source, _model), do: false

  defp source_attributes_match?(canonical, source) do
    canonical["public_id"] == source.public_id and
      canonical["endpoint"] == Atom.to_string(source.endpoint) and
      canonical["tenant_id"] == source.tenant_id and
      canonical["principal_type"] == Atom.to_string(source.principal_type) and
      canonical["principal_id"] == principal_id_for(source) and
      canonical["api_key_id"] == source.api_key_id and
      canonical["service_account_id"] == source.service_account_id
  end

  defp model_reference_matches?(model_ref, source, model) do
    model_ref["model_id"] == model.model_id and
      model_ref["version"] == model.version and
      source.requested_model == "#{model.model_id}@#{model.version}"
  end

  defp principal_id_for(%Request{principal_type: :tenant, tenant_id: tenant_id}), do: tenant_id

  defp principal_id_for(%Request{
         principal_type: :service_account,
         service_account_id: account_id
       }),
       do: account_id

  defp decode_canonical_attrs(canonical, source) do
    with true <- required_keys?(canonical, @canonical_keys),
         true <- required_keys?(canonical["model_ref"], ~w(model_id version)),
         true <- required_keys?(canonical["sampling"], @sampling_keys),
         true <- required_keys?(canonical["tooling"], @tooling_keys),
         {:ok, endpoint} <- decode_endpoint(canonical["endpoint"]),
         {:ok, principal_type} <- decode_principal_type(canonical["principal_type"]),
         {:ok, response_format} <- decode_response_format(canonical["response_format"]),
         {:ok, resolved_policy} <- decode_resolved_policy(canonical["resolved_policy"]),
         {:ok, admission} <- decode_admission(canonical["admission"]),
         {:ok, registry_snapshot} <-
           decode_tool_snapshot(canonical["tooling"]["registry_snapshot"]),
         {:ok, execution_snapshot} <-
           decode_tool_snapshot(canonical["tooling"]["execution_snapshot"]) do
      internal_id = Ecto.UUID.generate()

      {:ok,
       %{
         internal_id: internal_id,
         public_id: retry_public_id(endpoint, internal_id),
         endpoint: endpoint,
         tenant_id: source.tenant_id,
         principal_type: principal_type,
         principal_id: canonical["principal_id"],
         service_account_id: canonical["service_account_id"],
         api_key_id: canonical["api_key_id"],
         model_ref: %{
           model_id: canonical["model_ref"]["model_id"],
           version: canonical["model_ref"]["version"]
         },
         input_items: canonical["input_items"],
         rendered_prompt: canonical["rendered_prompt"],
         input_token_count: canonical["input_token_count"],
         store?: canonical["store"],
         stream?: canonical["stream"],
         stream_include_usage: canonical["stream_include_usage"],
         sampling: %{
           temperature: canonical["sampling"]["temperature"],
           top_p: canonical["sampling"]["top_p"],
           max_output_tokens: canonical["sampling"]["max_output_tokens"],
           stop: canonical["sampling"]["stop"],
           seed: canonical["sampling"]["seed"]
         },
         response_format: response_format,
         tooling: %{
           tools: canonical["tooling"]["tools"],
           requested_tools: canonical["tooling"]["requested_tools"],
           tool_choice: canonical["tooling"]["tool_choice"],
           registry_snapshot: registry_snapshot,
           execution_snapshot: execution_snapshot
         },
         metadata: canonical["metadata"],
         admission: admission,
         resolved_policy: resolved_policy
       }}
    else
      _invalid -> {:error, :retry_source_unavailable}
    end
  end

  defp decode_endpoint("chat_completions"), do: {:ok, :chat_completions}
  defp decode_endpoint("responses"), do: {:ok, :responses}
  defp decode_endpoint(_endpoint), do: {:error, :retry_source_unavailable}

  defp decode_principal_type("tenant"), do: {:ok, :tenant}
  defp decode_principal_type("service_account"), do: {:ok, :service_account}
  defp decode_principal_type(_principal_type), do: {:error, :retry_source_unavailable}

  defp decode_response_format(response_format) do
    with true <- required_keys?(response_format, @response_format_keys),
         {:ok, type} <- decode_response_format_type(response_format["type"]) do
      {:ok, %{type: type}}
    else
      _invalid -> {:error, :retry_source_unavailable}
    end
  end

  defp decode_response_format_type("text"), do: {:ok, :text}
  defp decode_response_format_type("json_object"), do: {:ok, :json_object}
  defp decode_response_format_type(_type), do: {:error, :retry_source_unavailable}

  defp decode_resolved_policy(resolved_policy) do
    with true <- required_keys?(resolved_policy, @resolved_policy_keys),
         {:ok, residency_preference} <-
           decode_residency_preference(resolved_policy["residency_preference"]) do
      {:ok,
       %{
         quota_id: resolved_policy["quota_id"],
         routing_policy_id: resolved_policy["routing_policy_id"],
         allowed_pool_ids: resolved_policy["allowed_pool_ids"],
         max_active_requests: resolved_policy["max_active_requests"],
         residency_preference: residency_preference
       }}
    else
      _invalid -> {:error, :retry_source_unavailable}
    end
  end

  defp decode_admission(%{
         "timeout_ms" => timeout_ms,
         "queue_wait_ms" => queue_wait_ms,
         "max_cold_start_ms" => max_cold_start_ms
       })
       when is_integer(timeout_ms) and timeout_ms > 0 and
              is_integer(queue_wait_ms) and queue_wait_ms >= 0 and
              is_integer(max_cold_start_ms) and max_cold_start_ms >= 0 do
    {:ok,
     %{
       timeout_ms: timeout_ms,
       queue_wait_ms: queue_wait_ms,
       max_cold_start_ms: max_cold_start_ms
     }}
  end

  defp decode_admission(_admission), do: {:error, :retry_source_unavailable}

  defp decode_residency_preference("required_loaded"), do: {:ok, :required_loaded}
  defp decode_residency_preference("prefer_loaded"), do: {:ok, :prefer_loaded}
  defp decode_residency_preference("allow_cold_load"), do: {:ok, :allow_cold_load}
  defp decode_residency_preference(_preference), do: {:error, :retry_source_unavailable}

  defp decode_tool_snapshot(%{"entries" => entries}) when is_list(entries),
    do: {:ok, %{entries: entries}}

  defp decode_tool_snapshot(%{entries: entries}) when is_list(entries),
    do: {:ok, %{entries: entries}}

  defp decode_tool_snapshot(_snapshot), do: {:error, :retry_source_unavailable}

  defp required_keys?(map, keys) when is_map(map),
    do: Enum.all?(keys, &Map.has_key?(map, &1))

  defp required_keys?(_value, _keys), do: false

  defp retry_public_id(:chat_completions, internal_id), do: "chatcmpl-" <> internal_id
  defp retry_public_id(:responses, _internal_id), do: "resp_" <> Ecto.UUID.generate()

  defp build_canonical(attrs) do
    {:ok, CanonicalRequest.new(attrs)}
  rescue
    _error in [ArgumentError, KeyError] -> {:error, :retry_source_unavailable}
  end

  defp ensure_dispatchable_canonical(canonical) do
    case RequestOrchestrator.validate_resolved_tooling(canonical) do
      :ok -> :ok
      {:error, _reason} -> {:error, :retry_source_unavailable}
    end
  end

  defp ensure_retry_capacity(original_id) do
    retry_count =
      Request
      |> where([request], request.retry_of_request_id == ^original_id)
      |> Repo.aggregate(:count)

    if retry_count < @max_retries,
      do: :ok,
      else: {:error, :operator_retry_limit_reached}
  end

  defp create_descendant(source, original, tenant, model, canonical) do
    capture_mode =
      source.payload_capture_mode
      |> CapturePolicy.narrower(tenant.request_body_capture_mode)
      |> CapturePolicy.resolve(canonical.store?)

    case RequestOrchestrator.persistable_request_attrs(canonical, model,
           capture_mode: capture_mode,
           admission_opts: retained_admission_opts(canonical)
         ) do
      {:ok, attrs, persisted_canonical} ->
        insert_descendant(attrs, original, persisted_canonical)

      {:error, _reason} ->
        {:error, :retry_source_unavailable}
    end
  end

  defp retained_admission_opts(%CanonicalRequest{admission: admission}) do
    [
      effective_timeout_ms: admission.timeout_ms,
      queue_wait_ms: admission.queue_wait_ms,
      max_cold_start_ms: admission.max_cold_start_ms
    ]
  end

  defp insert_descendant(attrs, original, canonical) do
    case Requests.create_request(Map.put(attrs, :retry_of_request_id, original.id)) do
      {:ok, request} -> {:ok, request, canonical}
      {:error, %Ecto.Changeset{}} -> {:error, :retry_source_unavailable}
    end
  end

  defp dispatch(%{request: request, canonical: canonical, model: model}, dispatch_opts) do
    opts = Keyword.put(dispatch_opts, :success_persistence, &success_persistence_attrs/2)

    request
    |> RequestOrchestrator.execute_persisted(canonical, model, opts)
    |> handle_dispatch_result(request)
  end

  defp handle_dispatch_result({:error, {:terminal_persist_failed, _reason}}, request) do
    Logger.warning(
      "operator retry descendant retained without a terminal outcome: " <>
        dispatch_identifiers(request) <> " outcome=terminal_persist_failed"
    )

    {:error, :retry_dispatch_incomplete}
  end

  defp handle_dispatch_result({:error, reason}, request) do
    Logger.info(
      "operator retry dispatch failed: " <>
        dispatch_identifiers(request) <> " outcome=#{outcome_label(reason)}"
    )

    {:ok, Requests.get_request!(request.id)}
  end

  defp handle_dispatch_result(_result, request), do: {:ok, Requests.get_request!(request.id)}

  defp dispatch_identifiers(request) do
    "public_id=#{request.public_id} retry_of_request_id=#{request.retry_of_request_id}"
  end

  defp outcome_label(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp outcome_label(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: outcome_label(elem(reason, 0))

  defp outcome_label(_reason), do: "unknown"

  defp success_persistence_attrs(
         %CanonicalRequest{endpoint: :chat_completions} = canonical,
         events
       ),
       do: ChatResponseSerializer.success_persistence_attrs(canonical, events)

  defp success_persistence_attrs(%CanonicalRequest{endpoint: :responses} = canonical, events),
    do: ResponsesSerializer.success_persistence_attrs(canonical, events)

  defp unwrap_reservation({:ok, reservation}), do: {:ok, reservation}
  defp unwrap_reservation({:error, reason}), do: {:error, reason}
end
