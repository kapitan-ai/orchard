defmodule Orchard.Requests.OperatorRetry do
  @moduledoc false

  import Ecto.Query

  alias Orchard.CanonicalRequest
  alias Orchard.Governance.Tenant

  alias Orchard.Inference.{
    ChatResponseSerializer,
    RequestDeadline,
    RequestOrchestrator,
    ResponsesSerializer
  }

  alias Orchard.Inference.CanonicalRequestSerializer
  alias Orchard.Models.Model
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
  @admission_keys ~w(timeout_ms queue_wait_ms max_cold_start_ms)
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
          | :retry_source_not_eligible
          | :retry_source_unavailable

  @spec retry(String.t()) :: {:ok, Request.t()} | {:error, retry_error()}
  def retry(public_id) do
    with {:ok, reservation} <- reserve(public_id) do
      dispatch(reservation)
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
         {:ok, model} <- fetch_source_model(source),
         {:ok, canonical} <- rebuild_legacy_canonical(source, model),
         :ok <- ensure_dispatchable_canonical(canonical),
         :ok <- ensure_retry_capacity(original.id),
         {:ok, request} <- create_descendant(source, original, tenant, model, canonical) do
      %{request: request, canonical: canonical, model: model}
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

  defp fetch_source_model(%Request{model_id: model_id}) when is_binary(model_id) do
    case Repo.get(Model, model_id) do
      %Model{} = model -> {:ok, model}
      nil -> {:error, :retry_source_unavailable}
    end
  end

  defp fetch_source_model(%Request{}), do: {:error, :retry_source_unavailable}

  defp rebuild_legacy_canonical(source, model) do
    canonical = source.canonical_request

    with :ok <- ensure_omitted_legacy_contract(canonical),
         :ok <- ensure_source_identity(canonical, source, model),
         {:ok, attrs} <- decode_canonical_attrs(canonical, source) do
      build_canonical(attrs)
    end
  end

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
         {:ok, endpoint} <- decode_endpoint(canonical["endpoint"]),
         {:ok, principal_type} <- decode_principal_type(canonical["principal_type"]),
         {:ok, response_format} <- decode_response_format(canonical["response_format"]),
         {:ok, resolved_policy} <- decode_resolved_policy(canonical["resolved_policy"]),
         {:ok, registry_snapshot} <-
           decode_tool_snapshot(canonical["tooling"]["registry_snapshot"]),
         {:ok, execution_snapshot} <-
           decode_tool_snapshot(canonical["tooling"]["execution_snapshot"]),
         true <- required_keys?(canonical["model_ref"], ~w(model_id version)),
         true <- required_keys?(canonical["sampling"], @sampling_keys),
         true <- required_keys?(canonical["tooling"], @tooling_keys),
         true <- required_keys?(canonical["admission"], @admission_keys) do
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
         admission: %{
           timeout_ms: canonical["admission"]["timeout_ms"],
           queue_wait_ms: canonical["admission"]["queue_wait_ms"],
           max_cold_start_ms: canonical["admission"]["max_cold_start_ms"]
         },
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

    serialized = CanonicalRequestSerializer.serialize(canonical)

    attrs = %{
      id: canonical.internal_id,
      public_id: canonical.public_id,
      endpoint: canonical.endpoint,
      tenant_id: canonical.tenant_id,
      principal_type: canonical.principal_type,
      api_key_id: canonical.api_key_id,
      service_account_id: canonical.service_account_id,
      model_id: model.id,
      requested_model: "#{canonical.model_ref.model_id}@#{canonical.model_ref.version}",
      retry_of_request_id: original.id,
      state: :received,
      stream: canonical.stream?,
      body_hash: :crypto.hash(:sha256, Jason.encode!(serialized)),
      payload_capture_mode: capture_mode,
      canonical_request: serialized,
      request_payload: %{"prompt" => canonical.rendered_prompt},
      sampling_params: CanonicalRequestSerializer.sampling_params(canonical.sampling),
      response_format: %{"type" => Atom.to_string(canonical.response_format.type)},
      input_tokens: canonical.input_token_count,
      reserved_output_tokens: max_output_tokens(canonical),
      timeout_at: RequestDeadline.timeout_at(canonical.admission.timeout_ms, utc_now())
    }

    Requests.create_request(attrs)
  end

  defp max_output_tokens(%CanonicalRequest{sampling: %{max_output_tokens: value}})
       when is_integer(value) and value > 0,
       do: value

  defp max_output_tokens(%CanonicalRequest{}), do: 4_096

  defp dispatch(%{request: request, canonical: canonical, model: model}) do
    _result =
      RequestOrchestrator.execute_persisted(request, canonical, model,
        success_persistence: &success_persistence_attrs/2
      )

    {:ok, Requests.get_request!(request.id)}
  end

  defp success_persistence_attrs(
         %CanonicalRequest{endpoint: :chat_completions} = canonical,
         events
       ),
       do: ChatResponseSerializer.success_persistence_attrs(canonical, events)

  defp success_persistence_attrs(%CanonicalRequest{endpoint: :responses} = canonical, events),
    do: ResponsesSerializer.success_persistence_attrs(canonical, events)

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp unwrap_reservation({:ok, reservation}), do: {:ok, reservation}
  defp unwrap_reservation({:error, reason}), do: {:error, reason}
end
