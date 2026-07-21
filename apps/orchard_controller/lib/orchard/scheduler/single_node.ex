defmodule Orchard.Scheduler.SingleNode do
  @moduledoc """
  Injectable single-node scheduler and fallback for source-dev runtime targets.

  When status probing succeeds, the scheduler uses live node and placement
  capacity to advertise `:queue_lane_capacity` or return `{:error, :model_busy}`
  for proven saturation.

  Managed targets fail closed: when the target resolves to a known Node and no
  live authorized capacity input can be built — probe failure, skipped probing,
  or missing Controller-owned facts — the scheduler returns
  `{:error, :model_busy}` instead of a legacy direct schedule. Explicitly
  classified unmanaged targets stay dispatchable: they carry an unmanaged
  capacity input, its evaluation, and refresh providers so the dispatcher
  authorizes them through the same shared contract.
  """

  use Orchard.DispatchCapacity.Consumer, wiring: :single_node_authorization

  alias Orchard.CanonicalRequest
  alias Orchard.Dispatch.GrpcNodeRuntimeClient
  alias Orchard.DispatchCapacity.Authorization
  alias Orchard.Inference
  alias Orchard.Nodes
  alias Orchard.RuntimeEndpoint.{GrpcCompatibilityMapper, ModelRef, Observation, Target}

  @callback schedule(CanonicalRequest.t()) :: {:ok, map()} | {:error, term()}

  @default_status_timeout_ms 2_000

  def schedule(%CanonicalRequest{} = request) do
    case Inference.configured_scheduler_impl() do
      nil -> default_schedule(request)
      __MODULE__ -> default_schedule(request)
      module -> module.schedule(request)
    end
  end

  def target, do: Orchard.Inference.runtime_client_target()

  @doc """
  Build a single-node schedule map directly, without delegation.

  Public so that `MultiNode` can call this as a recursion-safe fallback
  when cluster scheduling is unavailable.

  The 1-arity version uses the configured singular `runtime_client_target`.
  The 2-arity version accepts an explicit target, used by `MultiNode` to
  preserve the actual plural target during fallback.
  The 3-arity version accepts test seams for live status probing.

  Options:
  - `:probe_status?` - set to `false` to skip live capacity probing
  - `:status_client` - module implementing `connect/1`, `status/2`, and
    `disconnect/1`. Defaults to `GrpcNodeRuntimeClient` for address-style
    targets and to the configured Runtime Endpoint client for `Target` structs,
    which `GrpcNodeRuntimeClient` cannot address.
  - `:status_timeout_ms` - timeout for the status probe
  """
  def default_schedule(%CanonicalRequest{} = request) do
    default_schedule(request, target())
  end

  def default_schedule(%CanonicalRequest{} = request, target) do
    default_schedule(request, target, [])
  end

  def default_schedule(%CanonicalRequest{} = request, target, opts) when is_list(opts) do
    case resolve_node(target, opts) do
      {:ok, node} ->
        schedule =
          %{
            strategy: :single_node,
            request_id: request.public_id,
            request_timeout_ms: Inference.request_timeout_ms(),
            model_load_timeout_ms: Inference.model_load_timeout_ms(),
            node_id: node && node.id
          }
          |> put_target(target)

        authorize_schedule(schedule, request, target, node, opts)

      {:error, :node_inventory_unavailable} ->
        {:error, :model_busy}
    end
  end

  defp resolve_node(target, opts) do
    resolver = Keyword.get(opts, :node_resolver, &Nodes.lookup_by_target_result/1)

    case resolver.(target) do
      {:ok, %Orchard.Nodes.Node{} = node} -> {:ok, node}
      {:ok, nil} -> {:ok, nil}
      %Orchard.Nodes.Node{} = node -> {:ok, node}
      nil -> {:ok, nil}
      _error -> {:error, :node_inventory_unavailable}
    end
  rescue
    _error -> {:error, :node_inventory_unavailable}
  catch
    _kind, _reason -> {:error, :node_inventory_unavailable}
  end

  defp authorize_schedule(schedule, request, target, node, opts) do
    if Keyword.get(opts, :probe_status?, true) do
      client = status_client(target, opts)
      timeout = Keyword.get(opts, :status_timeout_ms, @default_status_timeout_ms)
      opts = Keyword.put(opts, :observed_at, DateTime.utc_now())

      case client.connect(target) do
        {:ok, channel} ->
          try do
            case client.status(channel, timeout: timeout) do
              {:ok, response} ->
                capacity_schedule(schedule, request, target, node, response, opts)

              {:error, _reason} ->
                unavailable_schedule(schedule, target, node, opts)
            end
          after
            client.disconnect(channel)
          end

        {:error, _reason} ->
          unavailable_schedule(schedule, target, node, opts)
      end
    else
      unavailable_schedule(schedule, target, node, opts)
    end
  rescue
    _error -> unavailable_schedule(schedule, target, node, opts)
  catch
    :exit, _reason -> unavailable_schedule(schedule, target, node, opts)
  end

  defp capacity_schedule(schedule, request, target, node, response, opts) do
    placement_capacity = model_placement_capacity_for(response, request.model_ref)

    case capacity_input(node, target, response, placement_capacity, opts) do
      {:ok, input} ->
        authorize_capacity_input(
          schedule,
          request,
          target,
          node,
          response,
          placement_capacity,
          input,
          opts
        )

      {:error, _reason} ->
        {:error, :model_busy}
    end
  end

  defp authorize_capacity_input(
         schedule,
         request,
         target,
         node,
         response,
         placement_capacity,
         input,
         opts
       ) do
    authority = Keyword.get(opts, :dispatch_capacity_authority, AllocationAuthority)
    result = evaluate_dispatch_capacity(authority, schedule.node_id, input)

    if Consumer.authorized?(result) do
      acquisition_provider =
        capacity_input_provider(
          request,
          target,
          node,
          response,
          placement_capacity,
          :acquisition,
          opts
        )

      revalidation_provider =
        capacity_input_provider(
          request,
          target,
          node,
          response,
          placement_capacity,
          :revalidation,
          opts
        )

      authorized_schedule =
        schedule
        |> Map.put(:queue_lane_capacity, result.available_slots)
        |> Map.put(:dispatch_capacity_input, input)
        |> Map.put(:dispatch_capacity_acquisition_input_provider, acquisition_provider)
        |> Map.put(:dispatch_capacity_input_provider, revalidation_provider)
        |> Map.put(:dispatch_capacity_evaluation, result)
        |> Consumer.put_authority(opts)

      {:ok, authorized_schedule}
    else
      {:error, :model_busy}
    end
  end

  defp capacity_input(node, target, response, placement_capacity, opts) do
    case Keyword.get(opts, :dispatch_capacity_input_provider) do
      provider when is_function(provider, 3) ->
        Consumer.normalize_input(provider.(node, response, placement_capacity))

      provider when is_function(provider, 0) ->
        Consumer.normalize_input(provider.())

      nil when not is_nil(node) ->
        observed_capacity_input(node, target, response, placement_capacity, opts)

      nil ->
        Authorization.unmanaged_input(capacity_target(target), response,
          placement_capacity: placement_capacity,
          now: Keyword.get(opts, :observed_at, DateTime.utc_now())
        )
    end
  end

  defp observed_capacity_input(node, target, response, placement_capacity, opts) do
    observation = normalize_observation(target, response)

    input_opts = [
      minimum_evidence_observed_at: Keyword.fetch!(opts, :observed_at),
      placement_capacity: placement_capacity
    ]

    case observe_capacity(target, response, opts) do
      {:ok, %Orchard.Nodes.Node{id: node_id} = observed} when node_id == node.id ->
        Authorization.input_for_observation(observed, observation, input_opts)

      :noop ->
        Authorization.input_for_node_observation(node.id, observation, input_opts)

      _mismatched_or_unavailable ->
        {:error, :dispatch_capacity_facts_unavailable}
    end
  end

  defp capacity_input_provider(
         request,
         target,
         node,
         response,
         placement_capacity,
         phase,
         opts
       ) do
    if Keyword.has_key?(opts, :dispatch_capacity_input_provider) do
      configured_capacity_input_provider(node, target, response, placement_capacity, opts)
    else
      expected_node_id = if node, do: node.id, else: nil
      fn -> fresh_capacity_input(request, target, expected_node_id, phase, opts) end
    end
  end

  defp configured_capacity_input_provider(node, target, response, placement_capacity, opts) do
    fn ->
      case capacity_input(node, target, response, placement_capacity, opts) do
        {:ok, refreshed_input} -> refreshed_input
        {:error, _reason} -> nil
      end
    end
  end

  defp fresh_capacity_input(request, target, expected_node_id, phase, opts) do
    opts = Keyword.put(opts, :observed_at, DateTime.utc_now())

    with {:ok, node} <- resolve_node(target, opts),
         true <- capacity_identity_matches?(node, expected_node_id),
         {:ok, response} <- fresh_status(target, opts),
         placement_capacity <- refreshed_placement_capacity(response, request.model_ref, phase),
         {:ok, input} <-
           capacity_input(
             node,
             target,
             response,
             placement_capacity,
             opts
           ) do
      input
    else
      _unavailable -> nil
    end
  end

  defp capacity_identity_matches?(%Orchard.Nodes.Node{id: node_id}, node_id), do: true
  defp capacity_identity_matches?(nil, nil), do: true
  defp capacity_identity_matches?(_node, _expected_node_id), do: false

  defp refreshed_placement_capacity(response, model_ref, :acquisition),
    do: model_placement_capacity_for(response, model_ref)

  defp refreshed_placement_capacity(response, model_ref, :revalidation),
    do: post_load_placement_capacity_for(response, model_ref)

  defp status_client(target, opts) do
    Keyword.get_lazy(opts, :status_client, fn -> default_status_client(target) end)
  end

  defp default_status_client(%Target{}), do: Inference.runtime_endpoint_client()
  defp default_status_client(_target), do: GrpcNodeRuntimeClient

  defp fresh_status(target, opts) do
    client = status_client(target, opts)
    timeout = Keyword.get(opts, :status_timeout_ms, @default_status_timeout_ms)

    case client.connect(target) do
      {:ok, channel} ->
        try do
          client.status(channel, timeout: timeout)
        after
          client.disconnect(channel)
        end

      {:error, _reason} = error ->
        error
    end
  rescue
    _error -> {:error, :status_unavailable}
  catch
    _kind, _reason -> {:error, :status_unavailable}
  end

  defp observe_capacity(target, response, opts) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    Nodes.observe_status(target, response, observed_at)
  end

  defp normalize_observation(_target, %Observation{} = observation), do: observation

  defp normalize_observation(target, response),
    do: GrpcCompatibilityMapper.observation_from_status(Target.normalize(target), response)

  defp unavailable_schedule(_schedule, _target, node, _opts) when not is_nil(node),
    do: {:error, :model_busy}

  defp unavailable_schedule(schedule, target, nil, opts) do
    capacity_target = capacity_target(target)

    case unprobed_unmanaged_input(capacity_target, opts) do
      {:ok, input} -> authorize_unprobed_unmanaged(schedule, capacity_target, input, opts)
      {:error, _reason} -> {:error, :model_busy}
    end
  end

  defp authorize_unprobed_unmanaged(schedule, capacity_target, input, opts) do
    authority = Keyword.get(opts, :dispatch_capacity_authority, AllocationAuthority)
    result = safe_unmanaged_evaluation(authority, input)

    if Consumer.authorized?(result) do
      provider = fn -> unprobed_unmanaged_input_or_nil(capacity_target, opts) end

      authorized_schedule =
        schedule
        |> Map.put(:queue_lane_capacity, result.available_slots)
        |> Map.put(:dispatch_capacity_input, input)
        |> Map.put(:dispatch_capacity_acquisition_input_provider, provider)
        |> Map.put(:dispatch_capacity_input_provider, provider)
        |> Map.put(:dispatch_capacity_evaluation, result)
        |> Consumer.put_authority(opts)

      {:ok, authorized_schedule}
    else
      {:error, :model_busy}
    end
  end

  defp safe_unmanaged_evaluation(authority, input) do
    evaluate_dispatch_capacity(authority, nil, input)
  catch
    :exit, _reason -> nil
  end

  defp unprobed_unmanaged_input_or_nil(capacity_target, opts) do
    case unprobed_unmanaged_input(capacity_target, opts) do
      {:ok, input} -> input
      {:error, _reason} -> nil
    end
  end

  defp unprobed_unmanaged_input(capacity_target, opts) do
    input_opts = [placement_capacity: :not_applicable, now: DateTime.utc_now()]

    input_opts =
      case Keyword.fetch(opts, :controller_mode) do
        {:ok, controller_mode} -> Keyword.put(input_opts, :controller_mode, controller_mode)
        :error -> input_opts
      end

    Authorization.unmanaged_input(capacity_target, %{}, input_opts)
  end

  defp capacity_target(target) do
    normalized = Target.normalize(target)

    if normalized.metadata == %{} and Inference.static_runtime_target?(normalized) do
      %{normalized | metadata: %{capacity_management_class: :unmanaged_compatibility}}
    else
      normalized
    end
  end

  defp put_target(schedule, %Target{transport: :grpc_compat, address: address}),
    do: Map.put(schedule, :runtime_client_target, address)

  defp put_target(schedule, %Target{} = target),
    do: Map.put(schedule, :runtime_endpoint_target, target)

  defp put_target(schedule, target), do: Map.put(schedule, :runtime_client_target, target)

  defp model_placement_capacity_for(
         %Observation{} = observation,
         %CanonicalRequest.ModelRef{} = model_ref
       ) do
    if model_loaded?(observation, model_ref) do
      Observation.placement_capacity_for(observation, runtime_model_ref(model_ref))
    else
      :not_applicable
    end
  end

  defp model_placement_capacity_for(response, %CanonicalRequest.ModelRef{} = model_ref) do
    missing = if model_loaded?(response, model_ref), do: :unknown, else: :not_applicable
    matching_placement_capacity(response, model_ref, missing)
  end

  defp post_load_placement_capacity_for(
         %Observation{} = observation,
         %CanonicalRequest.ModelRef{} = model_ref
       ),
       do: Observation.placement_capacity_for(observation, runtime_model_ref(model_ref))

  defp post_load_placement_capacity_for(response, %CanonicalRequest.ModelRef{} = model_ref) do
    matching_placement_capacity(response, model_ref, :unknown)
  end

  defp runtime_model_ref(%CanonicalRequest.ModelRef{} = model_ref),
    do: ModelRef.new!(model_ref.model_id, model_ref.version)

  defp matching_placement_capacity(response, model_ref, missing) do
    response
    |> response_list(:runtime_model_placements)
    |> matching_model_placements(model_ref)
    |> case do
      [] -> missing
      [placement] -> valid_model_placement_capacity(placement)
      _ambiguous -> :unknown
    end
  end

  defp response_list(response, key) do
    case Map.get(response, key) || Map.get(response, to_string(key)) do
      list when is_list(list) -> list
      _other -> []
    end
  end

  defp matching_model_placements(placements, model_ref) when is_list(placements),
    do: Enum.filter(placements, &model_placement_matches?(&1, model_ref))

  defp model_loaded?(%Observation{} = observation, model_ref) do
    Observation.loaded_placement(observation, runtime_model_ref(model_ref)) != nil
  end

  defp model_loaded?(response, model_ref) do
    response
    |> response_list(:loaded_models)
    |> Enum.any?(&model_reference_matches?(&1, model_ref))
  end

  defp model_placement_matches?(placement, model_ref) when is_map(placement) do
    placement
    |> placement_value(:model_ref)
    |> model_reference_matches?(model_ref)
  end

  defp model_placement_matches?(_placement, _model_ref), do: false

  defp model_reference_matches?(reference, model_ref) when is_map(reference) do
    case reference do
      %{model_id: model_id, version: version}
      when is_binary(model_id) and is_binary(version) ->
        model_id == model_ref.model_id and version == model_ref.version

      %{"model_id" => model_id, "version" => version}
      when is_binary(model_id) and is_binary(version) ->
        model_id == model_ref.model_id and version == model_ref.version

      _other ->
        false
    end
  end

  defp model_reference_matches?(_reference, _model_ref), do: false

  defp valid_model_placement_capacity(placement) when is_map(placement) do
    active_request_count = placement_value(placement, :active_request_count)
    max_concurrency = placement_value(placement, :max_concurrency)

    if is_integer(active_request_count) and active_request_count >= 0 and
         is_integer(max_concurrency) and max_concurrency > 0 do
      {:valid, active_request_count, max_concurrency}
    else
      :unknown
    end
  end

  defp valid_model_placement_capacity(_placement), do: :unknown

  defp placement_value(placement, key) do
    Map.get(placement, key, Map.get(placement, to_string(key)))
  end
end
