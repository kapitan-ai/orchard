defmodule Orchard.DispatchCapacity.Authorization do
  @moduledoc """
  Assembles the Controller-owned facts used to authorize dispatch capacity.

  Production inputs are built from durable authority, policy, inventory, and
  capacity evidence. Unmanaged inputs require an explicit Controller-owned
  target classification and a successful live observation.
  """

  require Logger

  alias Orchard.DispatchCapacity
  alias Orchard.DispatchCapacity.{Authority, CapacityEvidence, ManagementClassifier, Policy}
  alias Orchard.DispatchCapacity.Evaluator.Input
  alias Orchard.DispatchCapacity.ManagementClassifier.Input, as: ClassificationInput
  alias Orchard.Nodes
  alias Orchard.Nodes.Node
  alias Orchard.RuntimeEndpoint.{Observation, PlacementCapacity, Target}

  @admitted_states [:admitted, :active, :cordoned, :draining, :maintenance, :decommissioning]

  @type error_reason ::
          :dispatch_capacity_facts_unavailable
          | :dispatch_capacity_management_class_missing
          | :dispatch_capacity_node_not_found

  @doc "Builds a strict production-managed input for one persisted Node."
  @spec input(Node.t(), keyword()) :: {:ok, Input.t()} | {:error, error_reason()}
  def input(%Node{} = node, opts \\ []) do
    authority = option(opts, :authority, &DispatchCapacity.get_authority/0)
    policy = option(opts, :policy, fn -> DispatchCapacity.get_policy(node.id) end)
    evidence = option(opts, :evidence, fn -> DispatchCapacity.get_capacity_evidence(node.id) end)

    {:ok, from_facts(node, authority, policy, evidence, opts)}
  rescue
    error -> facts_unavailable(error)
  catch
    kind, reason -> facts_unavailable({kind, reason})
  end

  @doc "Reloads one Node and its Controller-owned capacity facts."
  @spec input_for_node(Ecto.UUID.t(), keyword()) :: {:ok, Input.t()} | {:error, error_reason()}
  def input_for_node(node_id, opts \\ []) do
    node_fetcher = Keyword.get(opts, :node_fetcher, &Nodes.fetch_node/1)

    case node_fetcher.(node_id) do
      {:ok, %Node{} = node} -> input(node, opts)
      _missing -> {:error, :dispatch_capacity_node_not_found}
    end
  rescue
    error -> facts_unavailable(error)
  catch
    kind, reason -> facts_unavailable({kind, reason})
  end

  @doc "Reloads one Node while using capacity facts from its current live observation."
  @spec input_for_node_observation(Ecto.UUID.t(), Observation.t() | map(), keyword()) ::
          {:ok, Input.t()} | {:error, error_reason()}
  def input_for_node_observation(node_id, observation, opts \\ []) do
    node_fetcher = Keyword.get(opts, :node_fetcher, &Nodes.fetch_node/1)

    case node_fetcher.(node_id) do
      {:ok, %Node{} = node} -> input_for_observation(node, observation, opts)
      _missing -> {:error, :dispatch_capacity_node_not_found}
    end
  rescue
    error -> facts_unavailable(error)
  catch
    kind, reason -> facts_unavailable({kind, reason})
  end

  @doc "Uses one already-loaded Node with capacity facts from its current live observation."
  @spec input_for_observation(Node.t(), Observation.t() | map(), keyword()) ::
          {:ok, Input.t()} | {:error, error_reason()}
  def input_for_observation(%Node{} = node, observation, opts \\ []) do
    evidence = option(opts, :evidence, fn -> DispatchCapacity.get_capacity_evidence(node.id) end)
    minimum_observed_at = Keyword.get(opts, :minimum_evidence_observed_at)
    now = Keyword.get_lazy(opts, :now, &utc_now/0)
    freshness_threshold_ms = Keyword.get(opts, :freshness_threshold_ms, freshness_threshold_ms())

    if observation_identity_matches?(node, observation) and
         authenticated_evidence_current?(evidence, minimum_observed_at) and
         authenticated_evidence_fresh?(evidence, now, freshness_threshold_ms) do
      authorized_observation_input(
        node,
        observation,
        evidence,
        opts,
        now,
        freshness_threshold_ms
      )
    else
      {:error, :dispatch_capacity_facts_unavailable}
    end
  rescue
    error -> facts_unavailable(error)
  catch
    kind, reason -> facts_unavailable({kind, reason})
  end

  @doc "Builds a mode-valid explicitly unmanaged input from one live observation."
  @spec unmanaged_input(Target.t() | keyword() | map(), map() | struct(), keyword()) ::
          {:ok, Input.t()} | {:error, error_reason()}
  def unmanaged_input(target, observation, opts \\ []) do
    target = Target.normalize(target)

    with {:ok, classification} <- classify_unmanaged_target(target, opts) do
      now = Keyword.get_lazy(opts, :now, &utc_now/0)

      freshness_threshold_ms =
        Keyword.get(opts, :freshness_threshold_ms, freshness_threshold_ms())

      observed_at = observation_time(observation, now)

      {:ok,
       %Input{
         authority_phase: :invalid,
         policy_presence: :missing,
         policy_state: :missing,
         management_classification: {:ok, classification},
         trusted_identity?: true,
         lifecycle_state: :active,
         health: observation_health(observation),
         heartbeat_fresh?: true,
         capacity_observation_fresh?: fresh?(observed_at, now, freshness_threshold_ms),
         observation_time: observed_at,
         runtime_concurrency_limit: runtime_limit(observation),
         aggregate_active_count: active_count(observation),
         controller_dispatch_ceiling: :missing,
         controller_accounted_allocation: 0,
         placement_capacity:
           normalize_placement(Keyword.get(opts, :placement_capacity, :not_applicable)),
         temporary_legacy_claim_count: 0,
         pool_eligible?: Keyword.get(opts, :pool_eligible?, true),
         format_eligible?: Keyword.get(opts, :format_eligible?, true),
         memory_eligible?: Keyword.get(opts, :memory_eligible?, true),
         breaker_eligible?: Keyword.get(opts, :breaker_eligible?, true)
       }}
    end
  end

  @doc "Classifies one explicitly configured unmanaged Runtime Endpoint target."
  @spec classify_unmanaged_target(Target.t() | keyword() | map(), keyword()) ::
          {:ok, :unmanaged_source_development | :unmanaged_compatibility}
          | {:error, :dispatch_capacity_management_class_missing}
  def classify_unmanaged_target(target, opts \\ []) do
    target
    |> Target.normalize()
    |> unmanaged_classification(opts)
  end

  @doc "Normalizes already-read Controller facts into one evaluator input."
  @spec from_facts(
          Node.t(),
          Authority.t() | nil,
          Policy.t() | nil,
          CapacityEvidence.t() | nil,
          keyword()
        ) ::
          Input.t()
  def from_facts(%Node{} = node, authority, policy, evidence, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &utc_now/0)
    freshness_threshold_ms = Keyword.get(opts, :freshness_threshold_ms, freshness_threshold_ms())

    %Input{
      authority_phase: authority_phase(authority),
      policy_presence: policy_presence(policy),
      policy_state: policy_state(policy),
      management_classification:
        Keyword.get(opts, :management_classification, {:ok, :production_managed}),
      trusted_identity?: Keyword.get(opts, :trusted_identity?, trusted_identity?(node, evidence)),
      lifecycle_state: node.state,
      health: Keyword.get(opts, :health, node.health),
      heartbeat_fresh?: fresh?(node.last_heartbeat_at, now, freshness_threshold_ms),
      capacity_observation_fresh?:
        fresh?(evidence_observed_at(evidence), now, freshness_threshold_ms),
      observation_time: evidence_observed_at(evidence),
      runtime_concurrency_limit: runtime_limit(evidence),
      aggregate_active_count: active_count(evidence),
      controller_dispatch_ceiling: controller_ceiling(policy),
      controller_accounted_allocation: Keyword.get(opts, :controller_accounted_allocation, 0),
      placement_capacity:
        normalize_placement(Keyword.get(opts, :placement_capacity, :not_applicable)),
      temporary_legacy_claim_count: Keyword.get(opts, :temporary_legacy_claim_count, 0),
      pool_eligible?: Keyword.get(opts, :pool_eligible?, true),
      format_eligible?: Keyword.get(opts, :format_eligible?, true),
      memory_eligible?: Keyword.get(opts, :memory_eligible?, true),
      breaker_eligible?: Keyword.get(opts, :breaker_eligible?, true)
    }
  end

  defp unmanaged_classification(%Target{} = target, opts) do
    declared_classes = declared_classes(target)

    classification =
      %ClassificationInput{
        target_reference: target.id,
        inventory_resolution: :not_admitted,
        controller_mode: Keyword.get(opts, :controller_mode, controller_mode()),
        declared_classes: declared_classes,
        compatibility_enabled?: :unmanaged_compatibility in declared_classes
      }
      |> ManagementClassifier.classify()

    case classification do
      {:ok, class} ->
        {:ok, class}

      {:error, :runtime_endpoint_management_class_missing} ->
        {:error, :dispatch_capacity_management_class_missing}

      {:error, _invalid} ->
        {:error, :dispatch_capacity_management_class_missing}
    end
  end

  defp declared_classes(%Target{metadata: metadata}) do
    case metadata_value(metadata, :capacity_management_class) do
      class when class in [:unmanaged_source_development, "unmanaged_source_development"] ->
        [:unmanaged_source_development]

      class when class in [:unmanaged_compatibility, "unmanaged_compatibility"] ->
        [:unmanaged_compatibility]

      _other ->
        if metadata_value(metadata, :source_dev) == true,
          do: [:unmanaged_source_development],
          else: []
    end
  end

  defp controller_mode do
    if Code.ensure_loaded?(Mix) and Mix.env() != :prod,
      do: :source_development,
      else: :production
  end

  defp authority_phase(%Authority{enforcement_phase: phase}), do: phase
  defp authority_phase(_authority), do: :invalid

  defp policy_presence(%Policy{}), do: :present
  defp policy_presence(_policy), do: :missing

  defp policy_state(%Policy{policy_state: state}), do: state
  defp policy_state(_policy), do: :missing

  defp controller_ceiling(%Policy{
         policy_state: :shadow_legacy,
         controller_dispatch_ceiling: nil
       }),
       do: :missing

  defp controller_ceiling(%Policy{controller_dispatch_ceiling: value})
       when is_integer(value) and value >= 0,
       do: {:valid, value}

  defp controller_ceiling(%Policy{controller_dispatch_ceiling: nil}), do: :missing
  defp controller_ceiling(%Policy{}), do: :invalid
  defp controller_ceiling(_policy), do: :missing

  defp runtime_limit(%CapacityEvidence{validity: :valid, runtime_concurrency_limit: value})
       when is_integer(value) and value > 0,
       do: {:valid, value}

  defp runtime_limit(%CapacityEvidence{validity: :missing, runtime_concurrency_limit: nil}),
    do: :missing

  defp runtime_limit(%CapacityEvidence{validity: :missing, runtime_concurrency_limit: value})
       when is_integer(value) and value > 0,
       do: {:valid, value}

  defp runtime_limit(%CapacityEvidence{}), do: :invalid

  defp runtime_limit(observation) when is_map(observation) do
    case observation_capacity_value(observation, :runtime_concurrency_limit) do
      value when is_integer(value) and value > 0 -> {:valid, value}
      nil -> :missing
      _invalid -> :invalid
    end
  end

  defp runtime_limit(_evidence), do: :missing

  defp active_count(%CapacityEvidence{validity: :valid, active_request_count: value})
       when is_integer(value) and value >= 0,
       do: {:valid, value}

  defp active_count(%CapacityEvidence{validity: :missing, active_request_count: nil}),
    do: :missing

  defp active_count(%CapacityEvidence{validity: :missing, active_request_count: value})
       when is_integer(value) and value >= 0,
       do: {:valid, value}

  defp active_count(%CapacityEvidence{}), do: :invalid

  defp active_count(observation) when is_map(observation) do
    case observation_capacity_value(observation, :active_request_count) do
      value when is_integer(value) and value >= 0 -> {:valid, value}
      nil -> :missing
      _invalid -> :invalid
    end
  end

  defp active_count(_evidence), do: :missing

  defp observation_capacity_value(%Observation{aggregate_capacity_evidence: evidence}, key),
    do: metadata_value(evidence, key)

  defp observation_capacity_value(observation, :runtime_concurrency_limit) do
    map_value(observation, :aggregate_max_concurrency) || map_value(observation, :max_concurrency)
  end

  defp observation_capacity_value(observation, :active_request_count) do
    map_value(observation, :aggregate_active_request_count) ||
      map_value(observation, :active_request_count)
  end

  defp evidence_observed_at(%CapacityEvidence{observed_at: observed_at}), do: observed_at
  defp evidence_observed_at(_evidence), do: nil

  defp observation_time(%Observation{observed_at: %DateTime{} = observed_at}, _now),
    do: observed_at

  defp observation_time(_observation, now), do: now

  defp observation_health(%Observation{availability: :degraded}), do: :degraded

  defp observation_health(%Observation{availability: availability})
       when availability in [:unavailable, :unknown],
       do: :unhealthy

  defp observation_health(%Observation{}), do: :healthy

  defp observation_health(observation) when is_map(observation) do
    case map_value(observation, :runtime_health) do
      %{ready: false} -> :unhealthy
      %{"ready" => false} -> :unhealthy
      _health -> :healthy
    end
  end

  defp authoritative_health(:healthy, observation_health), do: observation_health
  defp authoritative_health(node_health, _observation_health), do: node_health

  defp normalize_placement(%PlacementCapacity{
         status: :known,
         active_request_count: active,
         max_concurrency: maximum
       }),
       do: {:valid, active, maximum}

  defp normalize_placement(%PlacementCapacity{status: :unknown}), do: :unknown
  defp normalize_placement(%PlacementCapacity{}), do: :invalid
  defp normalize_placement(value), do: value

  defp fresh?(%DateTime{} = observed_at, %DateTime{} = now, threshold_ms)
       when is_integer(threshold_ms) and threshold_ms > 0 do
    age_ms = DateTime.diff(now, observed_at, :millisecond)
    age_ms >= 0 and age_ms <= threshold_ms
  end

  defp fresh?(_observed_at, _now, _threshold_ms), do: false

  defp trusted_identity?(%Node{state: state}, %CapacityEvidence{}), do: state in @admitted_states
  defp trusted_identity?(_node, _evidence), do: false

  defp authenticated_evidence_current?(
         %CapacityEvidence{observed_at: %DateTime{} = observed_at},
         %DateTime{} = minimum_observed_at
       ) do
    DateTime.compare(observed_at, minimum_observed_at) in [:eq, :gt]
  end

  defp authenticated_evidence_current?(%CapacityEvidence{}, nil), do: true

  defp authenticated_evidence_current?(_evidence, _minimum_observed_at), do: false

  defp authenticated_evidence_fresh?(
         %CapacityEvidence{observed_at: %DateTime{} = observed_at},
         %DateTime{} = now,
         freshness_threshold_ms
       ),
       do: fresh?(observed_at, now, freshness_threshold_ms)

  defp authenticated_evidence_fresh?(_evidence, _now, _freshness_threshold_ms), do: false

  defp authorized_observation_input(
         node,
         observation,
         evidence,
         opts,
         now,
         freshness_threshold_ms
       ) do
    opts =
      opts
      |> Keyword.put(:evidence, evidence)
      |> Keyword.put(:health, authoritative_health(node.health, observation_health(observation)))
      |> Keyword.put(:trusted_identity?, true)

    case input(node, opts) do
      {:ok, input} ->
        {:ok, put_live_capacity(input, observation, now, freshness_threshold_ms)}

      {:error, _reason} = error ->
        error
    end
  end

  defp put_live_capacity(input, observation, now, freshness_threshold_ms) do
    observed_at = observation_time(observation, now)

    %{
      input
      | runtime_concurrency_limit: runtime_limit(observation),
        aggregate_active_count: active_count(observation),
        capacity_observation_fresh?: fresh?(observed_at, now, freshness_threshold_ms),
        observation_time: observed_at
    }
  end

  defp observation_identity_matches?(%Node{id: node_id}, observation) do
    with {:ok, normalized_node_id} <- Ecto.UUID.cast(node_id),
         {:ok, normalized_observed_id} <- Ecto.UUID.cast(observation_node_id(observation)) do
      normalized_node_id == normalized_observed_id
    else
      _invalid -> false
    end
  end

  defp observation_node_id(%Observation{} = observation), do: Observation.node_id(observation)

  defp observation_node_id(observation) when is_map(observation) do
    metadata = map_value(observation, :node_metadata) || map_value(observation, :metadata) || %{}
    map_value(metadata, :node_id)
  end

  defp observation_node_id(_observation), do: nil

  defp freshness_threshold_ms, do: Orchard.Inference.node_freshness_threshold_ms()

  defp option(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> default.()
    end
  end

  defp facts_unavailable(cause) do
    Logger.warning("Dispatch-capacity fact assembly failed: #{inspect(cause)}")
    {:error, :dispatch_capacity_facts_unavailable}
  end

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp metadata_value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
