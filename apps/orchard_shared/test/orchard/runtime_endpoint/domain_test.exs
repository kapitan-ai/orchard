defmodule Orchard.RuntimeEndpoint.DomainTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.{
    AcceleratorProviderObservation,
    HostCpuObservation,
    HostInventoryObservation,
    HostNetworkInterfaceObservation,
    HostNetworkObservation
  }

  alias Orchard.RuntimeEndpoint.{
    ModelRef,
    Observation,
    Operation,
    Placement,
    PlacementCapacity,
    Target
  }

  test "known placement capacity can prove spare capacity" do
    capacity =
      PlacementCapacity.new(%{
        model_ref: ModelRef.new!("mlx-community/phi-3", "main"),
        active_request_count: 1,
        max_concurrency: 2,
        source: :compatibility_status
      })

    assert capacity.status == :known
    assert PlacementCapacity.spare?(capacity)
    refute PlacementCapacity.full?(capacity)
  end

  test "placement capacity preserves explicit zero values" do
    capacity =
      PlacementCapacity.new(%{
        "active_request_count" => 1,
        model_ref: ModelRef.new!("mlx-community/phi-3", "main"),
        active_request_count: 0,
        max_concurrency: 2,
        source: :compatibility_status
      })

    assert capacity.status == :known
    assert capacity.active_request_count == 0
    assert PlacementCapacity.spare?(capacity)
  end

  test "known placement capacity can prove full capacity" do
    capacity =
      PlacementCapacity.new(%{
        model_ref: ModelRef.new!("mlx-community/phi-3", "main"),
        active_request_count: 2,
        max_concurrency: 2,
        source: :compatibility_status
      })

    assert capacity.status == :known
    assert PlacementCapacity.full?(capacity)
    refute PlacementCapacity.spare?(capacity)
  end

  test "unknown placement capacity cannot prove eligibility" do
    capacity =
      PlacementCapacity.new(%{
        model_ref: ModelRef.new!("mlx-community/phi-3", "main"),
        source: :missing_compatibility_status
      })

    assert capacity.status == :unknown
    refute PlacementCapacity.spare?(capacity)
    refute PlacementCapacity.full?(capacity)
  end

  test "malformed placement capacity is invalid and cannot prove eligibility" do
    capacity =
      PlacementCapacity.new(%{
        model_ref: ModelRef.new!("mlx-community/phi-3", "main"),
        active_request_count: "1",
        max_concurrency: 0,
        source: :malformed
      })

    assert capacity.status == :invalid
    refute PlacementCapacity.spare?(capacity)
    refute PlacementCapacity.full?(capacity)
  end

  test "runtime endpoint observations expose loaded placement capacity" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")

    observation =
      Observation.new(%{
        target: Target.grpc_compat(host: "127.0.0.1", port: 50_061),
        placements: [
          %{
            model_ref: model_ref,
            state: :loaded,
            capacity: %{
              active_request_count: 1,
              max_concurrency: 2,
              source: :compatibility_status
            }
          }
        ]
      })

    assert %Placement{} = Observation.loaded_placement(observation, model_ref)

    assert PlacementCapacity.spare?(Observation.placement_capacity_for(observation, model_ref))
  end

  test "status observations preserve bounded worker crash counter entries" do
    counters = [%{model_id: "model-a", count: 2, counter_version: "epoch-1"}]
    observation = Observation.new(%{worker_crash_counters: counters})

    assert observation.worker_crash_counters == counters
    assert Observation.new(%{}).worker_crash_counters == []
  end

  describe "SPEC.md §4.1 observation-only host inventory" do
    test "a bounded inventory is preserved and an older observation decodes as absent" do
      inventory = host_inventory(cpu: %HostCpuObservation{architecture: "x86_64"})

      assert Observation.new(%{host_inventory: inventory}).host_inventory == inventory
      assert Observation.new(%{}).host_inventory == nil
    end

    test "an inventory without observation-only authority or the known schema is absent" do
      assert Observation.new(%{
               host_inventory: host_inventory(authority: :HOST_INVENTORY_AUTHORITY_UNSPECIFIED)
             }).host_inventory ==
               nil

      assert Observation.new(%{host_inventory: host_inventory(schema_version: 2)}).host_inventory ==
               nil

      assert Observation.new(%{host_inventory: %{schema_version: 1}}).host_inventory == nil
    end

    test "oversized or malformed inventory is absent rather than truncated" do
      long = String.duplicate("a", 257)
      interface = %HostNetworkInterfaceObservation{name: "eth0"}

      oversized_string = host_inventory(cpu: %HostCpuObservation{model_name: long})
      invalid_utf8 = host_inventory(cpu: %HostCpuObservation{model_name: <<0xFF>>})

      too_many_interfaces =
        host_inventory(
          network: %HostNetworkObservation{interfaces: List.duplicate(interface, 65)}
        )

      duplicate_vendor =
        host_inventory(
          accelerator_providers: [
            %AcceleratorProviderObservation{vendor: :ACCELERATOR_VENDOR_NVIDIA},
            %AcceleratorProviderObservation{vendor: :ACCELERATOR_VENDOR_NVIDIA}
          ]
        )

      for inventory <- [oversized_string, invalid_utf8, too_many_interfaces, duplicate_vendor] do
        assert Observation.new(%{host_inventory: inventory}).host_inventory == nil
      end
    end

    test "malformed or missing raw unknown-field state is absent without raising" do
      valid = host_inventory(cpu: %HostCpuObservation{architecture: "x86_64"})

      malformed = [
        %{valid | __unknown_fields__: :bogus},
        Map.delete(valid, :__unknown_fields__),
        %{valid | __unknown_fields__: [{20, 9, "x"}]},
        %{valid | __unknown_fields__: [{20, 0, 1} | :tail]},
        %{valid | cpu: %{valid.cpu | __unknown_fields__: :bogus}},
        # varint beyond uint64, and a field number beyond the protobuf maximum
        %{valid | __unknown_fields__: [{20, 0, 18_446_744_073_709_551_616}]},
        %{valid | __unknown_fields__: [{536_870_912, 0, 1}]},
        %{valid | __unknown_fields__: [{20, 1, <<1, 2, 3>>}]},
        %{valid | __unknown_fields__: [{20, 3, <<>>}]},
        # lower bounds: field number 0 and a negative varint
        %{valid | __unknown_fields__: [{0, 0, 1}]},
        %{valid | __unknown_fields__: [{20, 0, -1}]},
        # unknown tuples reusing a field number the message defines
        %{valid | __unknown_fields__: [{2, 2, "x"}]},
        %{valid | __unknown_fields__: [{4, 2, <<0xFF>>}]},
        %{valid | cpu: %{valid.cpu | __unknown_fields__: [{3, 2, "x"}]}},
        # known fields of the wrong range or shape
        %{valid | cpu: %{valid.cpu | logical_processor_count: 4_294_967_296}},
        %{valid | accelerator_providers: [%AcceleratorProviderObservation{vendor: :bogus}]}
      ]

      for inventory <- malformed do
        assert Observation.new(%{host_inventory: inventory}).host_inventory == nil
      end
    end

    test "an additive field decoded from a newer writer is preserved" do
      valid = host_inventory(cpu: %HostCpuObservation{architecture: "x86_64"})
      # field 20, varint wire type, value 7
      decoded =
        HostInventoryObservation.decode(
          HostInventoryObservation.encode(valid) <> <<0xA0, 0x01, 0x07>>
        )

      assert decoded.__unknown_fields__ == [{20, 0, 7}]
      assert Observation.new(%{host_inventory: decoded}).host_inventory == decoded

      at_limits = %{
        valid
        | __unknown_fields__: [
            {536_870_911, 0, 18_446_744_073_709_551_615},
            {21, 1, <<0::64>>},
            {22, 2, "x"},
            {23, 5, <<0::32>>}
          ]
      }

      assert Observation.new(%{host_inventory: at_limits}).host_inventory == at_limits
    end

    test "a raw BEAM inventory term with a field this reader does not define is absent" do
      valid = host_inventory(cpu: %HostCpuObservation{architecture: "x86_64"})

      assert Observation.new(%{host_inventory: Map.put(valid, :future_field, 1)}).host_inventory ==
               nil
    end

    test "improper lists from a raw BEAM term are absent without raising" do
      provider = %AcceleratorProviderObservation{vendor: :ACCELERATOR_VENDOR_NVIDIA}

      top_level = host_inventory(accelerator_providers: [provider | :tail])

      nested =
        host_inventory(accelerator_providers: [%{provider | devices: [:device | :tail]}])

      assert Observation.new(%{host_inventory: top_level}).host_inventory == nil
      assert Observation.new(%{host_inventory: nested}).host_inventory == nil
    end
  end

  defp host_inventory(attrs) do
    struct(
      %HostInventoryObservation{
        schema_version: 1,
        observed_at_unix_ms: 1_789_743_600_000,
        authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY
      },
      attrs
    )
  end

  test "SPEC.md §4.6.2 observations preserve aggregate capacity evidence before fallbacks" do
    observation =
      Observation.new(%{
        aggregate_active_request_count: -1,
        aggregate_max_concurrency: "four"
      })

    assert observation.aggregate_active_request_count == 0
    assert observation.aggregate_max_concurrency == nil

    assert observation.aggregate_capacity_evidence == %{
             active_request_count: nil,
             runtime_concurrency_limit: nil,
             validity: :invalid
           }
  end

  test "SPEC.md §4.6.2 a malformed capacity value stays invalid when its pair is missing" do
    malformed_active = Observation.new(%{aggregate_active_request_count: -1})

    assert malformed_active.aggregate_capacity_evidence == %{
             active_request_count: nil,
             runtime_concurrency_limit: nil,
             validity: :invalid
           }

    malformed_limit = Observation.new(%{aggregate_max_concurrency: 0})

    assert malformed_limit.aggregate_capacity_evidence == %{
             active_request_count: nil,
             runtime_concurrency_limit: nil,
             validity: :invalid
           }
  end

  test "SPEC.md §4.6.2 absent capacity values stay missing rather than invalid" do
    observation = Observation.new(%{})

    assert observation.aggregate_capacity_evidence == %{
             active_request_count: nil,
             runtime_concurrency_limit: nil,
             validity: :missing
           }

    partial = Observation.new(%{aggregate_active_request_count: 2})

    assert partial.aggregate_capacity_evidence == %{
             active_request_count: 2,
             runtime_concurrency_limit: nil,
             validity: :missing
           }
  end

  test "target normalization preserves default gRPC fallback and admits explicit BEAM targets" do
    grpc_target = Target.normalize(host: "127.0.0.1", port: 50_071)

    assert grpc_target.transport == :grpc_compat
    assert grpc_target.address == [host: "127.0.0.1", port: 50_071]

    node_id = "550e8400-e29b-41d4-a716-446655440000"

    beam_target =
      Target.normalize(%{
        transport: :beam,
        node_id: node_id,
        address: :orchard_node_agent@localhost,
        metadata: %{role: :node_agent}
      })

    assert beam_target.transport == :beam
    assert beam_target.node_id == node_id
    assert beam_target.address == :orchard_node_agent@localhost
    assert beam_target.metadata == %{role: :node_agent}
  end

  test "BEAM target normalization accepts IP-literal BEAM node-name hosts" do
    ipv4_target =
      Target.normalize(%{
        transport: :beam,
        id: "source-dev-ipv4",
        address: "orchard_node_agent@127.0.0.1"
      })

    assert ipv4_target.address == "orchard_node_agent@127.0.0.1"

    ipv6_target =
      Target.normalize(%{
        transport: :beam,
        id: "source-dev-ipv6",
        address: "orchard_node_agent@::1"
      })

    assert ipv6_target.address == "orchard_node_agent@::1"
  end

  test "BEAM target normalization keeps node_id nil unless explicitly configured" do
    target =
      Target.normalize(%{
        transport: :beam,
        id: "source-dev-node-agent",
        address: :orchard_node_agent@localhost
      })

    assert target.id == "source-dev-node-agent"
    assert target.transport == :beam
    assert target.node_id == nil
    assert target.address == :orchard_node_agent@localhost
  end

  test "prebuilt BEAM target normalization validates and normalizes address" do
    node_id = "550e8400-e29b-41d4-a716-446655440000"

    target =
      Target.normalize(%Target{
        id: "source-dev-node-agent",
        transport: :beam,
        address: "orchard_node_agent@localhost",
        node_id: node_id
      })

    assert target.address == "orchard_node_agent@localhost"
    assert target.node_id == node_id
  end

  test "runtime endpoint observations prefer metadata node identity without target node_id" do
    node_id = "550e8400-e29b-41d4-a716-446655440000"

    observation =
      Observation.new(%{
        target:
          Target.normalize(%{
            transport: :beam,
            id: "source-dev-node-agent",
            address: :orchard_node_agent@localhost
          }),
        metadata: %{node_id: node_id}
      })

    assert Observation.node_id(observation) == node_id
  end

  test "BEAM target normalization rejects configured non-UUID node_id values" do
    assert_raise ArgumentError, fn ->
      Target.normalize(
        transport: :beam,
        node_id: "node-1",
        address: :orchard_node_agent@localhost
      )
    end

    assert_raise ArgumentError, fn ->
      Target.beam("node-1", address: :orchard_node_agent@localhost)
    end

    assert_raise ArgumentError, fn ->
      Target.normalize(%Target{
        id: "source-dev-node-agent",
        transport: :beam,
        address: :orchard_node_agent@localhost,
        node_id: "node-1"
      })
    end
  end

  test "BEAM target construction requires explicit address" do
    assert_raise ArgumentError, fn ->
      Target.beam("550e8400-e29b-41d4-a716-446655440000")
    end
  end

  test "target normalization rejects malformed configured BEAM node names" do
    assert_raise ArgumentError, fn ->
      Target.normalize(
        transport: :beam,
        node_id: "550e8400-e29b-41d4-a716-446655440000",
        address: "not a node"
      )
    end
  end

  test "target normalization rejects malformed atom BEAM node names" do
    assert_raise ArgumentError, fn ->
      Target.normalize(
        transport: :beam,
        node_id: "550e8400-e29b-41d4-a716-446655440000",
        address: :not_a_node
      )
    end
  end

  test "operation constructors validate scalar request shape without enforcing policy" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")

    request =
      Operation.ExecuteRequest.new!(%{
        request_id: "req_123",
        controller_session_id: "session_123",
        model_ref: model_ref,
        rendered_prompt_utf8: "hello",
        input_tokens: 1,
        params: %{max_output_tokens: 4},
        metadata_json: "{}",
        prompt_token_ids: [1, 2, 3],
        tensorfold_history_projection_json: ~s({"schema_version":1}),
        artifact_sha256: "sha256:abc",
        artifact_source_uri: "file:///models/phi-3",
        preload: true
      })

    assert request.model_ref == model_ref
    assert request.prompt_token_ids == [1, 2, 3]
    assert request.tensorfold_history_projection_json == ~s({"schema_version":1})
    assert request.preload
  end

  test "operation constructors preserve explicit false and zero values" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")

    load_request =
      Operation.EnsureModelLoadedRequest.new!(%{
        "preload" => true,
        model_ref: model_ref,
        preload: false
      })

    execute_request =
      Operation.ExecuteRequest.new!(%{
        "input_tokens" => 4,
        request_id: "req_123",
        controller_session_id: "session_123",
        model_ref: model_ref,
        rendered_prompt_utf8: "",
        input_tokens: 0
      })

    refute load_request.preload
    assert execute_request.input_tokens == 0
    assert execute_request.tensorfold_history_projection_json == nil
  end
end
