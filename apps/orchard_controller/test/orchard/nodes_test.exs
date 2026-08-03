defmodule Orchard.NodesTest.ExitingQueueManager do
  def refresh_node_capacity_sources(_observation) do
    exit(
      {:noproc,
       {GenServer, :call, [Orchard.Inference.QueueManager, :refresh_node_capacity_sources, 5_000]}}
    )
  end

  def clear_capacity_sources(_sources, _opts) do
    exit(
      {:noproc,
       {GenServer, :call, [Orchard.Inference.QueueManager, :clear_capacity_sources, 5_000]}}
    )
  end
end

defmodule Orchard.NodesTest.TransactionProbeQueueManager do
  def refresh_node_capacity_sources(_observation), do: :ok

  def clear_capacity_sources(sources, opts) do
    send(
      Process.get(:nodes_test_queue_probe_pid),
      {:queue_capacity_clear, sources, opts, Orchard.Repo.in_transaction?()}
    )

    :ok
  end
end

defmodule Orchard.NodesTest do
  use Orchard.DataCase, async: false

  import ExUnit.CaptureLog

  alias Orchard.DispatchCapacity
  alias Orchard.DispatchCapacity.Evaluator.Input
  alias Orchard.DispatchCapacity.Policy
  alias Orchard.Governance.AuditLog
  alias Orchard.Inference.QueueManager
  alias Orchard.Nodes
  alias Orchard.Nodes.{AdmissionCandidate, AdmissionDecision, Node}
  alias Orchard.RuntimeEndpoint.GrpcCompatibilityMapper
  alias Orchard.RuntimeEndpoint.{ModelRef, Observation, Placement, PlacementCapacity, Target}

  # -- Helpers --

  defp node_attrs(overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        hostname: "host-#{unique}.local",
        display_name: "node-#{unique}",
        advertise_addr: unique_advertise_addr(unique),
        rpc_port: 9444,
        state: :active,
        health: :healthy,
        capabilities: %{},
        tool_readiness: %{}
      },
      overrides
    )
  end

  defp unique_advertise_addr(unique) do
    second_octet = unique |> div(65_536) |> rem(256)
    third_octet = unique |> div(256) |> rem(256)
    fourth_octet = rem(unique, 254) + 1

    "10.#{second_octet}.#{third_octet}.#{fourth_octet}"
  end

  defp insert_node!(overrides) do
    attrs = node_attrs(overrides)

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_node_from_status!(target, status, overrides \\ %{}) do
    metadata = status_metadata(status)
    target = status_target(target)

    attrs =
      %{
        id: metadata_value(metadata, :node_id),
        hostname: metadata_value(metadata, :hostname),
        display_name: metadata_value(metadata, :display_name),
        advertise_addr: metadata_value(metadata, :listen_host),
        rpc_port: metadata_value(metadata, :listen_port),
        connect_host: Keyword.get(target, :host),
        connect_port: Keyword.get(target, :port),
        state: :active,
        health: :healthy,
        capabilities: %{},
        tool_readiness: %{}
      }
      |> Map.merge(overrides)

    node = Repo.get(Node, attrs.id) || insert_node!(attrs)
    ensure_legacy_capacity_policy!(node)
  end

  defp ensure_legacy_capacity_policy!(%Node{} = node) do
    case Repo.get(Policy, node.id) do
      %Policy{} ->
        node

      nil ->
        admitted_at = DateTime.utc_now()

        decision =
          %AdmissionDecision{}
          |> AdmissionDecision.changeset(%{
            node_id: node.id,
            decision: :admitted,
            actor_type: "system",
            actor_id: "nodes-test-legacy-policy",
            observed_identity: %{},
            metadata: %{},
            decided_at: admitted_at
          })
          |> Repo.insert!()

        %Policy{
          node_id: node.id,
          admission_decision_id: decision.id,
          policy_state: :shadow_legacy,
          controller_dispatch_ceiling: nil,
          legacy_admitted_at: admitted_at,
          version: 1
        }
        |> Repo.insert!()

        node
    end
  end

  defp status_metadata(%Observation{metadata: metadata}), do: metadata
  defp status_metadata(%{node_metadata: metadata}), do: metadata

  defp status_target(%Target{transport: :grpc_compat, address: address}), do: address
  defp status_target(%Target{transport: :beam}), do: []
  defp status_target(target), do: target

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp make_target(host, port), do: [host: host, port: port]

  defp observe_status(target, status, observed_at, opts \\ []) do
    opts = Keyword.put_new(opts, :dispatch_capacity_input, capacity_input(status, observed_at))
    Nodes.observe_status(target, status, observed_at, opts)
  end

  defp capacity_input(status, observed_at) do
    %Input{
      authority_phase: :pre_cutover,
      policy_presence: :present,
      policy_state: :shadow_legacy,
      management_classification: {:ok, :production_managed},
      trusted_identity?: true,
      lifecycle_state: capacity_node_state(status),
      health: capacity_health(status),
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: observed_at,
      runtime_concurrency_limit: capacity_runtime_limit(status),
      aggregate_active_count: capacity_active_count(status),
      controller_dispatch_ceiling: :missing,
      controller_accounted_allocation: 0,
      placement_capacity: :not_applicable,
      temporary_legacy_claim_count: 0,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }
  end

  defp capacity_node_state(status) do
    with node_id when is_binary(node_id) <- capacity_node_id(status),
         {:ok, node_id} <- Ecto.UUID.cast(node_id),
         %Node{state: state} <- Repo.get(Node, node_id) do
      state
    else
      _missing_or_invalid -> :active
    end
  end

  defp capacity_node_id(%Observation{} = observation), do: Observation.node_id(observation)

  defp capacity_node_id(%{} = status) do
    metadata = Map.get(status, :node_metadata) || Map.get(status, "node_metadata") || %{}
    Map.get(metadata, :node_id) || Map.get(metadata, "node_id")
  end

  defp capacity_runtime_limit(%Observation{aggregate_capacity_evidence: evidence}),
    do: capacity_evidence(evidence, :runtime_concurrency_limit, &(&1 > 0))

  defp capacity_runtime_limit(status),
    do: capacity_evidence(status, :max_concurrency, &(&1 > 0))

  defp capacity_active_count(%Observation{aggregate_capacity_evidence: evidence}),
    do: capacity_evidence(evidence, :active_request_count, &(&1 >= 0))

  defp capacity_active_count(status),
    do: capacity_evidence(status, :active_request_count, &(&1 >= 0))

  defp capacity_evidence(values, key, valid?) do
    value = Map.get(values, key) || Map.get(values, Atom.to_string(key))

    cond do
      is_integer(value) and valid?.(value) -> {:valid, value}
      is_nil(value) -> :missing
      true -> :invalid
    end
  end

  defp capacity_health(%Observation{availability: :degraded}), do: :degraded

  defp capacity_health(%Observation{availability: availability})
       when availability in [:unavailable, :unknown],
       do: :unhealthy

  defp capacity_health(%Observation{}), do: :healthy

  defp capacity_health(status) do
    health = Map.get(status, :runtime_health) || Map.get(status, "runtime_health") || %{}
    ready = Map.get(health, :ready, Map.get(health, "ready"))
    code = Map.get(health, :health_code, Map.get(health, "health_code", ""))
    message = Map.get(health, :health_message, Map.get(health, "health_message", ""))

    cond do
      ready == false -> :unhealthy
      code not in [nil, ""] or message not in [nil, ""] -> :degraded
      true -> :healthy
    end
  end

  defp admission_opts do
    [actor_type: "service_account", actor_id: "admin-api-principal"]
  end

  defp admission_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        trust_evidence_ref: "registration-audit:#{Ecto.UUID.generate()}",
        pool_id: Ecto.UUID.generate(),
        routing_policy_id: Ecto.UUID.generate(),
        capacity_policy_reason: "approved for test capacity"
      },
      overrides
    )
  end

  defp tool_ref(name, version), do: "tool://#{name}@#{version}"

  defp hosted_tool_capability(name, version, adapter_kind \\ "mcp") do
    %{
      "ref" => tool_ref(name, version),
      "name" => name,
      "version" => version,
      "adapter_kind" => adapter_kind
    }
  end

  defp make_status_response(meta_overrides), do: make_status_response(meta_overrides, nil)

  defp make_status_response(meta_overrides, health_overrides) do
    unique = System.unique_integer([:positive])

    metadata =
      Map.merge(
        %{
          node_id: Ecto.UUID.generate(),
          display_name: "node-#{unique}",
          hostname: "host-#{unique}.local",
          agent_version: "0.1.0",
          listen_host: "10.0.0.#{rem(unique, 255)}",
          listen_port: 9444,
          worker_backend: "mlx"
        },
        meta_overrides
      )

    runtime_health =
      case health_overrides do
        nil -> nil
        overrides -> Map.merge(%{ready: true, health_code: "", health_message: ""}, overrides)
      end

    %{node_metadata: metadata, runtime_health: runtime_health}
  end

  defp placement_status(host, model_id, opts) do
    version = Keyword.get(opts, :version, "v1")
    max_concurrency = Keyword.fetch!(opts, :max_concurrency)

    placement =
      %{
        model_ref: %{model_id: model_id, version: version},
        active_request_count: 0,
        max_concurrency: max_concurrency
      }
      |> maybe_put_placement_state(opts)

    make_status_response(%{listen_host: host, listen_port: 9444})
    |> Map.put(:runtime_model_placements, [placement])
  end

  defp maybe_put_placement_state(placement, opts) do
    case Keyword.fetch(opts, :placement_state) do
      {:ok, placement_state} -> Map.put(placement, :placement_state, placement_state)
      :error -> placement
    end
  end

  defp queue_admission_request(public_id, model_id, version \\ "v1") do
    %{
      request_id: Ecto.UUID.generate(),
      public_id: public_id,
      tenant_id: Ecto.UUID.generate(),
      model_id: model_id,
      version: version,
      caller_pid: self()
    }
  end

  defp queue_config(overrides) do
    Keyword.merge(
      [
        enabled: true,
        capacity: 1,
        max_queued_per_tenant: 32,
        max_wait_ms: 1_000
      ],
      overrides
    )
  end

  defp start_holding_awaiter(ticket, tag) do
    parent = self()

    spawn(fn ->
      result = QueueManager.await(ticket)
      send(parent, {tag, result})

      receive do
        :stop -> :ok
      after
        5_000 -> :ok
      end
    end)
  end

  defp put_ticket_awaiter(ticket, tag) do
    parent = self()
    monitor_ref = Process.monitor(parent)

    :sys.replace_state(QueueManager, fn state ->
      entry =
        state.entries
        |> Map.fetch!(ticket.ticket_ref)
        |> Map.put(:await_from, {parent, tag})
        |> Map.put(:awaiter_monitor_ref, monitor_ref)

      %{
        state
        | entries: Map.put(state.entries, ticket.ticket_ref, entry),
          monitors: Map.put(state.monitors, monitor_ref, {:awaiter, ticket.ticket_ref})
      }
    end)
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp queue_entry_awaiting?(ticket) do
    QueueManager
    |> :sys.get_state()
    |> Map.get(:entries)
    |> Map.get(ticket.ticket_ref)
    |> case do
      %{await_from: await_from} when await_from != nil -> true
      _other -> false
    end
  end

  defp put_queue_manager_impl(module) do
    inference = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.put(inference, :queue_manager_impl, module)
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, inference)
    end)
  end

  # -- Schema validation --

  describe "Node schema" do
    test "valid attrs produce valid changeset" do
      changeset = Node.changeset(%Node{}, node_attrs())
      assert changeset.valid?
    end

    test "required fields" do
      changeset = Node.changeset(%Node{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:hostname]
      assert errors[:display_name]
      assert errors[:advertise_addr]
      assert errors[:rpc_port]
      assert errors[:state]
      assert errors[:health]
    end

    test "invalid rpc_port" do
      changeset = Node.changeset(%Node{}, node_attrs(%{rpc_port: 0}))
      refute changeset.valid?
      assert errors_on(changeset)[:rpc_port]

      changeset = Node.changeset(%Node{}, node_attrs(%{rpc_port: 70_000}))
      refute changeset.valid?
      assert errors_on(changeset)[:rpc_port]
    end

    test "invalid connect_port" do
      changeset = Node.changeset(%Node{}, node_attrs(%{connect_port: 0}))
      refute changeset.valid?
      assert errors_on(changeset)[:connect_port]

      changeset = Node.changeset(%Node{}, node_attrs(%{connect_port: 70_000}))
      refute changeset.valid?
      assert errors_on(changeset)[:connect_port]
    end

    test "connect target fields must be populated as a pair" do
      changeset = Node.changeset(%Node{}, node_attrs(%{connect_host: "10.0.0.1"}))
      refute changeset.valid?
      assert errors_on(changeset)[:connect_port]

      changeset = Node.changeset(%Node{}, node_attrs(%{connect_port: 9444}))
      refute changeset.valid?
      assert errors_on(changeset)[:connect_host]
    end

    test "requires tool_readiness to be a map" do
      changeset = Node.changeset(%Node{}, node_attrs(%{tool_readiness: nil}))
      refute changeset.valid?
      assert errors_on(changeset)[:tool_readiness]

      changeset = Node.changeset(%Node{}, node_attrs(%{tool_readiness: "bad"}))
      refute changeset.valid?
      assert errors_on(changeset)[:tool_readiness]
    end

    test "rejects tool_readiness entries for refs missing from hosted_tools" do
      changeset =
        Node.changeset(
          %Node{},
          node_attrs(%{
            capabilities: %{"hosted_tools" => []},
            tool_readiness: %{
              tool_ref("lookup_docs", "2026-04-11") => %{
                "ready" => true,
                "status_code" => "ok",
                "status_message" => "ready"
              }
            }
          })
        )

      refute changeset.valid?
      assert errors_on(changeset)[:tool_readiness]
    end

    test "rejects tool_readiness entries with invalid payload types" do
      ref = tool_ref("lookup_docs", "2026-04-11")

      changeset =
        Node.changeset(
          %Node{},
          node_attrs(%{
            capabilities: %{
              "hosted_tools" => [hosted_tool_capability("lookup_docs", "2026-04-11")]
            },
            tool_readiness: %{
              ref => %{"ready" => "yes", "status_code" => "ok", "status_message" => "ready"}
            }
          })
        )

      refute changeset.valid?
      assert errors_on(changeset)[:tool_readiness]
    end

    test "accepts tool_readiness entries that match hosted_tools" do
      ref = tool_ref("lookup_docs", "2026-04-11")

      changeset =
        Node.changeset(
          %Node{},
          node_attrs(%{
            capabilities: %{
              "hosted_tools" => [hosted_tool_capability("lookup_docs", "2026-04-11")]
            },
            tool_readiness: %{
              ref => %{ready: true, status_code: "ok", status_message: "ready"}
            }
          })
        )

      assert changeset.valid?
    end

    test "enum helpers" do
      assert :active in Node.states()
      assert :provisioned in Node.states()
      assert length(Node.states()) == 9

      assert :healthy in Node.health_values()
      assert :unreachable in Node.health_values()
      assert length(Node.health_values()) == 4
    end
  end

  # -- list_nodes/0 --

  describe "list_nodes/0" do
    test "returns empty list when no nodes" do
      assert Nodes.list_nodes() == []
    end

    test "returns nodes ordered by display_name" do
      insert_node!(%{display_name: "zeta"})
      insert_node!(%{display_name: "alpha"})
      insert_node!(%{display_name: "middle"})

      names = Nodes.list_nodes() |> Enum.map(& &1.display_name)
      assert names == ["alpha", "middle", "zeta"]
    end
  end

  # -- summary/0 --

  describe "summary/0" do
    test "returns zero-filled summary on empty DB" do
      summary = Nodes.summary()
      assert summary.total == 0
      assert summary.by_state.active == 0
      assert summary.by_state.provisioned == 0
      assert summary.by_health.healthy == 0
      assert summary.by_health.unreachable == 0
      assert map_size(summary.by_state) == 9
      assert map_size(summary.by_health) == 4
    end

    test "counts by state and health" do
      insert_node!(%{state: :active, health: :healthy})
      insert_node!(%{state: :active, health: :degraded})
      insert_node!(%{state: :cordoned, health: :unhealthy})

      summary = Nodes.summary()
      assert summary.total == 3
      assert summary.by_state.active == 2
      assert summary.by_state.cordoned == 1
      assert summary.by_state.provisioned == 0
      assert summary.by_health.healthy == 1
      assert summary.by_health.degraded == 1
      assert summary.by_health.unhealthy == 1
    end
  end

  # -- lookup_by_target/1 --

  describe "lookup_by_target/1" do
    test "returns node for exact target match" do
      node = insert_node!(%{advertise_addr: "10.0.0.5", rpc_port: 9444})
      found = Nodes.lookup_by_target(host: "10.0.0.5", port: 9444)
      assert found.id == node.id
    end

    test "returns node for persisted connect target before advertise target" do
      legacy =
        insert_node!(%{
          advertise_addr: "100.90.207.78",
          rpc_port: 50_071,
          display_name: "legacy-target"
        })

      node =
        insert_node!(%{
          advertise_addr: "0.0.0.0",
          rpc_port: 9444,
          connect_host: "100.90.207.78",
          connect_port: 50_071
        })

      found = Nodes.lookup_by_target(host: "100.90.207.78", port: 50_071)
      assert found.id == node.id
      refute found.id == legacy.id
    end

    test "returns nil for no match" do
      assert Nodes.lookup_by_target(host: "10.0.0.99", port: 9444) == nil
    end

    test "returns nil for malformed target" do
      assert Nodes.lookup_by_target(host: "", port: 9444) == nil
      assert Nodes.lookup_by_target(host: "10.0.0.1", port: 0) == nil
      assert Nodes.lookup_by_target([]) == nil
    end
  end

  # -- admission candidates --

  describe "admission candidates" do
    test "SPEC.md §4.2 and §7.5.4 first observation creates candidate, not active node" do
      node_id = Ecto.UUID.generate()
      target = make_target("10.0.0.1", 9444)
      observed_at = DateTime.utc_now()

      status =
        make_status_response(%{
          node_id: node_id,
          display_name: "candidate-node",
          hostname: "candidate-host.local",
          listen_host: "10.0.0.1",
          listen_port: 9444
        })

      assert :noop = observe_status(target, status, observed_at)
      assert Repo.get(Node, node_id) == nil

      assert [%AdmissionCandidate{} = candidate] = Nodes.list_admission_candidates()
      assert candidate.source == :runtime_endpoint_observation
      assert candidate.admission_category == :pending_observed
      assert candidate.observed_identity["claimed_node_id"] == node_id
      assert candidate.observed_identity["display_name"] == "candidate-node"
      assert candidate.target_ref == "10.0.0.1:9444"
      assert candidate.endpoint_target == "10.0.0.1:9444"
      assert candidate.inventory["capabilities"]["supports_prompt_token_ids"] == false
      assert candidate.last_observed_at == DateTime.truncate(observed_at, :microsecond)
    end

    test "SPEC.md §4.2 duplicate observations reuse one observed candidate" do
      node_id = Ecto.UUID.generate()
      target = make_target("10.0.0.19", 9444)
      first_observed_at = DateTime.utc_now()
      second_observed_at = DateTime.add(first_observed_at, 1, :second)

      status =
        make_status_response(%{
          node_id: node_id,
          display_name: "duplicate-candidate-node",
          hostname: "duplicate-candidate.local",
          listen_host: "10.0.0.19",
          listen_port: 9444
        })

      assert :noop = observe_status(target, status, first_observed_at)
      assert :noop = observe_status(target, status, second_observed_at)

      assert [%AdmissionCandidate{} = candidate] = Nodes.list_admission_candidates()
      assert candidate.observed_identity["claimed_node_id"] == node_id
      assert candidate.admission_category == :pending_observed
      assert candidate.last_observed_at == DateTime.truncate(second_observed_at, :microsecond)
    end

    test "SPEC.md §4.2 stale duplicate observations preserve newer candidate evidence" do
      node_id = Ecto.UUID.generate()
      target = make_target("10.0.0.33", 9444)
      newer_observed_at = DateTime.utc_now()
      older_observed_at = DateTime.add(newer_observed_at, -30, :second)

      newer_status =
        make_status_response(%{
          node_id: node_id,
          display_name: "newer-candidate-node",
          hostname: "newer-candidate.local",
          listen_host: "10.0.0.33",
          listen_port: 9444,
          agent_version: "0.3.0"
        })

      older_status =
        make_status_response(%{
          node_id: node_id,
          display_name: "older-candidate-node",
          hostname: "older-candidate.local",
          listen_host: "10.0.0.33",
          listen_port: 9444,
          agent_version: "0.1.0"
        })

      equal_timestamp_status =
        make_status_response(%{
          node_id: node_id,
          display_name: "equal-candidate-node",
          hostname: "equal-candidate.local",
          listen_host: "10.0.0.33",
          listen_port: 9444,
          agent_version: "0.2.0"
        })

      assert :noop = observe_status(target, newer_status, newer_observed_at)
      assert :noop = observe_status(target, older_status, older_observed_at)
      assert :noop = observe_status(target, equal_timestamp_status, newer_observed_at)

      assert [%AdmissionCandidate{} = candidate] = Nodes.list_admission_candidates()
      assert candidate.observed_identity["claimed_node_id"] == node_id
      assert candidate.observed_identity["display_name"] == "newer-candidate-node"
      assert candidate.observed_identity["hostname"] == "newer-candidate.local"
      assert candidate.observed_identity["agent_version"] == "0.3.0"
      assert candidate.last_observed_at == DateTime.truncate(newer_observed_at, :microsecond)
    end

    test "SPEC.md §4.2 open observed candidate identity is unique in the database" do
      node_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      attrs = %{
        source: :runtime_endpoint_observation,
        admission_category: :pending_observed,
        observed_identity: %{"claimed_node_id" => node_id},
        target_ref: "10.0.0.20:9444",
        endpoint_transport: :grpc,
        endpoint_target: "10.0.0.20:9444",
        inventory: %{},
        compatibility_evidence: %{},
        last_observed_at: now
      }

      assert {:ok, _candidate} =
               %AdmissionCandidate{}
               |> AdmissionCandidate.changeset(attrs)
               |> Repo.insert()

      assert {:error, changeset} =
               %AdmissionCandidate{}
               |> AdmissionCandidate.changeset(attrs)
               |> Repo.insert()

      assert %{observed_identity: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, _candidate} =
               %AdmissionCandidate{}
               |> AdmissionCandidate.changeset(%{
                 attrs
                 | observed_identity: %{"claimed_node_id" => Ecto.UUID.generate()}
               })
               |> Repo.insert()
    end

    test "SPEC.md §4.2 multibyte observed metadata is UTF-8 safe and byte bounded" do
      node_id = Ecto.UUID.generate()
      target = make_target("10.0.0.24", 9444)
      multibyte = String.duplicate("界", 300)

      status =
        make_status_response(%{
          node_id: node_id,
          display_name: "utf8-candidate",
          hostname: "utf8-candidate.local",
          listen_host: "10.0.0.24",
          listen_port: 9444,
          agent_version: multibyte
        })
        |> put_in([:hosted_tool_capabilities], [
          hosted_tool_capability(multibyte, "2026-06-28", "mcp")
        ])

      assert :noop = observe_status(target, status, DateTime.utc_now())
      assert [%AdmissionCandidate{} = candidate] = Nodes.list_admission_candidates()

      agent_version = candidate.observed_identity["agent_version"]

      hosted_tool_name =
        candidate.inventory["capabilities"]["hosted_tools"] |> hd() |> Map.fetch!("name")

      assert String.valid?(agent_version)
      assert String.valid?(hosted_tool_name)
      assert byte_size(agent_version) <= 512
      assert byte_size(hosted_tool_name) <= 512
      assert agent_version != ""
      assert hosted_tool_name != ""
    end

    test "SPEC.md §4.2 observed candidate list snapshots mark count truncation" do
      node_id = Ecto.UUID.generate()
      target = make_target("10.0.0.25", 9444)

      tools =
        for index <- 1..41 do
          hosted_tool_capability("tool-#{index}", "2026-06-28", "mcp")
        end

      status =
        make_status_response(%{
          node_id: node_id,
          display_name: "truncated-list-candidate",
          hostname: "truncated-list-candidate.local",
          listen_host: "10.0.0.25",
          listen_port: 9444
        })
        |> Map.put(:hosted_tool_capabilities, tools)

      assert :noop = observe_status(target, status, DateTime.utc_now())
      assert [%AdmissionCandidate{} = candidate] = Nodes.list_admission_candidates()

      hosted_tools = candidate.inventory["capabilities"]["hosted_tools"]
      marker = List.last(hosted_tools)

      assert length(hosted_tools) == 40

      assert marker == %{
               "truncated" => true,
               "reason" => "entry_limit",
               "kind" => "list",
               "entry_limit" => 40,
               "original_count" => 41
             }

      refute Enum.any?(hosted_tools, &match?(%{"name" => "tool-41"}, &1))
    end

    test "SPEC.md §4.2 observed candidate list snapshots at count cap stay unmarked" do
      node_id = Ecto.UUID.generate()
      target = make_target("10.0.0.26", 9444)

      tools =
        for index <- 1..40 do
          hosted_tool_capability("complete-tool-#{index}", "2026-06-28", "mcp")
        end

      status =
        make_status_response(%{
          node_id: node_id,
          display_name: "complete-list-candidate",
          hostname: "complete-list-candidate.local",
          listen_host: "10.0.0.26",
          listen_port: 9444
        })
        |> Map.put(:hosted_tool_capabilities, tools)

      assert :noop = observe_status(target, status, DateTime.utc_now())
      assert [%AdmissionCandidate{} = candidate] = Nodes.list_admission_candidates()

      hosted_tools = candidate.inventory["capabilities"]["hosted_tools"]

      assert length(hosted_tools) == 40
      refute Enum.any?(hosted_tools, &Map.has_key?(&1, "truncated"))
    end

    test "SPEC.md §4.3 admission decision map snapshots mark count truncation" do
      target = make_target("10.0.0.27", 9444)

      status =
        make_status_response(%{
          display_name: "truncated-map-candidate",
          hostname: "truncated-map-candidate.local",
          listen_host: "10.0.0.27",
          listen_port: 9444
        })

      oversized_metadata =
        1..41
        |> Enum.map(fn index -> {"evidence_#{index}", "value-#{index}"} end)
        |> Map.new()

      assert :noop = observe_status(target, status, DateTime.utc_now())
      [candidate] = Nodes.list_admission_candidates()
      assert {:ok, rejected} = Nodes.reject_admission(candidate.id, %{reason: "needs review"})

      assert {:ok, cleared} =
               Nodes.clear_admission_rejection(rejected.candidate.id, oversized_metadata)

      marker = cleared.decision.metadata["__orchard_snapshot_truncation__"]

      assert map_size(cleared.decision.metadata) == 40

      assert marker == %{
               "truncated" => true,
               "reason" => "entry_limit",
               "kind" => "map",
               "entry_limit" => 40,
               "original_count" => 41
             }
    end

    test "SPEC.md §4.3 admission decision map snapshots at count cap stay unmarked" do
      target = make_target("10.0.0.28", 9444)

      status =
        make_status_response(%{
          display_name: "complete-map-candidate",
          hostname: "complete-map-candidate.local",
          listen_host: "10.0.0.28",
          listen_port: 9444
        })

      complete_metadata =
        1..40
        |> Enum.map(fn index -> {"evidence_#{index}", "value-#{index}"} end)
        |> Map.new()

      assert :noop = observe_status(target, status, DateTime.utc_now())
      [candidate] = Nodes.list_admission_candidates()
      assert {:ok, rejected} = Nodes.reject_admission(candidate.id, %{reason: "needs review"})

      assert {:ok, cleared} =
               Nodes.clear_admission_rejection(rejected.candidate.id, complete_metadata)

      assert map_size(cleared.decision.metadata) == 40
      refute Map.has_key?(cleared.decision.metadata, "__orchard_snapshot_truncation__")
    end

    test "SPEC.md §4.3 pending admission rejection is auditable and not decommissioning" do
      target = make_target("10.0.0.12", 9444)

      status =
        make_status_response(%{
          display_name: "reject-candidate",
          hostname: "reject-candidate.local",
          listen_host: "10.0.0.12",
          listen_port: 9444
        })

      assert :noop = observe_status(target, status, DateTime.utc_now())
      [candidate] = Nodes.list_admission_candidates()

      assert {:ok, result} =
               Nodes.reject_admission(
                 candidate.id,
                 %{reason: "identity not approved"},
                 actor_type: "operator",
                 actor_id: "admin@example.test"
               )

      assert result.candidate.admission_category == :rejected
      assert result.decision.decision == :rejected
      assert result.decision.reason == "identity not approved"
      assert result.decision.candidate_id == candidate.id
      assert result.decision.audit_log_id == result.audit_log.id
      assert %AuditLog{} = result.audit_log
      assert result.audit_log.scope == "cluster"
      assert result.audit_log.tenant_id == nil
      assert result.audit_log.action == "node_admission.rejected"
    end

    test "SPEC.md §4.3 node-id rejection is pending-only and does not duplicate decisions" do
      node =
        insert_node!(%{
          state: :registered,
          display_name: "registered-double-reject",
          hostname: "registered-double-reject.local",
          advertise_addr: "10.0.0.21",
          rpc_port: 9444
        })

      assert {:ok, _rejected} =
               Nodes.reject_admission(node.id, %{reason: "first rejection"})

      assert {:error, :admission_not_pending} =
               Nodes.reject_admission(node.id, %{reason: "second rejection"})

      decisions =
        AdmissionDecision
        |> where([decision], decision.node_id == ^node.id)
        |> where([decision], decision.decision == :rejected)
        |> Repo.all()

      assert length(decisions) == 1
    end

    test "SPEC.md §4.3 rejected observed candidate remains rejected after later observation" do
      node_id = Ecto.UUID.generate()
      target = make_target("10.0.0.15", 9444)
      observed_at = DateTime.utc_now()

      status =
        make_status_response(%{
          node_id: node_id,
          display_name: "rejected-observed",
          hostname: "rejected-observed.local",
          listen_host: "10.0.0.15",
          listen_port: 9444
        })

      assert :noop = observe_status(target, status, observed_at)
      [candidate] = Nodes.list_admission_candidates()

      assert {:ok, rejected} =
               Nodes.reject_admission(candidate.id, %{reason: "not trusted"})

      assert rejected.candidate.admission_category == :rejected

      later = DateTime.add(observed_at, 1, :second)
      assert :noop = observe_status(target, status, later)

      assert [refreshed] = Nodes.list_admission_candidates()
      assert refreshed.id == candidate.id
      assert refreshed.admission_category == :rejected
      assert refreshed.last_observed_at == DateTime.truncate(later, :microsecond)
    end

    test "SPEC.md §4.2 first BEAM observation creates a BEAM admission candidate" do
      node_id = Ecto.UUID.generate()
      target = Target.beam(node_id, address: :orchard_node_agent@localhost)
      observed_at = DateTime.utc_now()

      observation =
        Observation.new(%{
          endpoint_id: target.id,
          target: target,
          availability: :available,
          aggregate_active_request_count: 0,
          aggregate_max_concurrency: 1,
          metadata: %{
            node_id: node_id,
            display_name: "beam-candidate",
            hostname: "beam-candidate.local",
            listen_host: "10.0.0.16",
            listen_port: 9444
          },
          health: %{ready: true},
          placements: []
        })

      assert :noop = observe_status(target, observation, observed_at)
      assert Repo.get(Node, node_id) == nil

      assert [%AdmissionCandidate{} = candidate] = Nodes.list_admission_candidates()
      assert candidate.source == :runtime_endpoint_observation
      assert candidate.admission_category == :pending_observed
      assert candidate.endpoint_transport == :beam
      assert candidate.endpoint_target == "10.0.0.16:9444"
      assert candidate.observed_identity["claimed_node_id"] == node_id
    end

    test "SPEC.md §4.3 rejection clear appends history before registered node admission" do
      node =
        insert_node!(%{
          state: :registered,
          display_name: "registered-for-admission",
          hostname: "registered-for-admission.local",
          advertise_addr: "10.0.0.13",
          rpc_port: 9444
        })

      assert {:ok, rejected} =
               Nodes.reject_admission(node.id, %{reason: "waiting for approval"})

      assert Repo.get!(Node, node.id).state == :registered
      assert {:error, :admission_rejected} = Nodes.admit_node(node.id)

      assert {:ok, cleared} =
               Nodes.clear_admission_rejection(rejected.candidate.id, %{surface: "test"})

      assert cleared.candidate.admission_category == :pending_registered
      assert {:ok, admitted} = Nodes.admit_node(node.id, admission_attrs(), admission_opts())
      assert admitted.node.state == :admitted
      assert admitted.decision.decision == :admitted
      assert admitted.policy.policy_state == :approved_explicit
      assert admitted.policy.controller_dispatch_ceiling == 1
      assert admitted.policy.approval_reason == "approved for test capacity"
      assert admitted.policy.admission_decision_id == admitted.decision.id

      decisions =
        AdmissionDecision
        |> where([decision], decision.node_id == ^node.id)
        |> order_by([decision], asc: decision.inserted_at)
        |> Repo.all()
        |> Enum.map(& &1.decision)

      assert decisions == [:rejected, :rejection_cleared, :admitted]
    end

    test "SPEC.md §7.3.1 admission preserves explicit zero and approval provenance" do
      node =
        insert_node!(%{
          state: :registered,
          display_name: "registered-zero-capacity",
          hostname: "registered-zero-capacity.local"
        })

      attrs =
        admission_attrs(%{
          controller_dispatch_ceiling: 0,
          capacity_policy_reason: "admit without dispatch headroom"
        })

      assert {:ok, admitted} =
               Nodes.admit_node(node.id, attrs,
                 actor_type: "service_account",
                 actor_id: "operator-42"
               )

      assert %Policy{} = policy = Repo.get!(Policy, node.id)
      assert policy.controller_dispatch_ceiling == 0
      assert policy.policy_state == :approved_explicit
      assert policy.approved_by_actor_type == "service_account"
      assert policy.approved_by_actor_id == "operator-42"
      assert policy.approval_reason == "admit without dispatch headroom"
      assert policy.admission_decision_id == admitted.decision.id
    end

    test "SPEC.md §7.3.1 capacity policy validation rolls back admission" do
      node =
        insert_node!(%{
          state: :registered,
          display_name: "registered-invalid-capacity",
          hostname: "registered-invalid-capacity.local"
        })

      assert {:error, :capacity_policy_reason_required} =
               Nodes.admit_node(node.id, Map.delete(admission_attrs(), :capacity_policy_reason))

      assert Repo.get!(Node, node.id).state == :registered
      assert Repo.get(Policy, node.id) == nil

      assert {:error, :invalid_controller_dispatch_ceiling} =
               Nodes.admit_node(node.id, admission_attrs(%{controller_dispatch_ceiling: -1}))

      assert Repo.get!(Node, node.id).state == :registered
      assert Repo.get(Policy, node.id) == nil
    end

    test "SPEC.md §7.3.1 a non-binary capacity policy reason is a client error, not a rollback" do
      node =
        insert_node!(%{
          state: :registered,
          display_name: "registered-nonbinary-reason",
          hostname: "registered-nonbinary-reason.local"
        })

      for reason <- [123, %{"text" => "approved"}, ["approved"], :approved, true] do
        assert {:error, :capacity_policy_reason_required} =
                 Nodes.admit_node(node.id, admission_attrs(%{capacity_policy_reason: reason}))

        assert Repo.get!(Node, node.id).state == :registered
        assert Repo.get(Policy, node.id) == nil
      end
    end

    test "SPEC.md §7.3.1 admission rolls back when no trusted actor provenance is available" do
      node =
        insert_node!(%{
          state: :registered,
          display_name: "registered-no-actor",
          hostname: "registered-no-actor.local"
        })

      assert {:error, :admission_actor_identity_unavailable} =
               Nodes.admit_node(node.id, admission_attrs())

      assert Repo.get!(Node, node.id).state == :registered
      assert Repo.get(Policy, node.id) == nil
      assert Repo.aggregate(AdmissionDecision, :count) == 0
    end

    test "SPEC.md §7.3.1 admission ignores actor provenance supplied in request attributes" do
      node =
        insert_node!(%{
          state: :registered,
          display_name: "registered-spoofed-actor",
          hostname: "registered-spoofed-actor.local"
        })

      attrs =
        admission_attrs(%{
          actor_id: "spoofed-operator",
          actor_type: "system",
          approved_by_actor_id: "spoofed-operator"
        })

      assert {:ok, admitted} = Nodes.admit_node(node.id, attrs, admission_opts())

      policy = Repo.get!(Policy, node.id)
      assert policy.approved_by_actor_type == "service_account"
      assert policy.approved_by_actor_id == "admin-api-principal"

      decision = Repo.get!(AdmissionDecision, admitted.decision.id)
      assert decision.actor_type == "service_account"
      assert decision.actor_id == "admin-api-principal"
      refute Map.has_key?(decision.metadata, "actor_id")
      refute Map.has_key?(decision.metadata, "actor_type")
      assert decision.metadata["capacity_policy_reason"] == "approved for test capacity"

      audit_log = Repo.get!(AuditLog, admitted.audit_log.id)
      refute Map.has_key?(audit_log.payload, "actor_id")
      refute Map.has_key?(audit_log.payload, "actor_type")
      assert audit_log.actor_id == "admin-api-principal"
    end

    test "SPEC.md §4.2 registered node admission fails closed without required inputs" do
      node =
        insert_node!(%{
          state: :registered,
          display_name: "registered-inputs",
          hostname: "registered-inputs.local",
          advertise_addr: "10.0.0.17",
          rpc_port: 9444
        })

      assert {:error, :trust_not_established} = Nodes.admit_node(node.id)

      assert {:error, :pool_required} =
               Nodes.admit_node(node.id, %{trust_evidence_ref: "registration-audit:test"})

      assert {:error, :policy_required} =
               Nodes.admit_node(node.id, %{
                 trust_evidence_ref: "registration-audit:test",
                 pool_id: Ecto.UUID.generate()
               })
    end

    test "SPEC.md §4.2 registered node admission accepts bind-all inventory with connect target" do
      node =
        insert_node!(%{
          state: :registered,
          display_name: "registered-bind-all",
          hostname: "registered-bind-all.local",
          advertise_addr: "0.0.0.0",
          rpc_port: 50_071,
          connect_host: "100.90.207.78",
          connect_port: 50_071
        })

      assert {:ok, admitted} = Nodes.admit_node(node.id, admission_attrs(), admission_opts())
      assert admitted.node.state == :admitted
      assert admitted.decision.decision == :admitted
    end

    test "SPEC.md §4.3 admission decisions reject direct updates" do
      target = make_target("10.0.0.18", 9444)

      status =
        make_status_response(%{
          display_name: "append-only-candidate",
          hostname: "append-only-candidate.local",
          listen_host: "10.0.0.18",
          listen_port: 9444
        })

      assert :noop = observe_status(target, status, DateTime.utc_now())
      [candidate] = Nodes.list_admission_candidates()

      assert {:ok, result} =
               Nodes.reject_admission(candidate.id, %{reason: "append-only test"})

      {:ok, decision_id} = Ecto.UUID.dump(result.decision.id)

      assert_raise Postgrex.Error, ~r/node_admission_decisions is append-only/, fn ->
        Repo.query!(
          "UPDATE node_admission_decisions SET reason = 'mutated' WHERE id = $1",
          [decision_id]
        )
      end
    end

    test "SPEC.md §4.3 admission decisions reject direct deletes" do
      target = make_target("10.0.0.23", 9444)

      status =
        make_status_response(%{
          display_name: "append-only-delete-candidate",
          hostname: "append-only-delete-candidate.local",
          listen_host: "10.0.0.23",
          listen_port: 9444
        })

      assert :noop = observe_status(target, status, DateTime.utc_now())
      [candidate] = Nodes.list_admission_candidates()

      assert {:ok, result} =
               Nodes.reject_admission(candidate.id, %{reason: "append-only delete test"})

      {:ok, decision_id} = Ecto.UUID.dump(result.decision.id)

      assert_raise Postgrex.Error, ~r/node_admission_decisions is append-only/, fn ->
        Repo.query!("DELETE FROM node_admission_decisions WHERE id = $1", [decision_id])
      end
    end

    test "SPEC.md §4.3 admission decisions allow FK retention nullification" do
      node =
        insert_node!(%{
          state: :registered,
          display_name: "registered-fk-nullify",
          hostname: "registered-fk-nullify.local",
          advertise_addr: "10.0.0.22",
          rpc_port: 9444
        })

      assert {:ok, result} =
               Nodes.reject_admission(node.id, %{reason: "fk nullify test"})

      decision_id = result.decision.id

      Repo.delete!(result.candidate)

      decision = Repo.get!(AdmissionDecision, decision_id)
      assert decision.candidate_id == nil
      assert decision.node_id == node.id
      assert decision.audit_log_id == result.audit_log.id

      Repo.delete!(node)

      decision = Repo.get!(AdmissionDecision, decision_id)
      assert decision.candidate_id == nil
      assert decision.node_id == nil
      assert decision.audit_log_id == result.audit_log.id

      Repo.query!("ALTER TABLE audit_logs DISABLE TRIGGER audit_logs_append_only")

      try do
        Repo.delete!(result.audit_log)
      after
        Repo.query!("ALTER TABLE audit_logs ENABLE TRIGGER audit_logs_append_only")
      end

      decision = Repo.get!(AdmissionDecision, decision_id)
      assert decision.candidate_id == nil
      assert decision.node_id == nil
      assert decision.audit_log_id == nil
      assert decision.reason == "fk nullify test"
    end

    test "SPEC.md §4.3 admission decisions reject direct reference rewrites" do
      target = make_target("10.0.0.25", 9444)

      status =
        make_status_response(%{
          display_name: "append-only-reference-candidate",
          hostname: "append-only-reference-candidate.local",
          listen_host: "10.0.0.25",
          listen_port: 9444
        })

      assert :noop = observe_status(target, status, DateTime.utc_now())
      [candidate] = Nodes.list_admission_candidates()

      assert {:ok, result} =
               Nodes.reject_admission(candidate.id, %{reason: "reference rewrite test"})

      other_candidate =
        %AdmissionCandidate{}
        |> AdmissionCandidate.changeset(%{
          source: :runtime_endpoint_observation,
          admission_category: :pending_observed,
          observed_identity: %{"claimed_node_id" => Ecto.UUID.generate()},
          target_ref: "10.0.0.26:9444",
          endpoint_transport: :grpc,
          endpoint_target: "10.0.0.26:9444",
          inventory: %{},
          compatibility_evidence: %{},
          last_observed_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      other_node =
        insert_node!(%{
          state: :registered,
          display_name: "registered-reference-target",
          hostname: "registered-reference-target.local",
          advertise_addr: "10.0.0.27",
          rpc_port: 9444
        })

      assert {:ok, other_audit_log} =
               Orchard.Governance.insert_cluster_audit_log(%{
                 action: "node_admission.rejected",
                 target_type: "node",
                 target_id: other_node.id,
                 payload: %{}
               })

      {:ok, decision_id} = Ecto.UUID.dump(result.decision.id)
      {:ok, other_candidate_id} = Ecto.UUID.dump(other_candidate.id)
      {:ok, other_node_id} = Ecto.UUID.dump(other_node.id)

      assert_raise Postgrex.Error, ~r/node_admission_decisions is append-only/, fn ->
        Repo.query!(
          "UPDATE node_admission_decisions SET candidate_id = NULL WHERE id = $1",
          [decision_id]
        )
      end

      assert_raise Postgrex.Error, ~r/node_admission_decisions is append-only/, fn ->
        Repo.query!(
          "UPDATE node_admission_decisions SET candidate_id = $2 WHERE id = $1",
          [decision_id, other_candidate_id]
        )
      end

      assert_raise Postgrex.Error, ~r/node_admission_decisions is append-only/, fn ->
        Repo.query!(
          "UPDATE node_admission_decisions SET node_id = $2 WHERE id = $1",
          [decision_id, other_node_id]
        )
      end

      assert_raise Postgrex.Error, ~r/node_admission_decisions is append-only/, fn ->
        Repo.query!(
          "UPDATE node_admission_decisions SET audit_log_id = $2 WHERE id = $1",
          [decision_id, other_audit_log.id]
        )
      end
    end

    test "SPEC.md §4.3 unauthenticated healthy observation does not activate admitted node" do
      node =
        insert_node!(%{
          state: :registered,
          display_name: "registered-activation",
          hostname: "registered-activation.local",
          advertise_addr: "10.0.0.14",
          rpc_port: 9444
        })

      assert {:ok, admitted} = Nodes.admit_node(node.id, admission_attrs(), admission_opts())
      assert admitted.node.state == :admitted

      target = make_target("10.0.0.14", 9444)

      status =
        make_status_response(%{
          node_id: node.id,
          display_name: "registered-activation",
          hostname: "registered-activation.local",
          listen_host: "10.0.0.14",
          listen_port: 9444
        })

      assert {:ok, observed} = observe_status(target, status, DateTime.utc_now())
      assert observed.state == :admitted
      assert DispatchCapacity.get_capacity_evidence(node.id) == nil
    end
  end

  # -- observe_status/3 trusted update --

  describe "observe_status/3 trusted update" do
    test "valid metadata updates active node" do
      node_id = Ecto.UUID.generate()
      target = make_target("10.0.0.1", 9444)
      now = DateTime.utc_now()

      status =
        make_status_response(%{
          node_id: node_id,
          display_name: "test-node",
          hostname: "test-host.local",
          listen_host: "10.0.0.1",
          listen_port: 9444
        })

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, now)
      assert node.id == node_id
      assert node.state == :active
      assert node.display_name == "test-node"
      assert node.hostname == "test-host.local"
      assert node.advertise_addr == "10.0.0.1"
      assert node.rpc_port == 9444
      assert node.connect_host == "10.0.0.1"
      assert node.connect_port == 9444
    end

    test "persists connect target separately from advertised bind-all address" do
      node_id = Ecto.UUID.generate()
      target = make_target("100.90.207.78", 50_071)
      now = DateTime.utc_now()

      status =
        make_status_response(%{
          node_id: node_id,
          display_name: "bind-all-node",
          hostname: "bind-all.local",
          listen_host: "0.0.0.0",
          listen_port: 50_071
        })

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, now)
      assert node.advertise_addr == "0.0.0.0"
      assert node.rpc_port == 50_071
      assert node.connect_host == "100.90.207.78"
      assert node.connect_port == 50_071
    end

    test "persists health mapping: nil runtime_health -> healthy" do
      target = make_target("10.0.0.2", 9444)
      status = make_status_response(%{listen_host: "10.0.0.2"}, nil)

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, DateTime.utc_now())
      assert node.health == :healthy
    end

    test "persists health mapping: not ready -> unhealthy" do
      target = make_target("10.0.0.3", 9444)
      status = make_status_response(%{listen_host: "10.0.0.3"}, %{ready: false})

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, DateTime.utc_now())
      assert node.health == :unhealthy
    end

    test "persists health mapping: ready with code -> degraded" do
      target = make_target("10.0.0.4", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.4"}, %{
          ready: true,
          health_code: "SLOW"
        })

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, DateTime.utc_now())
      assert node.health == :degraded
    end

    test "stores worker_backend in capabilities" do
      target = make_target("10.0.0.5", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.5", worker_backend: "mlx"})

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, DateTime.utc_now())

      assert node.capabilities == %{
               "worker_backend" => "mlx",
               "supports_prompt_token_ids" => false,
               "hosted_tools" => []
             }

      assert node.tool_readiness == %{}
    end

    test "stores prompt token id support in capabilities" do
      target = make_target("10.0.0.50", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.50", worker_backend: "mlx"})
        |> Map.put(:supports_prompt_token_ids, true)

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, DateTime.utc_now())
      assert node.capabilities["supports_prompt_token_ids"] == true
    end

    test "stores missing prompt token id support as false in capabilities" do
      target = make_target("10.0.0.51", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.51", worker_backend: "mlx"})
        |> Map.put(:supports_prompt_token_ids, false)

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, DateTime.utc_now())
      assert node.capabilities["supports_prompt_token_ids"] == false
    end

    test "empty worker_backend stores empty capabilities" do
      target = make_target("10.0.0.6", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.6", worker_backend: ""})

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, DateTime.utc_now())
      assert node.capabilities == %{"supports_prompt_token_ids" => false, "hosted_tools" => []}
      assert node.tool_readiness == %{}
    end

    test "persists hosted tool capability separately from tool readiness" do
      target = make_target("10.0.0.7", 9444)

      status = %{
        node_metadata: %{
          node_id: Ecto.UUID.generate(),
          display_name: "tool-node",
          hostname: "tool-node.local",
          agent_version: "0.5.0",
          listen_host: "10.0.0.7",
          listen_port: 9444,
          worker_backend: "mlx"
        },
        runtime_health: %{ready: true, health_code: "", health_message: ""},
        hosted_tool_capabilities: [
          %{name: "lookup_docs", version: "2026-04-11", adapter_kind: "mcp"}
        ],
        hosted_tool_readiness: [
          %{
            name: "lookup_docs",
            version: "2026-04-11",
            ready: false,
            readiness_code: "warming",
            readiness_message: "warming up"
          }
        ]
      }

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, DateTime.utc_now())

      assert node.capabilities == %{
               "worker_backend" => "mlx",
               "supports_prompt_token_ids" => false,
               "hosted_tools" => [
                 %{
                   "ref" => "tool://lookup_docs@2026-04-11",
                   "name" => "lookup_docs",
                   "version" => "2026-04-11",
                   "adapter_kind" => "mcp"
                 }
               ]
             }

      assert node.tool_readiness == %{
               "tool://lookup_docs@2026-04-11" => %{
                 "ready" => false,
                 "status_code" => "warming",
                 "status_message" => "warming up"
               }
             }
    end

    test "swallows QueueManager refresh exits after persisting eligible node" do
      put_queue_manager_impl(Orchard.NodesTest.ExitingQueueManager)

      node_id = Ecto.UUID.generate()
      target = make_target("10.0.0.46", 9444)

      status =
        make_status_response(%{
          node_id: node_id,
          listen_host: "10.0.0.46",
          listen_port: 9444
        })
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, DateTime.utc_now())
      assert node.id == node_id
    end

    test "drops readiness entries without matching capability" do
      target = make_target("10.0.0.8", 9444)

      status = %{
        node_metadata: %{
          node_id: Ecto.UUID.generate(),
          display_name: "tool-node-no-readiness",
          hostname: "tool-node-no-readiness.local",
          agent_version: "0.5.0",
          listen_host: "10.0.0.8",
          listen_port: 9444,
          worker_backend: "mlx"
        },
        runtime_health: %{ready: true, health_code: "", health_message: ""},
        hosted_tool_capabilities: [
          %{name: "lookup_docs", version: "2026-04-11", adapter_kind: "mcp"}
        ],
        hosted_tool_readiness: [
          %{name: "other_tool", version: "2026-04-11", ready: true}
        ]
      }

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, DateTime.utc_now())

      assert node.capabilities["hosted_tools"] == [
               %{
                 "ref" => "tool://lookup_docs@2026-04-11",
                 "name" => "lookup_docs",
                 "version" => "2026-04-11",
                 "adapter_kind" => "mcp"
               }
             ]

      assert node.tool_readiness == %{}
    end

    test "ignores malformed hosted tool entries without turning valid observation into noop" do
      target = make_target("10.0.0.9", 9444)

      status = %{
        node_metadata: %{
          node_id: Ecto.UUID.generate(),
          display_name: "tool-node-malformed",
          hostname: "tool-node-malformed.local",
          agent_version: "0.5.0",
          listen_host: "10.0.0.9",
          listen_port: 9444,
          worker_backend: "mlx"
        },
        runtime_health: %{ready: true, health_code: "", health_message: ""},
        hosted_tool_capabilities: [
          %{name: "bad tool", version: "2026-04-11", adapter_kind: "mcp"},
          %{name: "lookup_docs", version: "2026-04-11", adapter_kind: "mcp"}
        ],
        hosted_tool_readiness: [
          %{name: "lookup_docs", version: "2026-04-11", ready: "yes"},
          %{name: "lookup_docs", version: "2026-04-11", ready: true, readiness_code: "ok"}
        ]
      }

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, DateTime.utc_now())

      assert node.capabilities["hosted_tools"] == [
               %{
                 "ref" => "tool://lookup_docs@2026-04-11",
                 "name" => "lookup_docs",
                 "version" => "2026-04-11",
                 "adapter_kind" => "mcp"
               }
             ]

      assert node.tool_readiness == %{
               "tool://lookup_docs@2026-04-11" => %{
                 "ready" => true,
                 "status_code" => "ok",
                 "status_message" => ""
               }
             }
    end
  end

  # -- observe_status/3 update --

  describe "observe_status/3 update" do
    test "updates metadata on existing node" do
      node_id = Ecto.UUID.generate()
      existing = insert_node!(%{id: node_id, advertise_addr: "10.0.0.10", rpc_port: 9444})
      target = make_target("10.0.0.10", 9444)
      later = DateTime.add(DateTime.utc_now(), 60, :second)

      status =
        make_status_response(%{
          node_id: node_id,
          display_name: "updated-name",
          hostname: "updated-host.local",
          listen_host: "10.0.0.10",
          listen_port: 9444,
          agent_version: "0.2.0"
        })

      insert_node_from_status!(target, status)
      assert {:ok, updated} = observe_status(target, status, later)
      assert updated.id == existing.id
      assert updated.display_name == "updated-name"
      assert updated.agent_version == "0.2.0"
    end

    test "preserves admin-managed state on update" do
      node_id = Ecto.UUID.generate()
      insert_node!(%{id: node_id, state: :cordoned, advertise_addr: "10.0.0.11", rpc_port: 9444})
      target = make_target("10.0.0.11", 9444)
      later = DateTime.add(DateTime.utc_now(), 60, :second)

      status =
        make_status_response(%{
          node_id: node_id,
          display_name: "cordoned-node",
          listen_host: "10.0.0.11",
          listen_port: 9444
        })

      insert_node_from_status!(target, status)
      assert {:ok, updated} = observe_status(target, status, later)
      assert updated.state == :cordoned
    end

    test "SPEC.md §5.4 placement state change wakes queued model lane" do
      QueueManager.reset()

      assert {:queued, ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-placement-wake", "wake-model"),
                 config: queue_config(capacity: 0)
               )

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      refute Task.yield(awaiter, 50)

      status =
        make_status_response(%{
          listen_host: "10.0.0.52",
          listen_port: 9444
        })
        |> Map.put(:runtime_model_placements, [
          %{
            model_ref: %{model_id: "wake-model", version: "v1"},
            placement_state: :PLACEMENT_STATE_LOADED,
            active_request_count: 0,
            max_concurrency: 1
          }
        ])

      target = make_target("10.0.0.52", 9444)
      insert_node_from_status!(target, status)

      assert {:ok, _node} =
               observe_status(target, status, DateTime.utc_now())

      assert {:ok, grant} = Task.await(awaiter, 2_000)
      assert grant.queue_result == :queued
      assert grant.queue_key == "wake-model@v1"

      assert :ok = QueueManager.release(grant)
    end

    test "SPEC.md §5.4 placement status aggregates queued capacity across nodes" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-placement-aggregate-a", "aggregate-model"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-placement-aggregate-b", "aggregate-model"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_aggregate_result)
      second_awaiter = start_holding_awaiter(second_ticket, :second_aggregate_result)

      status_a =
        placement_status("10.0.0.53", "aggregate-model", max_concurrency: 1)

      target_a = make_target("10.0.0.53", 9444)
      insert_node_from_status!(target_a, status_a)

      assert {:ok, node_a} =
               observe_status(target_a, status_a, DateTime.utc_now())

      assert_receive {:first_aggregate_result, {:ok, first_grant}}, 2_000
      assert :ok = QueueManager.mark_grant_node(first_grant, node_a.id)
      refute_receive {:second_aggregate_result, _result}, 50

      status_b =
        placement_status("10.0.0.54", "aggregate-model", max_concurrency: 1)

      target_b = make_target("10.0.0.54", 9444)
      insert_node_from_status!(target_b, status_b)

      assert {:ok, _node} =
               observe_status(target_b, status_b, DateTime.utc_now())

      assert_receive {:second_aggregate_result, {:ok, second_grant}}, 2_000

      assert first_grant.queue_result == :queued
      assert second_grant.queue_result == :queued

      assert :ok = QueueManager.release(first_grant)
      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
      send(second_awaiter, :stop)
    end

    test "SPEC.md §5.5 placement status queue refresh is constrained by node max concurrency" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-capacity-constrained-a", "node-cap-model"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-capacity-constrained-b", "node-cap-model"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_node_cap_result)
      second_awaiter = start_holding_awaiter(second_ticket, :second_node_cap_result)

      target = make_target("10.0.0.56", 9444)

      status =
        placement_status("10.0.0.56", "node-cap-model", max_concurrency: 4)
        |> Map.put(:active_request_count, 1)
        |> Map.put(:max_concurrency, 2)

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, DateTime.utc_now())

      assert_receive {:first_node_cap_result, {:ok, first_grant}}, 2_000
      refute_receive {:second_node_cap_result, _result}, 100

      refreshed_status = Map.put(status, :active_request_count, 0)

      insert_node_from_status!(target, refreshed_status)
      assert {:ok, _node} = observe_status(target, refreshed_status, DateTime.utc_now())
      assert_receive {:second_node_cap_result, {:ok, second_grant}}, 2_000

      assert first_grant.queue_result == :queued
      assert second_grant.queue_result == :queued

      assert :ok = QueueManager.release(first_grant)
      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
      send(second_awaiter, :stop)
    end

    test "SPEC.md §5.5 placement heartbeat spends one node slot across queued lanes" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-placement-lane-a", "placement-lane-a"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-placement-lane-b", "placement-lane-b"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_placement_lane_result)
      second_awaiter = start_holding_awaiter(second_ticket, :second_placement_lane_result)
      target = make_target("10.0.0.68", 9444)
      observed_at = DateTime.utc_now()

      status =
        make_status_response(%{listen_host: "10.0.0.68", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [
          %{
            model_ref: %{model_id: "placement-lane-a", version: "v1"},
            active_request_count: 0,
            max_concurrency: 1
          },
          %{
            model_ref: %{model_id: "placement-lane-b", version: "v1"},
            active_request_count: 0,
            max_concurrency: 1
          }
        ])

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, observed_at)

      {granted_lane, first_grant} =
        receive do
          {:first_placement_lane_result, {:ok, grant}} -> {:first, grant}
          {:second_placement_lane_result, {:ok, grant}} -> {:second, grant}
        after
          2_000 -> flunk("expected exactly one placement lane grant")
        end

      refute_receive {:first_placement_lane_result, _result}, 100
      refute_receive {:second_placement_lane_result, _result}, 100

      assert :ok = QueueManager.release(first_grant)

      assert {:ok, _node} =
               observe_status(target, status, DateTime.add(observed_at, 1, :second))

      second_grant =
        case granted_lane do
          :first ->
            assert_receive {:second_placement_lane_result, {:ok, grant}}, 2_000
            grant

          :second ->
            assert_receive {:first_placement_lane_result, {:ok, grant}}, 2_000
            grant
        end

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
      send(second_awaiter, :stop)
    end

    test "SPEC.md §5.5 status observation reserves unassigned base grants by default" do
      QueueManager.reset()

      assert {:ok, active_grant} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-default-observation-base-a",
                   "default-observation-base"
                 ),
                 config: queue_config(capacity: 1)
               )

      assert {:queued, ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-default-observation-base-b",
                   "default-observation-base"
                 ),
                 config: queue_config(capacity: 1)
               )

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket) end)

      target = make_target("10.0.0.86", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.86", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, DateTime.utc_now())
      refute Task.yield(awaiter, 100)

      assert :ok = QueueManager.release(active_grant)
      assert {:ok, queued_grant} = Task.await(awaiter, 2_000)
      assert queued_grant.queue_result == :queued

      assert :ok = QueueManager.release(queued_grant)
    end

    test "SPEC.md §5.5 aggregate headroom does not republish an observed source reservation" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-observed-source-a", "observed-source-model"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-observed-source-b", "observed-source-model"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_observed_source_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      target = make_target("10.0.0.80", 9444)
      observed_at = DateTime.utc_now()

      initial_status =
        placement_status("10.0.0.80", "observed-source-model", max_concurrency: 1)
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)

      insert_node_from_status!(target, initial_status)
      assert {:ok, _node} = observe_status(target, initial_status, observed_at)
      assert_receive {:first_observed_source_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)
      assert :ok = QueueManager.mark_capacity_source_observed(first_grant)

      refreshed_status =
        initial_status
        |> Map.put(:active_request_count, 1)
        |> Map.put(:max_concurrency, 2)
        |> put_in([:runtime_model_placements, Access.at(0), :max_concurrency], 2)
        |> put_in([:runtime_model_placements, Access.at(0), :active_request_count], 1)

      assert {:ok, _node} =
               observe_status(
                 target,
                 refreshed_status,
                 DateTime.add(observed_at, 1, :second)
               )

      assert {:error, :queue_timeout, metadata} = Task.await(second_awaiter, 2_000)
      assert metadata.queue_key == "observed-source-model@v1"

      assert :ok = QueueManager.release(first_grant)
      send(first_awaiter, :stop)
    end

    test "SPEC.md §5.5 unobserved source reservation does not overlap unrelated active work" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-unobserved-source-a", "unobserved-source-a"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-unobserved-source-b", "unobserved-source-b"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_unobserved_source_result)
      second_awaiter = start_holding_awaiter(second_ticket, :second_unobserved_source_result)
      target = make_target("10.0.0.83", 9444)
      observed_at = DateTime.utc_now()

      initial_status =
        make_status_response(%{listen_host: "10.0.0.83", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, initial_status)
      assert {:ok, _node} = observe_status(target, initial_status, observed_at)
      assert_receive {:first_unobserved_source_result, {:ok, first_grant}}, 2_000
      refute_receive {:second_unobserved_source_result, _result}, 50

      refreshed_status =
        initial_status
        |> Map.put(:active_request_count, 1)
        |> Map.put(:max_concurrency, 2)

      assert {:ok, _node} =
               observe_status(
                 target,
                 refreshed_status,
                 DateTime.add(observed_at, 1, :second)
               )

      refute_receive {:second_unobserved_source_result, _result}, 100

      assert :ok = QueueManager.release(first_grant)
      assert_receive {:second_unobserved_source_result, {:ok, second_grant}}, 2_000

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
      send(second_awaiter, :stop)
    end

    test "SPEC.md §5.5 multi-slot placement heartbeat grants queued lanes in order" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-multislot-placement-a", "multislot-lane-a"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-multislot-placement-b", "multislot-lane-b"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_multislot_result)
      second_awaiter = start_holding_awaiter(second_ticket, :second_multislot_result)
      target = make_target("10.0.0.81", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.81", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 2)
        |> Map.put(:runtime_model_placements, [
          %{
            model_ref: %{model_id: "multislot-lane-a", version: "v1"},
            active_request_count: 0,
            max_concurrency: 2
          },
          %{
            model_ref: %{model_id: "multislot-lane-b", version: "v1"},
            active_request_count: 0,
            max_concurrency: 1
          }
        ])

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, DateTime.utc_now())

      assert_receive {:first_multislot_result, {:ok, first_grant}}, 2_000
      assert_receive {:second_multislot_result, {:ok, second_grant}}, 2_000
      assert first_grant.queue_key == "multislot-lane-a@v1"
      assert second_grant.queue_key == "multislot-lane-b@v1"

      assert :ok = QueueManager.release(first_grant)
      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
      send(second_awaiter, :stop)
    end

    test "SPEC.md §5.5 heartbeat spends node capacity in queue-head order" do
      QueueManager.reset()

      tenant_id = Ecto.UUID.generate()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-head-order-cold", "head-order-cold")
                 |> Map.put(:tenant_id, tenant_id),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-head-order-loaded", "head-order-loaded")
                 |> Map.put(:tenant_id, tenant_id),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_head_order_result)
      second_awaiter = start_holding_awaiter(second_ticket, :second_head_order_result)
      target = make_target("10.0.0.78", 9444)
      observed_at = DateTime.utc_now()

      status =
        make_status_response(%{listen_host: "10.0.0.78", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [
          %{
            model_ref: %{model_id: "head-order-loaded", version: "v1"},
            active_request_count: 0,
            max_concurrency: 1
          }
        ])

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, observed_at)

      assert_receive {:first_head_order_result, {:ok, first_grant}}, 2_000
      refute_receive {:second_head_order_result, _result}, 100

      assert :ok = QueueManager.release(first_grant)

      assert {:ok, _node} =
               observe_status(target, status, DateTime.add(observed_at, 1, :second))

      assert_receive {:second_head_order_result, {:ok, second_grant}}, 2_000

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
      send(second_awaiter, :stop)
    end

    test "SPEC.md §5.4 heartbeat state change wakes queued cold model lane" do
      QueueManager.reset()

      assert {:queued, ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-cold-wake", "cold-wake-model"),
                 config: queue_config(capacity: 0)
               )

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      target = make_target("10.0.0.59", 9444)

      full_status =
        make_status_response(%{listen_host: "10.0.0.59", listen_port: 9444})
        |> Map.put(:active_request_count, 1)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, full_status)
      assert {:ok, _node} = observe_status(target, full_status, DateTime.utc_now())
      refute Task.yield(awaiter, 100)

      available_status = Map.put(full_status, :active_request_count, 0)

      insert_node_from_status!(target, available_status)
      assert {:ok, _node} = observe_status(target, available_status, DateTime.utc_now())
      assert {:ok, grant} = Task.await(awaiter, 2_000)
      assert grant.queue_result == :queued
      assert grant.queue_key == "cold-wake-model@v1"

      assert :ok = QueueManager.release(grant)
    end

    test "SPEC.md §5.5 cold heartbeat contributes one conservative slot per node" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-cold-conservative-a", "cold-one-slot-model"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-cold-conservative-b", "cold-one-slot-model"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_cold_one_slot_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      target = make_target("10.0.0.64", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.64", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 4)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, DateTime.utc_now())
      assert_receive {:first_cold_one_slot_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 100)

      assert :ok = QueueManager.release(first_grant)
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued
      assert second_grant.queue_key == "cold-one-slot-model@v1"

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "SPEC.md §5.5 cold heartbeat spends one node slot across queued lanes" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-cold-lane-a", "cold-lane-a"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-cold-lane-b", "cold-lane-b"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_cold_lane_result)
      second_awaiter = start_holding_awaiter(second_ticket, :second_cold_lane_result)
      target = make_target("10.0.0.69", 9444)
      observed_at = DateTime.utc_now()

      status =
        make_status_response(%{listen_host: "10.0.0.69", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, observed_at)

      {granted_lane, first_grant} =
        receive do
          {:first_cold_lane_result, {:ok, grant}} -> {:first, grant}
          {:second_cold_lane_result, {:ok, grant}} -> {:second, grant}
        after
          2_000 -> flunk("expected exactly one cold lane grant")
        end

      refute_receive {:first_cold_lane_result, _result}, 100
      refute_receive {:second_cold_lane_result, _result}, 100

      assert :ok = QueueManager.release(first_grant)

      assert {:ok, _node} =
               observe_status(target, status, DateTime.add(observed_at, 1, :second))

      second_grant =
        case granted_lane do
          :first ->
            assert_receive {:second_cold_lane_result, {:ok, grant}}, 2_000
            grant

          :second ->
            assert_receive {:first_cold_lane_result, {:ok, grant}}, 2_000
            grant
        end

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
      send(second_awaiter, :stop)
    end

    test "SPEC.md §5.5 releasing cold source grant reallocates to next queued lane" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-release-cold-lane-a", "release-cold-lane-a"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-release-cold-lane-b", "release-cold-lane-b"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_release_cold_lane_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      target = make_target("10.0.0.82", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.82", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, DateTime.utc_now())
      assert_receive {:first_release_cold_lane_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      assert :ok = QueueManager.release(first_grant)
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued
      assert second_grant.queue_key == "release-cold-lane-b@v1"

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "SPEC.md §5.5 exhausted aggregate heartbeat clears observed cold source capacity" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-empty-source-a", "empty-source-a"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_empty_source_result)
      target = make_target("10.0.0.84", 9444)
      observed_at = DateTime.utc_now()

      initial_status =
        make_status_response(%{listen_host: "10.0.0.84", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, initial_status)
      assert {:ok, _node} = observe_status(target, initial_status, observed_at)
      assert_receive {:first_empty_source_result, {:ok, first_grant}}, 2_000
      assert :ok = QueueManager.mark_capacity_source_observed(first_grant)

      active_status = Map.put(initial_status, :active_request_count, 1)

      assert {:ok, _node} =
               observe_status(target, active_status, DateTime.add(observed_at, 1, :second))

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-empty-source-b", "empty-source-b"),
                 config: queue_config(capacity: 0)
               )

      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(second_ticket) end)
      refute Task.yield(second_awaiter, 50)

      assert :ok = QueueManager.release(first_grant)
      assert {:error, :queue_timeout, metadata} = Task.await(second_awaiter, 2_000)
      assert metadata.queue_key == "empty-source-b@v1"
      send(first_awaiter, :stop)
    end

    test "SPEC.md §5.5 repeated cold heartbeat keeps active source slot reserved across lanes" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-repeat-cold-lane-a", "repeat-cold-lane-a"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-repeat-cold-lane-b", "repeat-cold-lane-b"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_repeat_cold_lane_result)
      second_awaiter = start_holding_awaiter(second_ticket, :second_repeat_cold_lane_result)
      target = make_target("10.0.0.77", 9444)
      observed_at = DateTime.utc_now()

      status =
        make_status_response(%{listen_host: "10.0.0.77", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, observed_at)

      {granted_lane, first_grant} =
        receive do
          {:first_repeat_cold_lane_result, {:ok, grant}} -> {:first, grant}
          {:second_repeat_cold_lane_result, {:ok, grant}} -> {:second, grant}
        after
          2_000 -> flunk("expected exactly one cold lane grant")
        end

      assert {:ok, _node} =
               observe_status(target, status, DateTime.add(observed_at, 1, :second))

      refute_receive {:first_repeat_cold_lane_result, _result}, 100
      refute_receive {:second_repeat_cold_lane_result, _result}, 100

      assert :ok = QueueManager.release(first_grant)

      assert {:ok, _node} =
               observe_status(target, status, DateTime.add(observed_at, 2, :second))

      second_grant =
        case granted_lane do
          :first ->
            assert_receive {:second_repeat_cold_lane_result, {:ok, grant}}, 2_000
            grant

          :second ->
            assert_receive {:first_repeat_cold_lane_result, {:ok, grant}}, 2_000
            grant
        end

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
      send(second_awaiter, :stop)
    end

    test "SPEC.md §5.4 repeated cold heartbeat preserves queued lane capacity" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-repeated-cold-heartbeat-a",
                   "repeat-cold-model"
                 ),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-repeated-cold-heartbeat-b",
                   "repeat-cold-model"
                 ),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_repeat_cold_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      target = make_target("10.0.0.67", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.67", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, DateTime.utc_now())
      assert_receive {:first_repeat_cold_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      assert {:ok, _node} =
               observe_status(target, status, DateTime.add(DateTime.utc_now(), 1, :second))

      assert :ok = QueueManager.release(first_grant)
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued
      assert second_grant.queue_key == "repeat-cold-model@v1"

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "SPEC.md §5.5 cold heartbeat capacity aggregates across eligible nodes" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-cold-aggregate-a", "cold-aggregate-model"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-cold-aggregate-b", "cold-aggregate-model"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_cold_aggregate_result)
      second_awaiter = start_holding_awaiter(second_ticket, :second_cold_aggregate_result)

      status_a =
        make_status_response(%{listen_host: "10.0.0.65", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      target_a = make_target("10.0.0.65", 9444)
      insert_node_from_status!(target_a, status_a)

      assert {:ok, node_a} =
               observe_status(target_a, status_a, DateTime.utc_now())

      assert_receive {:first_cold_aggregate_result, {:ok, first_grant}}, 2_000
      assert :ok = QueueManager.mark_grant_node(first_grant, node_a.id)
      refute_receive {:second_cold_aggregate_result, _result}, 100

      status_b =
        make_status_response(%{listen_host: "10.0.0.66", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      target_b = make_target("10.0.0.66", 9444)
      insert_node_from_status!(target_b, status_b)

      assert {:ok, _node} =
               observe_status(target_b, status_b, DateTime.utc_now())

      assert_receive {:second_cold_aggregate_result, {:ok, second_grant}}, 2_000

      assert first_grant.queue_result == :queued
      assert first_grant.queue_key == "cold-aggregate-model@v1"
      assert second_grant.queue_result == :queued
      assert second_grant.queue_key == "cold-aggregate-model@v1"

      assert :ok = QueueManager.release(first_grant)
      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
      send(second_awaiter, :stop)
    end

    test "SPEC.md §5.5 degraded node heartbeat can wake queued cold model lane" do
      QueueManager.reset()

      assert {:queued, ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-degraded-cold-wake", "degraded-cold-model"),
                 config: queue_config(capacity: 0)
               )

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      target = make_target("10.0.0.63", 9444)

      status =
        make_status_response(
          %{listen_host: "10.0.0.63", listen_port: 9444},
          %{health_code: "degraded", health_message: "runtime degraded but available"}
        )
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, DateTime.utc_now())
      assert node.health == :degraded
      assert {:ok, grant} = Task.await(awaiter, 2_000)
      assert grant.queue_result == :queued
      assert grant.queue_key == "degraded-cold-model@v1"

      assert :ok = QueueManager.release(grant)
    end

    test "SPEC.md §5.5 ineligible node heartbeat does not wake queued cold model lane" do
      QueueManager.reset()

      node_id = Ecto.UUID.generate()

      node =
        insert_node!(%{
          id: node_id,
          state: :cordoned,
          advertise_addr: "10.0.0.62",
          rpc_port: 9444
        })

      assert {:queued, ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-cordoned-cold-wake", "cordoned-cold-model"),
                 config: queue_config(capacity: 0)
               )

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      target = make_target("10.0.0.62", 9444)

      status =
        make_status_response(%{
          node_id: node_id,
          listen_host: "10.0.0.62",
          listen_port: 9444
        })
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, status)
      assert {:ok, updated} = observe_status(target, status, DateTime.utc_now())
      assert updated.state == :cordoned
      refute Task.yield(awaiter, 100)

      node
      |> Ecto.Changeset.change(state: :active)
      |> Repo.update!()

      later = DateTime.add(DateTime.utc_now(), 1, :second)

      insert_node_from_status!(target, status)
      assert {:ok, active_node} = observe_status(target, status, later)
      assert active_node.state == :active
      assert {:ok, grant} = Task.await(awaiter, 2_000)
      assert grant.queue_result == :queued
      assert grant.queue_key == "cordoned-cold-model@v1"

      assert :ok = QueueManager.release(grant)
    end

    test "SPEC.md §5.5 ineligible heartbeat clears stale cold queue capacity" do
      QueueManager.reset()

      node_id = Ecto.UUID.generate()

      node =
        insert_node!(%{
          id: node_id,
          state: :active,
          health: :healthy,
          advertise_addr: "10.0.0.63",
          rpc_port: 9444
        })

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-stale-cold-capacity-a", "stale-cold-model"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-stale-cold-capacity-b", "stale-cold-model"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_stale_cold_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      target = make_target("10.0.0.63", 9444)

      healthy_status =
        make_status_response(%{
          node_id: node_id,
          listen_host: "10.0.0.63",
          listen_port: 9444
        })
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      assert {:ok, _active_node} =
               observe_status(target, healthy_status, DateTime.utc_now())

      assert_receive {:first_stale_cold_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      node
      |> Ecto.Changeset.change(state: :cordoned)
      |> Repo.update!()

      later = DateTime.add(DateTime.utc_now(), 1, :second)

      insert_node_from_status!(target, healthy_status)
      assert {:ok, cordoned_node} = observe_status(target, healthy_status, later)
      assert cordoned_node.state == :cordoned
      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      cordoned_node
      |> Ecto.Changeset.change(state: :active)
      |> Repo.update!()

      newest = DateTime.add(later, 1, :second)

      insert_node_from_status!(target, healthy_status)
      assert {:ok, _active_node} = observe_status(target, healthy_status, newest)
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued
      assert second_grant.queue_key == "stale-cold-model@v1"

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "SPEC.md §5.5 invalid placement max concurrency does not wake queued admission" do
      QueueManager.reset()

      assert {:queued, ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-invalid-placement-capacity",
                   "invalid-cap-model"
                 ),
                 config: queue_config(capacity: 0)
               )

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      target = make_target("10.0.0.58", 9444)

      invalid_status =
        placement_status("10.0.0.58", "invalid-cap-model", max_concurrency: 0)

      insert_node_from_status!(target, invalid_status)
      assert {:ok, _node} = observe_status(target, invalid_status, DateTime.utc_now())
      refute Task.yield(awaiter, 100)

      valid_status =
        put_in(
          invalid_status,
          [:runtime_model_placements, Access.at(0), :max_concurrency],
          1
        )

      insert_node_from_status!(target, valid_status)
      assert {:ok, _node} = observe_status(target, valid_status, DateTime.utc_now())
      assert {:ok, grant} = Task.await(awaiter, 2_000)
      assert grant.queue_result == :queued

      assert :ok = QueueManager.release(grant)
    end

    test "SPEC.md §5.5 runtime endpoint observation refreshes placement queue capacity" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-observation-placement-a",
                   "observation-placement"
                 ),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-observation-placement-b",
                   "observation-placement"
                 ),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_observation_placement_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      target = make_target("10.0.0.93", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.93", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 2)
        |> Map.put(:loaded_models, [%{model_id: "observation-placement", version: "v1"}])
        |> Map.put(:runtime_model_placements, [
          %{
            model_ref: %{model_id: "observation-placement", version: "v1"},
            active_request_count: 0,
            max_concurrency: 2
          }
        ])

      observation = GrpcCompatibilityMapper.observation_from_status(target, status)

      insert_node_from_status!(target, observation)
      assert {:ok, _node} = observe_status(target, observation, DateTime.utc_now())
      assert_receive {:first_observation_placement_result, {:ok, first_grant}}, 2_000
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued
      assert second_grant.queue_key == "observation-placement@v1"

      assert :ok = QueueManager.release(first_grant)
      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "SPEC.md §5.5 BEAM runtime endpoint observation persists node capacity" do
      QueueManager.reset()

      node_id = Ecto.UUID.generate()
      model_ref = ModelRef.new!("beam-observation-placement", "v1")
      target = Target.beam(node_id, address: :orchard_node_agent@localhost)

      assert {:queued, ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-beam-observation-placement",
                   "beam-observation-placement"
                 ),
                 config: queue_config(capacity: 0)
               )

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)

      observation =
        Observation.new(%{
          endpoint_id: target.id,
          target: target,
          availability: :available,
          aggregate_active_request_count: 0,
          aggregate_max_concurrency: 1,
          metadata: %{
            node_id: node_id,
            display_name: "beam-observation-node",
            hostname: "beam-observation.local",
            listen_host: "10.0.0.95",
            listen_port: 9444
          },
          health: %{ready: true},
          placements: [
            Placement.new(%{
              model_ref: model_ref,
              state: :loaded,
              capacity:
                PlacementCapacity.new(%{
                  model_ref: model_ref,
                  active_request_count: 0,
                  max_concurrency: 1,
                  source: :beam_runtime_endpoint_status
                })
            })
          ]
        })

      insert_node_from_status!(target, observation)
      assert {:ok, node} = observe_status(target, observation, DateTime.utc_now())
      assert node.id == node_id
      assert node.advertise_addr == "10.0.0.95"
      assert node.rpc_port == 9444

      assert {:ok, grant} = Task.await(awaiter, 2_000)
      assert grant.queue_key == "beam-observation-placement@v1"

      assert :ok = QueueManager.release(grant)
    end

    test "SPEC.md §5.5 address-only BEAM observation does not publish uncleared capacity" do
      QueueManager.reset()

      node_id = Ecto.UUID.generate()
      model_ref = ModelRef.new!("beam-address-only-placement", "v1")

      target =
        Target.normalize(
          transport: :beam,
          id: "source-dev-node-agent",
          address: :orchard_node_agent@localhost
        )

      assert {:queued, ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-beam-address-only-placement",
                   "beam-address-only-placement"
                 ),
                 config: queue_config(capacity: 0, max_wait_ms: 100)
               )

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)

      observation =
        Observation.new(%{
          endpoint_id: target.id,
          target: target,
          availability: :available,
          aggregate_active_request_count: 0,
          aggregate_max_concurrency: 1,
          metadata: %{
            node_id: node_id,
            display_name: "beam-address-only-node",
            hostname: "beam-address-only.local",
            listen_host: "10.0.0.96",
            listen_port: 9444
          },
          health: %{ready: true},
          placements: [
            Placement.new(%{
              model_ref: model_ref,
              state: :loaded,
              capacity:
                PlacementCapacity.new(%{
                  model_ref: model_ref,
                  active_request_count: 0,
                  max_concurrency: 1,
                  source: :beam_runtime_endpoint_status
                })
            })
          ]
        })

      insert_node_from_status!(target, observation)
      assert {:ok, node} = observe_status(target, observation, DateTime.utc_now())
      assert node.id == node_id
      assert {:error, :queue_timeout, metadata} = Task.await(awaiter, 2_000)
      assert metadata.queue_result == :queue_timeout
    end

    test "SPEC.md §5.5 unavailable runtime endpoint observation clears queue capacity" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-unavailable-observation-a",
                   "unavailable-observation"
                 ),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-unavailable-observation-b",
                   "unavailable-observation"
                 ),
                 config: queue_config(capacity: 0)
               )

      first_awaiter =
        start_holding_awaiter(first_ticket, :first_unavailable_observation_result)

      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      target = make_target("10.0.0.94", 9444)
      observed_at = DateTime.utc_now()

      status =
        make_status_response(%{listen_host: "10.0.0.94", listen_port: 9444})
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      observation = GrpcCompatibilityMapper.observation_from_status(target, status)

      insert_node_from_status!(target, observation)
      assert {:ok, _node} = observe_status(target, observation, observed_at)
      assert_receive {:first_unavailable_observation_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      unavailable_observation = %{observation | availability: :unavailable}

      assert {:ok, _node} =
               observe_status(
                 target,
                 unavailable_observation,
                 DateTime.add(observed_at, 1, :second)
               )

      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      assert {:ok, _node} =
               observe_status(target, observation, DateTime.add(observed_at, 2, :second))

      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued
      assert second_grant.queue_key == "unavailable-observation@v1"

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "SPEC.md §5.4 exhausted placement status does not publish queued capacity" do
      QueueManager.reset()

      assert {:queued, ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-exhausted-placement-capacity", "full-model"),
                 config: queue_config(capacity: 0)
               )

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      target = make_target("10.0.0.76", 9444)

      full_status =
        placement_status("10.0.0.76", "full-model", max_concurrency: 1)
        |> Map.put(:active_request_count, 1)
        |> Map.put(:max_concurrency, 1)
        |> put_in([:runtime_model_placements, Access.at(0), :active_request_count], 1)

      insert_node_from_status!(target, full_status)
      assert {:ok, _node} = observe_status(target, full_status, DateTime.utc_now())
      refute Task.yield(awaiter, 100)

      available_status =
        full_status
        |> Map.put(:active_request_count, 0)
        |> put_in([:runtime_model_placements, Access.at(0), :active_request_count], 0)

      insert_node_from_status!(target, available_status)
      assert {:ok, _node} = observe_status(target, available_status, DateTime.utc_now())
      assert {:ok, grant} = Task.await(awaiter, 2_000)
      assert grant.queue_result == :queued
      assert grant.queue_key == "full-model@v1"

      assert :ok = QueueManager.release(grant)
    end

    test "SPEC.md §5.4 non-loaded placement status clears stale queued capacity" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-placement-clear-a", "clear-model"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-placement-clear-b", "clear-model"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_clear_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)

      loaded_status =
        placement_status("10.0.0.55", "clear-model", max_concurrency: 1)

      target = make_target("10.0.0.55", 9444)
      insert_node_from_status!(target, loaded_status)
      assert {:ok, _node} = observe_status(target, loaded_status, DateTime.utc_now())
      assert_receive {:first_clear_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      cached_status =
        put_in(
          loaded_status,
          [:runtime_model_placements, Access.at(0), :placement_state],
          :PLACEMENT_STATE_CACHED
        )

      insert_node_from_status!(target, cached_status)
      assert {:ok, _node} = observe_status(target, cached_status, DateTime.utc_now())
      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      reloaded_status =
        put_in(
          cached_status,
          [:runtime_model_placements, Access.at(0), :placement_state],
          :PLACEMENT_STATE_LOADED
        )

      insert_node_from_status!(target, reloaded_status)
      assert {:ok, _node} = observe_status(target, reloaded_status, DateTime.utc_now())
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "SPEC.md §5.4 omitted placement status clears stale queued capacity" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-placement-omitted-a", "omitted-model"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-placement-omitted-b", "omitted-model"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_omitted_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)

      target = make_target("10.0.0.57", 9444)
      loaded_status = placement_status("10.0.0.57", "omitted-model", max_concurrency: 1)

      insert_node_from_status!(target, loaded_status)
      assert {:ok, _node} = observe_status(target, loaded_status, DateTime.utc_now())
      assert_receive {:first_omitted_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      omitted_status = Map.put(loaded_status, :runtime_model_placements, [])

      insert_node_from_status!(target, omitted_status)
      assert {:ok, _node} = observe_status(target, omitted_status, DateTime.utc_now())
      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      insert_node_from_status!(target, loaded_status)
      assert {:ok, _node} = observe_status(target, loaded_status, DateTime.utc_now())
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "SPEC.md §5.5 active loaded model without placement capacity does not wake as cold" do
      QueueManager.reset()

      assert {:queued, ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-loaded-missing-placement", "loaded-missing"),
                 config: queue_config(capacity: 0)
               )

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      target = make_target("10.0.0.92", 9444)
      observed_at = DateTime.utc_now()

      missing_placement_status =
        make_status_response(%{listen_host: "10.0.0.92", listen_port: 9444})
        |> Map.put(:active_request_count, 1)
        |> Map.put(:max_concurrency, 2)
        |> Map.put(:loaded_models, [%{model_id: "loaded-missing", version: "v1"}])
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, missing_placement_status)
      assert {:ok, _node} = observe_status(target, missing_placement_status, observed_at)
      refute Task.yield(awaiter, 100)

      placement_status =
        missing_placement_status
        |> Map.put(:runtime_model_placements, [
          %{
            model_ref: %{model_id: "loaded-missing", version: "v1"},
            active_request_count: 1,
            max_concurrency: 2
          }
        ])

      assert {:ok, _node} =
               observe_status(
                 target,
                 placement_status,
                 DateTime.add(observed_at, 1, :second)
               )

      assert {:ok, grant} = Task.await(awaiter, 2_000)
      assert grant.queue_result == :queued
      assert grant.queue_key == "loaded-missing@v1"

      assert :ok = QueueManager.release(grant)
    end
  end

  # -- observe_status/3 stale guard --

  describe "observe_status/3 stale guard" do
    test "stale invalid metadata does not clear target queue capacity" do
      QueueManager.reset()

      node_id = Ecto.UUID.generate()
      observed_at = DateTime.utc_now()

      insert_node!(%{
        id: node_id,
        state: :active,
        health: :healthy,
        advertise_addr: "10.0.0.19",
        rpc_port: 9444,
        last_heartbeat_at: observed_at
      })

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-stale-invalid-metadata-a", "stale-meta-model"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-stale-invalid-metadata-b", "stale-meta-model"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_stale_metadata_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      target = make_target("10.0.0.19", 9444)

      status =
        make_status_response(%{
          node_id: node_id,
          listen_host: "10.0.0.19",
          listen_port: 9444
        })
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, DateTime.add(observed_at, 1))
      assert_receive {:first_stale_metadata_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      assert :noop =
               observe_status(
                 target,
                 %{node_metadata: nil, runtime_health: nil},
                 observed_at
               )

      assert :ok = QueueManager.release(first_grant)
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "rejects stale observation" do
      node_id = Ecto.UUID.generate()
      now = DateTime.utc_now()
      earlier = DateTime.add(now, -60, :second)

      existing =
        insert_node!(%{
          id: node_id,
          advertise_addr: "10.0.0.20",
          rpc_port: 9444,
          last_heartbeat_at: now,
          capabilities: %{"worker_backend" => "mlx", "hosted_tools" => []},
          tool_readiness: %{}
        })

      target = make_target("10.0.0.20", 9444)

      status = %{
        node_metadata: %{
          node_id: node_id,
          display_name: existing.display_name,
          hostname: existing.hostname,
          agent_version: "0.2.0",
          listen_host: "10.0.0.20",
          listen_port: 9444,
          worker_backend: "mlx"
        },
        runtime_health: %{ready: true, health_code: "", health_message: ""},
        hosted_tool_capabilities: [
          %{name: "lookup_docs", version: "2026-04-11", adapter_kind: "mcp"}
        ],
        hosted_tool_readiness: [
          %{name: "lookup_docs", version: "2026-04-11", ready: true}
        ]
      }

      assert :noop = observe_status(target, status, earlier)

      reloaded = Repo.get!(Node, node_id)
      assert reloaded.capabilities == existing.capabilities
      assert reloaded.tool_readiness == existing.tool_readiness
    end

    test "rejects equal-timestamp observation" do
      node_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      insert_node!(%{
        id: node_id,
        advertise_addr: "10.0.0.21",
        rpc_port: 9444,
        last_heartbeat_at: now
      })

      target = make_target("10.0.0.21", 9444)

      status =
        make_status_response(%{
          node_id: node_id,
          listen_host: "10.0.0.21",
          listen_port: 9444
        })

      assert :noop = observe_status(target, status, now)
    end
  end

  # -- observe_status/3 identity conflicts --

  describe "observe_status/3 identity conflicts" do
    test "target conflict clears stale target queue capacity" do
      QueueManager.reset()

      node_id = Ecto.UUID.generate()

      insert_node!(%{
        id: node_id,
        state: :active,
        health: :healthy,
        advertise_addr: "10.0.0.29",
        rpc_port: 9444
      })

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-identity-conflict-a",
                   "identity-conflict-model"
                 ),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-identity-conflict-b",
                   "identity-conflict-model"
                 ),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_identity_conflict_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      target = make_target("10.0.0.29", 9444)

      valid_status =
        make_status_response(%{
          node_id: node_id,
          listen_host: "10.0.0.29",
          listen_port: 9444
        })
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, valid_status)
      assert {:ok, _node} = observe_status(target, valid_status, DateTime.utc_now())
      assert_receive {:first_identity_conflict_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      conflicting_status =
        make_status_response(%{
          node_id: Ecto.UUID.generate(),
          listen_host: "10.0.0.29",
          listen_port: 9444
        })
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      log =
        capture_log(fn ->
          assert :noop =
                   observe_status(
                     target,
                     conflicting_status,
                     DateTime.add(DateTime.utc_now(), 1, :second)
                   )
        end)

      assert log =~ "identity conflict"
      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      assert {:ok, _node} =
               observe_status(
                 target,
                 valid_status,
                 DateTime.add(DateTime.utc_now(), 2, :second)
               )

      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "target conflict: same addr:port, different UUID" do
      insert_node!(%{id: Ecto.UUID.generate(), advertise_addr: "10.0.0.30", rpc_port: 9444})
      target = make_target("10.0.0.30", 9444)
      different_id = Ecto.UUID.generate()

      status =
        make_status_response(%{
          node_id: different_id,
          listen_host: "10.0.0.30",
          listen_port: 9444
        })

      log =
        capture_log(fn ->
          assert :noop = observe_status(target, status, DateTime.utc_now())
        end)

      assert log =~ "identity conflict"
    end

    test "bind-all advertised target does not conflict when connect target differs" do
      insert_node!(%{
        id: Ecto.UUID.generate(),
        advertise_addr: "0.0.0.0",
        rpc_port: 50_071,
        connect_host: "100.90.207.78",
        connect_port: 50_071
      })

      target = make_target("100.90.207.79", 50_071)
      different_id = Ecto.UUID.generate()

      status =
        make_status_response(%{
          node_id: different_id,
          display_name: "second-bind-all",
          listen_host: "0.0.0.0",
          listen_port: 50_071
        })

      insert_node_from_status!(target, status)
      assert {:ok, node} = observe_status(target, status, DateTime.utc_now())
      assert node.id == different_id
      assert node.advertise_addr == "0.0.0.0"
      assert node.connect_host == "100.90.207.79"
    end

    test "display_name conflict: same name, different UUID" do
      insert_node!(%{display_name: "shared-name", advertise_addr: "10.0.0.31", rpc_port: 9444})
      target = make_target("10.0.0.32", 9444)

      status =
        make_status_response(%{
          node_id: Ecto.UUID.generate(),
          display_name: "shared-name",
          listen_host: "10.0.0.32",
          listen_port: 9444
        })

      log =
        capture_log(fn ->
          assert :noop = observe_status(target, status, DateTime.utc_now())
        end)

      assert log =~ "identity conflict"
    end
  end

  # -- observe_status/3 concurrent insert race --

  describe "observe_status/3 concurrent insert race" do
    test "constraint error on concurrent first-observation returns noop" do
      # Pre-insert a node to provoke a uniqueness conflict when observe_status
      # tries to insert with the same id (simulates a concurrent winner).
      node_id = Ecto.UUID.generate()
      insert_node!(%{id: node_id, advertise_addr: "10.0.0.60", rpc_port: 9444})

      # Now observe with the same id but from a different target — the
      # transaction will lock the existing row by id (not by target), see
      # no target conflict, and try to update. But if we use a *different*
      # display_name that also already exists, the unique constraint fires.
      target = make_target("10.0.0.61", 9444)

      status =
        make_status_response(%{
          node_id: Ecto.UUID.generate(),
          display_name: "unique-for-race",
          listen_host: "10.0.0.61",
          listen_port: 9444
        })

      # Insert a node at the same target to cause a constraint error on insert
      insert_node!(%{advertise_addr: "10.0.0.61", rpc_port: 9444, display_name: "occupant"})

      # The observe should noop due to target identity conflict
      log =
        capture_log(fn ->
          assert :noop = observe_status(target, status, DateTime.utc_now())
        end)

      assert log =~ "identity conflict"
    end
  end

  # -- observe_status/3 missing/invalid metadata --

  describe "observe_status/3 missing metadata" do
    test "invalid metadata clears stale target queue capacity" do
      QueueManager.reset()

      node_id = Ecto.UUID.generate()

      insert_node!(%{
        id: node_id,
        state: :active,
        health: :healthy,
        advertise_addr: "10.0.0.43",
        rpc_port: 9444
      })

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-invalid-metadata-a", "invalid-meta-model"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-invalid-metadata-b", "invalid-meta-model"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_invalid_metadata_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      target = make_target("10.0.0.43", 9444)

      valid_status =
        make_status_response(%{
          node_id: node_id,
          listen_host: "10.0.0.43",
          listen_port: 9444
        })
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, valid_status)
      assert {:ok, _node} = observe_status(target, valid_status, DateTime.utc_now())
      assert_receive {:first_invalid_metadata_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      assert :noop =
               observe_status(
                 target,
                 %{node_metadata: nil, runtime_health: nil},
                 DateTime.add(DateTime.utc_now(), 1, :second)
               )

      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      assert {:ok, _node} =
               observe_status(
                 target,
                 valid_status,
                 DateTime.add(DateTime.utc_now(), 2, :second)
               )

      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "map-shaped invalid metadata clears stale target queue capacity" do
      invalid_statuses = [
        {%{node_metadata: %{}, runtime_health: nil}, "10.0.0.44", "empty-map"},
        {%{node_metadata: %{"node_id" => Ecto.UUID.generate()}, runtime_health: nil}, "10.0.0.45",
         "string-keyed"}
      ]

      Enum.each(invalid_statuses, fn {invalid_status, host, suffix} ->
        QueueManager.reset()

        node_id = Ecto.UUID.generate()

        insert_node!(%{
          id: node_id,
          state: :active,
          health: :healthy,
          advertise_addr: host,
          rpc_port: 9444
        })

        assert {:queued, first_ticket} =
                 QueueManager.acquire(
                   queue_admission_request(
                     "req-node-invalid-map-metadata-a-#{suffix}",
                     "invalid-map-meta-model-#{suffix}"
                   ),
                   config: queue_config(capacity: 0)
                 )

        assert {:queued, second_ticket} =
                 QueueManager.acquire(
                   queue_admission_request(
                     "req-node-invalid-map-metadata-b-#{suffix}",
                     "invalid-map-meta-model-#{suffix}"
                   ),
                   config: queue_config(capacity: 0)
                 )

        first_awaiter = start_holding_awaiter(first_ticket, {:first_invalid_map_result, suffix})
        second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
        target = make_target(host, 9444)

        valid_status =
          make_status_response(%{
            node_id: node_id,
            listen_host: host,
            listen_port: 9444
          })
          |> Map.put(:active_request_count, 0)
          |> Map.put(:max_concurrency, 1)
          |> Map.put(:runtime_model_placements, [])

        insert_node_from_status!(target, valid_status)
        assert {:ok, _node} = observe_status(target, valid_status, DateTime.utc_now())
        assert_receive {{:first_invalid_map_result, ^suffix}, {:ok, first_grant}}, 2_000
        refute Task.yield(second_awaiter, 50)

        assert :noop =
                 observe_status(
                   target,
                   invalid_status,
                   DateTime.add(DateTime.utc_now(), 1, :second)
                 )

        assert :ok = QueueManager.release(first_grant)
        refute Task.yield(second_awaiter, 100)

        assert {:ok, _node} =
                 observe_status(
                   target,
                   valid_status,
                   DateTime.add(DateTime.utc_now(), 2, :second)
                 )

        assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
        assert second_grant.queue_result == :queued

        assert :ok = QueueManager.release(second_grant)
        send(first_awaiter, :stop)
      end)
    end

    test "nil node_metadata returns noop" do
      target = make_target("10.0.0.40", 9444)
      status = %{node_metadata: nil, runtime_health: nil}

      assert :noop = observe_status(target, status, DateTime.utc_now())
      assert Nodes.list_nodes() == []
    end

    test "invalid UUID returns noop" do
      target = make_target("10.0.0.41", 9444)

      status =
        make_status_response(%{node_id: "not-a-uuid", listen_host: "10.0.0.41"})

      assert :noop = observe_status(target, status, DateTime.utc_now())
      assert Nodes.list_nodes() == []
    end

    test "empty display_name and hostname returns noop" do
      target = make_target("10.0.0.42", 9444)

      status =
        make_status_response(%{
          display_name: "",
          hostname: "",
          listen_host: "10.0.0.42"
        })

      assert :noop = observe_status(target, status, DateTime.utc_now())
      assert Nodes.list_nodes() == []
    end
  end

  # -- mark_target_unreachable/2 --

  describe "mark_target_unreachable/2" do
    test "marks fresh transport failures as degraded" do
      hb_time = DateTime.utc_now()

      node =
        insert_node!(%{
          advertise_addr: "10.0.0.50",
          rpc_port: 9444,
          health: :healthy,
          last_heartbeat_at: hb_time
        })

      observed_at = DateTime.add(hb_time, 5, :second)

      assert {:ok, marked} =
               Nodes.mark_target_unreachable(make_target("10.0.0.50", 9444), observed_at)

      assert marked.id == node.id
      assert marked.health == :degraded
    end

    test "marks node by connect target when advertised address is bind-all" do
      hb_time = DateTime.utc_now()

      node =
        insert_node!(%{
          advertise_addr: "0.0.0.0",
          rpc_port: 50_071,
          connect_host: "100.90.207.78",
          connect_port: 50_071,
          health: :healthy,
          last_heartbeat_at: hb_time
        })

      observed_at = DateTime.add(hb_time, 5, :second)

      assert {:ok, marked} =
               Nodes.mark_target_unreachable(make_target("100.90.207.78", 50_071), observed_at)

      assert marked.id == node.id
      assert marked.health == :degraded
    end

    test "marks stale transport failures as unreachable after threshold" do
      hb_time = DateTime.utc_now()

      insert_node!(%{
        advertise_addr: "10.0.0.51",
        rpc_port: 9444,
        health: :healthy,
        last_heartbeat_at: hb_time
      })

      observed_at = DateTime.add(hb_time, Nodes.unreachable_threshold_ms() + 1_000, :millisecond)

      assert {:ok, marked} =
               Nodes.mark_target_unreachable(make_target("10.0.0.51", 9444), observed_at)

      assert marked.health == :unreachable
    end

    test "unreachable queue cleanup runs after health transaction commits" do
      Process.put(:nodes_test_queue_probe_pid, self())
      put_queue_manager_impl(Orchard.NodesTest.TransactionProbeQueueManager)
      hb_time = DateTime.utc_now()

      node =
        insert_node!(%{
          advertise_addr: "10.0.0.67",
          rpc_port: 9444,
          health: :healthy,
          last_heartbeat_at: hb_time
        })

      observed_at = DateTime.add(hb_time, Nodes.unreachable_threshold_ms() + 1_000, :millisecond)

      assert {:ok, marked} =
               Nodes.mark_target_unreachable(make_target("10.0.0.67", 9444), observed_at)

      assert marked.health == :unreachable

      assert_receive {:queue_capacity_clear, sources, opts, false}

      assert Enum.sort(sources) ==
               Enum.sort([
                 {:node, node.id},
                 {:node, node.id, :cold},
                 {:node, node.id, :placement}
               ])

      assert Keyword.fetch!(opts, :promote?) == true
    end

    test "SPEC.md §5.5 unreachable transport failure clears stale cold queue capacity" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-unreachable-capacity-a", "unreachable-model"),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-node-unreachable-capacity-b", "unreachable-model"),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_unreachable_capacity_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      node_id = Ecto.UUID.generate()
      target = make_target("10.0.0.68", 9444)
      heartbeat_at = DateTime.utc_now()

      status =
        make_status_response(%{
          node_id: node_id,
          listen_host: "10.0.0.68",
          listen_port: 9444
        })
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, heartbeat_at)
      assert_receive {:first_unreachable_capacity_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      unreachable_at =
        DateTime.add(heartbeat_at, Nodes.unreachable_threshold_ms() + 1_000, :millisecond)

      assert {:ok, unreachable_node} = Nodes.mark_target_unreachable(target, unreachable_at)
      assert unreachable_node.health == :unreachable

      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      restored_at = DateTime.add(unreachable_at, 1, :second)

      insert_node_from_status!(target, status)
      assert {:ok, restored_node} = observe_status(target, status, restored_at)
      assert restored_node.health == :healthy
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued
      assert second_grant.queue_key == "unreachable-model@v1"

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "SPEC.md §5.5 scheduler transport failure clears stale cold queue capacity" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-scheduler-transport-capacity-a",
                   "transport-failure-model"
                 ),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-scheduler-transport-capacity-b",
                   "transport-failure-model"
                 ),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_transport_capacity_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      node_id = Ecto.UUID.generate()
      target = make_target("10.0.0.69", 9444)
      heartbeat_at = DateTime.utc_now()

      status =
        make_status_response(%{
          node_id: node_id,
          listen_host: "10.0.0.69",
          listen_port: 9444
        })
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, heartbeat_at)
      assert_receive {:first_transport_capacity_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      unreachable_at =
        DateTime.add(heartbeat_at, Nodes.unreachable_threshold_ms() + 1_000, :millisecond)

      assert {:ok, unreachable_node} =
               Nodes.record_transport_failure(
                 target,
                 {:connect_failed, :econnrefused},
                 unreachable_at
               )

      assert unreachable_node.health == :unreachable

      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      restored_at = DateTime.add(unreachable_at, 1, :second)

      insert_node_from_status!(target, status)
      assert {:ok, restored_node} = observe_status(target, status, restored_at)
      assert restored_node.health == :healthy
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued
      assert second_grant.queue_key == "transport-failure-model@v1"

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "SPEC.md §5.5 scheduler transport failure clears stale placement queue capacity" do
      QueueManager.reset()

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-scheduler-placement-failure-a",
                   "transport-placement-model"
                 ),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-scheduler-placement-failure-b",
                   "transport-placement-model"
                 ),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_transport_placement_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      target = make_target("10.0.0.70", 9444)
      heartbeat_at = DateTime.utc_now()

      status = placement_status("10.0.0.70", "transport-placement-model", max_concurrency: 1)

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, heartbeat_at)
      assert_receive {:first_transport_placement_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      unreachable_at =
        DateTime.add(heartbeat_at, Nodes.unreachable_threshold_ms() + 1_000, :millisecond)

      assert {:ok, unreachable_node} =
               Nodes.record_transport_failure(
                 target,
                 {:connect_failed, :econnrefused},
                 unreachable_at
               )

      assert unreachable_node.health == :unreachable

      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      restored_at = DateTime.add(unreachable_at, 1, :second)

      insert_node_from_status!(target, status)
      assert {:ok, restored_node} = observe_status(target, status, restored_at)
      assert restored_node.health == :healthy
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued
      assert second_grant.queue_key == "transport-placement-model@v1"

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "marks nodes with nil heartbeat as unreachable" do
      insert_node!(%{
        advertise_addr: "10.0.0.52",
        rpc_port: 9444,
        health: :healthy,
        last_heartbeat_at: nil
      })

      assert {:ok, marked} =
               Nodes.mark_target_unreachable(make_target("10.0.0.52", 9444), DateTime.utc_now())

      assert marked.health == :unreachable
    end

    test "preserves unhealthy nodes on fresh transport failure" do
      hb_time = DateTime.utc_now()

      insert_node!(%{
        advertise_addr: "10.0.0.53",
        rpc_port: 9444,
        health: :unhealthy,
        last_heartbeat_at: hb_time
      })

      observed_at = DateTime.add(hb_time, 5, :second)

      assert {:ok, marked} =
               Nodes.mark_target_unreachable(make_target("10.0.0.53", 9444), observed_at)

      assert marked.health == :unhealthy
    end

    test "preserves state and last_heartbeat_at" do
      hb_time = DateTime.utc_now()

      insert_node!(%{
        advertise_addr: "10.0.0.54",
        rpc_port: 9444,
        state: :cordoned,
        health: :healthy,
        last_heartbeat_at: hb_time
      })

      observed_at = DateTime.add(hb_time, 5, :second)

      assert {:ok, marked} =
               Nodes.mark_target_unreachable(make_target("10.0.0.54", 9444), observed_at)

      assert marked.state == :cordoned
      assert DateTime.compare(marked.last_heartbeat_at, hb_time) == :eq
      assert marked.health == :degraded
    end

    test "returns noop for unknown target" do
      assert :noop =
               Nodes.mark_target_unreachable(make_target("10.0.0.99", 9444), DateTime.utc_now())
    end

    test "stale or equal failure observations are ignored" do
      now = DateTime.utc_now()
      earlier = DateTime.add(now, -60, :second)

      insert_node!(%{
        advertise_addr: "10.0.0.55",
        rpc_port: 9444,
        health: :healthy,
        last_heartbeat_at: now
      })

      assert :noop = Nodes.mark_target_unreachable(make_target("10.0.0.55", 9444), earlier)
      assert :noop = Nodes.mark_target_unreachable(make_target("10.0.0.55", 9444), now)
    end
  end

  # -- record_transport_failure/3 --

  describe "record_transport_failure/3" do
    test "fresh node + :node_timeout → degraded" do
      hb_time = DateTime.utc_now()

      node =
        insert_node!(%{
          advertise_addr: "10.0.0.70",
          rpc_port: 9444,
          health: :healthy,
          last_heartbeat_at: hb_time
        })

      observed_at = DateTime.add(hb_time, 5, :second)

      assert {:ok, marked} =
               Nodes.record_transport_failure(
                 make_target("10.0.0.70", 9444),
                 :node_timeout,
                 observed_at
               )

      assert marked.id == node.id
      assert marked.health == :degraded
    end

    test "stale node + {:connect_failed, _} → unreachable" do
      hb_time = DateTime.utc_now()

      insert_node!(%{
        advertise_addr: "10.0.0.71",
        rpc_port: 9444,
        health: :healthy,
        last_heartbeat_at: hb_time
      })

      observed_at = DateTime.add(hb_time, Nodes.unreachable_threshold_ms() + 1_000, :millisecond)

      assert {:ok, marked} =
               Nodes.record_transport_failure(
                 make_target("10.0.0.71", 9444),
                 {:connect_failed, :econnrefused},
                 observed_at
               )

      assert marked.health == :unreachable
    end

    test "connect failure updates persisted health through connect target mismatch" do
      hb_time = DateTime.utc_now()

      node =
        insert_node!(%{
          advertise_addr: "0.0.0.0",
          rpc_port: 50_071,
          connect_host: "100.90.207.78",
          connect_port: 50_071,
          health: :healthy,
          last_heartbeat_at: hb_time
        })

      observed_at = DateTime.add(hb_time, Nodes.unreachable_threshold_ms() + 1_000, :millisecond)

      assert {:ok, marked} =
               Nodes.record_transport_failure(
                 make_target("100.90.207.78", 50_071),
                 {:connect_failed, :econnrefused},
                 observed_at
               )

      assert marked.id == node.id
      assert marked.health == :unreachable
    end

    test ":node_unavailable is classified as transport failure" do
      hb_time = DateTime.utc_now()

      insert_node!(%{
        advertise_addr: "10.0.0.72",
        rpc_port: 9444,
        health: :healthy,
        last_heartbeat_at: hb_time
      })

      observed_at = DateTime.add(hb_time, 5, :second)

      assert {:ok, marked} =
               Nodes.record_transport_failure(
                 make_target("10.0.0.72", 9444),
                 :node_unavailable,
                 observed_at
               )

      assert marked.health == :degraded
    end

    test ":beam_node_unavailable is classified as transport failure" do
      hb_time = DateTime.utc_now()

      insert_node!(%{
        advertise_addr: "10.0.0.73",
        rpc_port: 9444,
        health: :healthy,
        last_heartbeat_at: hb_time
      })

      observed_at = DateTime.add(hb_time, 5, :second)

      assert {:ok, marked} =
               Nodes.record_transport_failure(
                 make_target("10.0.0.73", 9444),
                 :beam_node_unavailable,
                 observed_at
               )

      assert marked.health == :degraded
    end

    test ":beam_node_timeout is classified as transport failure" do
      hb_time = DateTime.utc_now()

      insert_node!(%{
        advertise_addr: "10.0.0.74",
        rpc_port: 9444,
        health: :healthy,
        last_heartbeat_at: hb_time
      })

      observed_at = DateTime.add(hb_time, 5, :second)

      assert {:ok, marked} =
               Nodes.record_transport_failure(
                 make_target("10.0.0.74", 9444),
                 :beam_node_timeout,
                 observed_at
               )

      assert marked.health == :degraded
    end

    test "SPEC.md §4.5 :authenticated_transport_failed is classified as transport failure" do
      hb_time = DateTime.utc_now()

      insert_node!(%{
        advertise_addr: "10.0.0.75",
        rpc_port: 9444,
        health: :healthy,
        last_heartbeat_at: hb_time
      })

      observed_at = DateTime.add(hb_time, 5, :second)

      assert {:ok, marked} =
               Nodes.record_transport_failure(
                 make_target("10.0.0.75", 9444),
                 :authenticated_transport_failed,
                 observed_at
               )

      assert marked.health == :degraded
    end

    test "SPEC.md §4.5 :beam_peer_grant_authorization_unavailable is classified as transport failure" do
      hb_time = DateTime.utc_now()

      insert_node!(%{
        advertise_addr: "10.0.0.76",
        rpc_port: 9444,
        health: :healthy,
        last_heartbeat_at: hb_time
      })

      observed_at = DateTime.add(hb_time, 5, :second)

      assert {:ok, marked} =
               Nodes.record_transport_failure(
                 make_target("10.0.0.76", 9444),
                 :beam_peer_grant_authorization_unavailable,
                 observed_at
               )

      assert marked.health == :degraded
    end

    test "SPEC.md §4.5 seam observation rejections are not transport demotions" do
      hb_time = DateTime.utc_now()

      node =
        insert_node!(%{
          advertise_addr: "10.0.0.77",
          rpc_port: 9444,
          health: :healthy,
          last_heartbeat_at: hb_time
        })

      observed_at = DateTime.add(hb_time, 5, :second)
      target = make_target("10.0.0.77", 9444)

      assert :noop =
               Nodes.record_transport_failure(
                 target,
                 :authenticated_observation_rejected,
                 observed_at
               )

      assert :noop =
               Nodes.record_transport_failure(
                 target,
                 :beam_peer_observation_rejected,
                 observed_at
               )

      assert Repo.get!(Node, node.id).health == :healthy
    end

    test "SPEC.md §5.5 transport failure clears stale queue capacity sources" do
      QueueManager.reset()

      node_id = Ecto.UUID.generate()

      insert_node!(%{
        id: node_id,
        advertise_addr: "10.0.0.74",
        rpc_port: 9444,
        health: :healthy,
        last_heartbeat_at: DateTime.utc_now()
      })

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-failure-clears-capacity-a",
                   "failure-clear-model"
                 ),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-failure-clears-capacity-b",
                   "failure-clear-model"
                 ),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_failure_clear_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      target = make_target("10.0.0.74", 9444)
      observed_at = DateTime.utc_now()

      status =
        make_status_response(%{
          node_id: node_id,
          listen_host: "10.0.0.74",
          listen_port: 9444
        })
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_node_from_status!(target, status)
      assert {:ok, _node} = observe_status(target, status, observed_at)
      assert_receive {:first_failure_clear_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      assert {:ok, marked} =
               Nodes.record_transport_failure(
                 target,
                 :node_timeout,
                 DateTime.add(observed_at, 1, :second)
               )

      assert marked.health == :degraded
      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      assert {:ok, _node} =
               observe_status(target, status, DateTime.add(observed_at, 2, :second))

      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "SPEC.md §5.5 transport failure clears node sources before promotion" do
      QueueManager.reset()

      node_id = Ecto.UUID.generate()

      insert_node!(%{
        id: node_id,
        advertise_addr: "10.0.0.79",
        rpc_port: 9444,
        health: :healthy,
        last_heartbeat_at: DateTime.utc_now()
      })

      assert {:queued, ticket} =
               QueueManager.acquire(
                 queue_admission_request(
                   "req-node-failure-atomic-clear",
                   "failure-atomic-clear-model"
                 ),
                 config: queue_config(capacity: 0)
               )

      assert :ok =
               QueueManager.refresh_capacity("failure-atomic-clear-model", "v1", 1,
                 source: {:node, node_id, :cold}
               )

      tag = make_ref()
      put_ticket_awaiter(ticket, tag)

      target = make_target("10.0.0.79", 9444)
      observed_at = DateTime.utc_now()

      assert {:ok, marked} =
               Nodes.record_transport_failure(
                 target,
                 :node_timeout,
                 DateTime.add(observed_at, 1, :second)
               )

      assert marked.health == :degraded
      refute_receive {^tag, {:ok, _grant}}, 100

      status =
        make_status_response(%{
          node_id: node_id,
          listen_host: "10.0.0.79",
          listen_port: 9444
        })
        |> Map.put(:active_request_count, 0)
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      assert {:ok, _node} =
               observe_status(target, status, DateTime.add(observed_at, 2, :second))

      assert_receive {^tag, {:ok, grant}}, 2_000
      assert :ok = QueueManager.release(grant)
    end

    test "SPEC.md §5.5 BEAM transport failure clears stale queue capacity sources" do
      QueueManager.reset()

      node_id = Ecto.UUID.generate()
      model_id = "beam-failure-clear-model"
      observed_at = DateTime.utc_now()

      insert_node!(%{
        id: node_id,
        advertise_addr: "10.0.0.80",
        rpc_port: 9444,
        health: :healthy,
        last_heartbeat_at: observed_at
      })

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-beam-failure-clear-a", model_id),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-beam-failure-clear-b", model_id),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_beam_failure_clear_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)

      # Both awaiters must be registered before capacity arrives: the queue only
      # grants to a head entry that is already awaiting, so refreshing early can
      # hand the single slot to whichever awaiter registered first.
      assert wait_until(fn -> queue_entry_awaiting?(first_ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(second_ticket) end)

      assert :ok =
               QueueManager.refresh_capacity(model_id, "v1", 1, source: {:node, node_id, :cold})

      assert_receive {:first_beam_failure_clear_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      target = Target.beam(node_id, address: :orchard_node_agent@localhost)

      assert {:ok, marked} =
               Nodes.record_transport_failure(
                 target,
                 :node_timeout,
                 DateTime.add(observed_at, 1, :second)
               )

      assert marked.health == :degraded
      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      assert :ok = QueueManager.refresh_capacity(model_id, "v1", 1, source: {:test, :restore})
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "swallows QueueManager clear exits after marking transport failure" do
      put_queue_manager_impl(Orchard.NodesTest.ExitingQueueManager)

      hb_time = DateTime.utc_now()

      node =
        insert_node!(%{
          advertise_addr: "10.0.0.47",
          rpc_port: 9444,
          health: :healthy,
          last_heartbeat_at: hb_time
        })

      assert {:ok, marked} =
               Nodes.record_transport_failure(
                 make_target("10.0.0.47", 9444),
                 :node_timeout,
                 DateTime.add(hb_time, 5, :second)
               )

      assert marked.id == node.id
      assert marked.health == :degraded
    end

    test "non-transport reason returns :noop without mutating health" do
      hb_time = DateTime.utc_now()

      node =
        insert_node!(%{
          advertise_addr: "10.0.0.73",
          rpc_port: 9444,
          health: :healthy,
          last_heartbeat_at: hb_time
        })

      observed_at = DateTime.add(hb_time, 5, :second)

      assert :noop =
               Nodes.record_transport_failure(
                 make_target("10.0.0.73", 9444),
                 :probe_failed,
                 observed_at
               )

      reloaded = Repo.get!(Orchard.Nodes.Node, node.id)
      assert reloaded.health == :healthy
    end

    test "unknown target returns :noop" do
      assert :noop =
               Nodes.record_transport_failure(
                 make_target("10.0.0.99", 9999),
                 :node_timeout,
                 DateTime.utc_now()
               )
    end
  end

  # -- Schedulable nodes --

  describe "sweep_stale_node_heartbeats/1" do
    test "SPEC.md §4.5 demotes active nodes past unreachable threshold" do
      hb_time = DateTime.utc_now()

      node =
        insert_node!(%{
          advertise_addr: "10.0.0.80",
          rpc_port: 9444,
          state: :active,
          health: :healthy,
          last_heartbeat_at: hb_time
        })

      observed_at = DateTime.add(hb_time, Nodes.unreachable_threshold_ms() + 1_000, :millisecond)

      assert {:ok, 1} = Nodes.sweep_stale_node_heartbeats(observed_at)
      assert Repo.get!(Node, node.id).health == :unreachable
    end

    test "SPEC.md §4.5 does not demote when heartbeat is still within threshold" do
      hb_time = DateTime.utc_now()

      node =
        insert_node!(%{
          advertise_addr: "10.0.0.81",
          rpc_port: 9444,
          state: :active,
          health: :healthy,
          last_heartbeat_at: hb_time
        })

      observed_at = DateTime.add(hb_time, 5, :second)

      assert {:ok, 0} = Nodes.sweep_stale_node_heartbeats(observed_at)
      assert Repo.get!(Node, node.id).health == :healthy
    end

    test "SPEC.md §4.5 leaves sticky unhealthy nodes unchanged" do
      hb_time = DateTime.utc_now()

      node =
        insert_node!(%{
          advertise_addr: "10.0.0.82",
          rpc_port: 9444,
          state: :active,
          health: :unhealthy,
          last_heartbeat_at: hb_time
        })

      observed_at = DateTime.add(hb_time, Nodes.unreachable_threshold_ms() + 1_000, :millisecond)

      assert {:ok, 0} = Nodes.sweep_stale_node_heartbeats(observed_at)
      assert Repo.get!(Node, node.id).health == :unhealthy
    end

    test "SPEC.md §4.5 leaves admitted nodes to the observation seam" do
      hb_time = DateTime.utc_now()

      node =
        insert_node!(%{
          advertise_addr: "10.0.0.83",
          rpc_port: 9444,
          state: :admitted,
          health: :degraded,
          last_heartbeat_at: hb_time
        })

      observed_at = DateTime.add(hb_time, Nodes.unreachable_threshold_ms() + 1_000, :millisecond)

      assert {:ok, 0} = Nodes.sweep_stale_node_heartbeats(observed_at)
      assert Repo.get!(Node, node.id).health == :degraded
    end
  end

  describe "schedulable_nodes/0" do
    test "returns active, healthy nodes within freshness threshold" do
      now = DateTime.utc_now()

      n1 =
        insert_node!(%{
          state: :active,
          health: :healthy,
          last_heartbeat_at: DateTime.add(now, -5, :second)
        })

      _n2 =
        insert_node!(%{
          state: :active,
          health: :healthy,
          last_heartbeat_at: DateTime.add(now, -60, :second)
        })

      result = Nodes.schedulable_nodes()
      assert length(result) == 1
      assert hd(result).id == n1.id
    end

    test "includes degraded nodes" do
      now = DateTime.utc_now()

      n1 =
        insert_node!(%{
          state: :active,
          health: :degraded,
          last_heartbeat_at: DateTime.add(now, -5, :second)
        })

      result = Nodes.schedulable_nodes()
      assert length(result) == 1
      assert hd(result).id == n1.id
    end

    test "excludes non-active states" do
      now = DateTime.utc_now()

      insert_node!(%{
        state: :registered,
        health: :healthy,
        last_heartbeat_at: DateTime.add(now, -5, :second)
      })

      assert Nodes.schedulable_nodes() == []
    end

    test "excludes unhealthy and unreachable" do
      now = DateTime.utc_now()

      insert_node!(%{
        state: :active,
        health: :unhealthy,
        last_heartbeat_at: DateTime.add(now, -5, :second)
      })

      insert_node!(%{
        state: :active,
        health: :unreachable,
        last_heartbeat_at: DateTime.add(now, -5, :second)
      })

      assert Nodes.schedulable_nodes() == []
    end

    test "excludes nodes with nil last_heartbeat_at" do
      insert_node!(%{
        state: :active,
        health: :healthy,
        last_heartbeat_at: nil
      })

      assert Nodes.schedulable_nodes() == []
    end

    test "returns ordered by id" do
      now = DateTime.utc_now()
      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{
        id: id_b,
        state: :active,
        health: :healthy,
        last_heartbeat_at: DateTime.add(now, -1, :second)
      })

      insert_node!(%{
        id: id_a,
        state: :active,
        health: :healthy,
        last_heartbeat_at: DateTime.add(now, -1, :second)
      })

      result = Nodes.schedulable_nodes()
      assert length(result) == 2
      assert Enum.map(result, & &1.id) == [id_a, id_b]
    end
  end
end
