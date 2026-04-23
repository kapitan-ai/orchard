defmodule Orchard.Scheduler.MultiNodeTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.Inference.CacheAffinity
  alias Orchard.Nodes.Node
  alias Orchard.Scheduler.MultiNode

  # -- Stub Status Client --

  defmodule StubClient do
    @moduledoc false

    @doc """
    Stub client that reads probe results from the process dictionary.

    Set `Process.put({:stub_status, target_key}, response)` before scheduling.
    Target key is `{host, port}`.
    """
    def connect(target) do
      key = {Keyword.fetch!(target, :host), Keyword.fetch!(target, :port)}

      case Process.get({:stub_connect, key}) do
        nil -> {:ok, target}
        error -> error
      end
    end

    def status(target, _opts) do
      key = {Keyword.fetch!(target, :host), Keyword.fetch!(target, :port)}

      case Process.get({:stub_status, key}) do
        nil -> {:error, :unavailable}
        :error -> {:error, :probe_failed}
        {:error, _} = error -> error
        response -> {:ok, response}
      end
    end

    def disconnect(_channel), do: :ok
  end

  # -- Helpers --

  defp canonical_request(model_id \\ "test-model", version \\ "v1", overrides \\ []) do
    CanonicalRequest.new(%{
      internal_id: "int_#{System.unique_integer([:positive])}",
      public_id: "pub_#{System.unique_integer([:positive])}",
      endpoint: :chat_completions,
      tenant_id: Keyword.get(overrides, :tenant_id, Ecto.UUID.generate()),
      model_ref: %ModelRef{model_id: model_id, version: version},
      rendered_prompt: Keyword.get(overrides, :rendered_prompt, "shared system prefix\nhello")
    })
  end

  defp insert_node!(overrides) do
    unique = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          hostname: "host-#{unique}.local",
          display_name: "node-#{unique}",
          advertise_addr: "10.0.0.#{rem(unique, 255)}",
          rpc_port: 9444,
          state: :active,
          health: :healthy,
          capabilities: %{},
          last_heartbeat_at: DateTime.utc_now()
        },
        overrides
      )

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end

  defp make_status(node_id, opts) do
    loaded_models = Keyword.get(opts, :loaded_models, [])
    active_request_count = Keyword.get(opts, :active_request_count, 0)
    health = Keyword.get(opts, :health, nil)
    prefix_cache_statuses = Keyword.get(opts, :runtime_prefix_cache_statuses, [])
    display_name = Keyword.get(opts, :display_name, "node-#{node_id}")
    host = Keyword.get(opts, :host, "10.0.0.1")
    port = Keyword.get(opts, :port, 9444)

    %{
      node_metadata: %{
        node_id: node_id,
        display_name: display_name,
        hostname: "#{display_name}.local",
        agent_version: "0.1.0",
        listen_host: host,
        listen_port: port,
        worker_backend: "mlx"
      },
      runtime_health: health,
      loaded_models: loaded_models,
      active_request_count: active_request_count,
      runtime_prefix_cache_statuses: prefix_cache_statuses
    }
  end

  defp stub_probe(host, port, response) do
    Process.put({:stub_status, {host, port}}, response)
  end

  defp stub_connect_failure(host, port, reason) do
    Process.put({:stub_connect, {host, port}}, {:error, reason})
  end

  defp insert_recent_cache_affinity_request!(
         tenant_id,
         model_id,
         version,
         node_id,
         affinity_key,
         completed_at
       ) do
    create_request!(%{
      tenant_id: tenant_id,
      requested_model: "#{model_id}@#{version}",
      state: :completed,
      stream: false,
      node_id: node_id,
      completed_at: DateTime.truncate(completed_at, :microsecond),
      scheduler_decision: %{"cache_affinity_key" => affinity_key}
    })
  end

  defp prefix_cache_status(model_id, version, attrs) do
    Map.merge(
      %{
        model_ref: %{model_id: model_id, version: version},
        implementation: "kv",
        enabled: true,
        entry_count: 0,
        total_bytes: 0,
        hits: 0,
        misses: 0,
        stores: 0,
        evictions: 0,
        status_code: "ok",
        session_started_unix_ms: 1_713_726_400_000
      },
      attrs
    )
  end

  defp cache_affinity_key!(request) do
    {:ok, key} = CacheAffinity.derive_key(request, Orchard.Inference.cache_affinity_config())
    key
  end

  defp put_inference(overrides) do
    config = Application.fetch_env!(:orchard_controller, :inference)
    Application.put_env(:orchard_controller, :inference, Keyword.merge(config, overrides))
  end

  setup do
    previous = Application.fetch_env!(:orchard_controller, :inference)
    on_exit(fn -> Application.put_env(:orchard_controller, :inference, previous) end)
    :ok
  end

  # -- Delegation to SingleNode --

  describe "single-node delegation" do
    test "delegates to SingleNode when no plural targets configured" do
      put_inference(runtime_client_targets: [])
      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :single_node
    end

    test "delegates to SingleNode when only one target configured" do
      put_inference(runtime_client_targets: [[host: "10.0.0.1", port: 50_061]])
      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :single_node
    end
  end

  # -- Multi-node ranking --

  describe "multi-node scheduling" do
    setup do
      put_inference(
        runtime_client_targets: [
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.2", port: 50_062]
        ]
      )

      :ok
    end

    test "prefers node with loaded model" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id, host: "10.0.0.1", port: 50_061)
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id,
          host: "10.0.0.2",
          port: 50_062,
          loaded_models: [%{model_id: "test-model", version: "v1"}]
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} =
               MultiNode.schedule(request, status_client: StubClient)

      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_b.id
      assert schedule.selected_tier == "loaded"
      assert schedule.candidate_count == 2
    end

    test "hosted tool capability and readiness data do not change inference ranking" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        Map.merge(
          make_status(node_a.id,
            host: "10.0.0.1",
            port: 50_061,
            loaded_models: [%{model_id: "test-model", version: "v1"}]
          ),
          %{
            hosted_tool_capabilities: [
              %{name: "lookup_docs", version: "2026-04-11", adapter_kind: "mcp"}
            ],
            hosted_tool_readiness: [
              %{name: "lookup_docs", version: "2026-04-11", ready: false}
            ]
          }
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        Map.merge(
          make_status(node_b.id, host: "10.0.0.2", port: 50_062),
          %{
            hosted_tool_capabilities: [
              %{name: "lookup_docs", version: "2026-04-11", adapter_kind: "mcp"}
            ],
            hosted_tool_readiness: [
              %{name: "lookup_docs", version: "2026-04-11", ready: true}
            ]
          }
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_a.id
      assert schedule.selected_tier == "loaded"
    end

    test "prefers lower active_request_count when both cold" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          active_request_count: 5
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id,
          host: "10.0.0.2",
          port: 50_062,
          active_request_count: 2
        )
      )

      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_b.id
    end

    test "prefers healthy over degraded when tied" do
      node_a =
        insert_node!(%{
          advertise_addr: "10.0.0.1",
          rpc_port: 50_061,
          health: :degraded
        })

      node_b =
        insert_node!(%{
          advertise_addr: "10.0.0.2",
          rpc_port: 50_062,
          health: :healthy
        })

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          health: %{ready: true, health_code: "warn", health_message: "degraded"}
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_b.id
    end

    test "breaks ties by node_id" do
      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{
        id: id_b,
        advertise_addr: "10.0.0.2",
        rpc_port: 50_062
      })

      insert_node!(%{
        id: id_a,
        advertise_addr: "10.0.0.1",
        rpc_port: 50_061
      })

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_a, host: "10.0.0.1", port: 50_061)
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_b, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == id_a
    end

    test "omits cache-affinity metadata and preserves legacy tie-break when disabled" do
      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == id_a
      refute Map.has_key?(schedule, :cache_affinity_enabled)
      refute Map.has_key?(schedule, :cache_affinity_key)
    end

    test "extracts matched prefix-cache status without changing ranking order" do
      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_a,
          host: "10.0.0.1",
          port: 50_061,
          runtime_prefix_cache_statuses: [
            prefix_cache_status("test-model", "v1", %{
              implementation: "disabled",
              enabled: false,
              status_code: "disabled"
            })
          ]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_b,
          host: "10.0.0.2",
          port: 50_062,
          runtime_prefix_cache_statuses: [
            prefix_cache_status("test-model", "v1", %{entry_count: 99, total_bytes: 9_999})
          ]
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.prefix_cache_status.status_code == "disabled"
      assert schedule.prefix_cache_status.enabled == false
      assert schedule.candidate_count == 2
    end

    test "ignores malformed or non-matching prefix-cache statuses during extraction" do
      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_a,
          host: "10.0.0.1",
          port: 50_061,
          runtime_prefix_cache_statuses: [
            "not a status map",
            prefix_cache_status("other-model", "v1", %{entry_count: 10})
          ]
        )
      )

      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      refute Map.has_key?(schedule, :prefix_cache_status)
    end

    test "uses cache-affinity as a tie-breaker for otherwise equivalent candidates" do
      put_inference(cache_affinity: [enabled: true, max_age_ms: 300_000, max_recent_requests: 8])

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"
      tenant_id = Ecto.UUID.generate()
      request = canonical_request("test-model", "v1", tenant_id: tenant_id)
      affinity_key = cache_affinity_key!(request)

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      insert_recent_cache_affinity_request!(
        tenant_id,
        "test-model",
        "v1",
        id_b,
        affinity_key,
        DateTime.utc_now()
      )

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_b
      assert schedule.cache_affinity_enabled == true
      assert schedule.cache_affinity_key == affinity_key
      assert schedule.cache_affinity_hint_available == true
      assert schedule.cache_affinity_selected_match == true
      assert schedule.cache_affinity_source == "recent_completed_request"
      assert schedule.cache_affinity_candidate_count == 1
      assert schedule.selected_cache_tier == "warm_prefix"
      refute inspect(schedule) =~ request.rendered_prompt
    end

    test "uses live prefix-cache fingerprint before historical cache-affinity" do
      put_inference(
        cache_affinity: [
          enabled: true,
          live_fingerprint_match_enabled: true,
          max_age_ms: 300_000,
          max_recent_requests: 8
        ]
      )

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"
      tenant_id = Ecto.UUID.generate()
      request = canonical_request("test-model", "v1", tenant_id: tenant_id)
      affinity_key = cache_affinity_key!(request)

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      insert_recent_cache_affinity_request!(
        tenant_id,
        "test-model",
        "v1",
        id_a,
        affinity_key,
        DateTime.utc_now()
      )

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_b,
          host: "10.0.0.2",
          port: 50_062,
          runtime_prefix_cache_statuses: [
            prefix_cache_status("test-model", "v1", %{
              prefix_cache_fingerprints: [affinity_key]
            })
          ]
        )
      )

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_b
      assert schedule.prefix_cache_fingerprint_match? == true
      assert schedule.cache_affinity_hint_available == true
      assert schedule.cache_affinity_selected_match == false
      assert schedule.cache_affinity_candidate_count == 1
    end

    test "does not let live prefix-cache fingerprint outrank health" do
      put_inference(
        cache_affinity: [
          enabled: true,
          live_fingerprint_match_enabled: true,
          max_age_ms: 300_000,
          max_recent_requests: 8
        ]
      )

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"
      request = canonical_request("test-model", "v1")
      affinity_key = cache_affinity_key!(request)

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061, health: :healthy})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062, health: :degraded})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_b,
          host: "10.0.0.2",
          port: 50_062,
          health: %{ready: true, health_code: "warn", health_message: "degraded"},
          runtime_prefix_cache_statuses: [
            prefix_cache_status("test-model", "v1", %{
              prefix_cache_fingerprints: [affinity_key]
            })
          ]
        )
      )

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.prefix_cache_fingerprint_match? == false
    end

    test "marks live fingerprint match false when candidate set does not contain the affinity key" do
      put_inference(
        cache_affinity: [
          enabled: true,
          live_fingerprint_match_enabled: true,
          max_age_ms: 300_000,
          max_recent_requests: 8
        ]
      )

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"
      request = canonical_request("test-model", "v1")
      non_matching = "hmac-sha256:" <> String.duplicate("f", 64)

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_a,
          host: "10.0.0.1",
          port: 50_061,
          runtime_prefix_cache_statuses: [
            prefix_cache_status("test-model", "v1", %{
              prefix_cache_fingerprints: [non_matching]
            })
          ]
        )
      )

      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.prefix_cache_fingerprint_match? == false
    end

    test "ignores live prefix-cache fingerprints when the child flag is disabled" do
      put_inference(
        cache_affinity: [
          enabled: true,
          live_fingerprint_match_enabled: false,
          max_age_ms: 300_000,
          max_recent_requests: 8
        ]
      )

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"
      request = canonical_request("test-model", "v1")
      affinity_key = cache_affinity_key!(request)

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_b,
          host: "10.0.0.2",
          port: 50_062,
          runtime_prefix_cache_statuses: [
            prefix_cache_status("test-model", "v1", %{
              prefix_cache_fingerprints: [affinity_key]
            })
          ]
        )
      )

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      refute Map.has_key?(schedule, :prefix_cache_fingerprint_match?)
    end

    test "does not let cache-affinity outrank active request count" do
      put_inference(cache_affinity: [enabled: true, max_age_ms: 300_000, max_recent_requests: 8])

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"
      tenant_id = Ecto.UUID.generate()
      request = canonical_request("test-model", "v1", tenant_id: tenant_id)
      affinity_key = cache_affinity_key!(request)

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      insert_recent_cache_affinity_request!(
        tenant_id,
        "test-model",
        "v1",
        id_b,
        affinity_key,
        DateTime.utc_now()
      )

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_b, host: "10.0.0.2", port: 50_062, active_request_count: 3)
      )

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.cache_affinity_hint_available == true
      assert schedule.cache_affinity_selected_match == false
      assert schedule.cache_affinity_candidate_count == 1
      assert schedule.selected_cache_tier == "hint_not_selected"
    end

    test "ignores stale cache-affinity placements" do
      put_inference(cache_affinity: [enabled: true, max_age_ms: 1_000, max_recent_requests: 8])

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"
      tenant_id = Ecto.UUID.generate()
      request = canonical_request("test-model", "v1", tenant_id: tenant_id)
      affinity_key = cache_affinity_key!(request)

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      insert_recent_cache_affinity_request!(
        tenant_id,
        "test-model",
        "v1",
        id_b,
        affinity_key,
        DateTime.add(DateTime.utc_now(), -5, :second)
      )

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.cache_affinity_hint_available == false
      assert schedule.cache_affinity_selected_match == false
      assert schedule.cache_affinity_candidate_count == 0
      assert schedule.selected_cache_tier == "no_hint"
    end

    test "falls back to SingleNode when all probes fail" do
      # Don't stub any probes — both will fail
      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :single_node
    end

    test "falls back to SingleNode when probed nodes are not schedulable" do
      node_a =
        insert_node!(%{
          advertise_addr: "10.0.0.1",
          rpc_port: 50_061,
          state: :registered
        })

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id, host: "10.0.0.1", port: 50_061)
      )

      # Second target probe fails
      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :single_node
    end

    test "skips nodes with missing metadata" do
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      # Node A has no metadata
      stub_probe("10.0.0.1", 50_061, %{node_metadata: nil, runtime_health: nil})

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_b.id
      assert schedule.candidate_count == 1
    end

    test "skips nodes with invalid UUID" do
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status("not-a-uuid", host: "10.0.0.1", port: 50_061)
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_b.id
    end

    test "returns dispatch-compatible schedule map" do
      node = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node.id, host: "10.0.0.1", port: 50_061)
      )

      # Second target fails
      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      # Required dispatch keys
      assert is_list(schedule.runtime_client_target)
      assert Keyword.has_key?(schedule.runtime_client_target, :host)
      assert Keyword.has_key?(schedule.runtime_client_target, :port)
      assert is_binary(schedule.request_id)
      assert is_integer(schedule.request_timeout_ms)
      assert is_integer(schedule.model_load_timeout_ms)
      assert is_binary(schedule.node_id)

      # Multi-node metadata (JSON-safe)
      assert schedule.strategy == :multi_node
      assert is_integer(schedule.candidate_count)
      assert schedule.selected_tier in ["loaded", "cold"]
    end

    test "deduplicates identical targets" do
      put_inference(
        runtime_client_targets: [
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.2", port: 50_062]
        ]
      )

      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id, host: "10.0.0.1", port: 50_061)
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :multi_node
      assert schedule.candidate_count == 2
    end
  end

  # -- Edge cases (M3b Session 4) --

  describe "edge case: all nodes degraded" do
    setup do
      put_inference(
        runtime_client_targets: [
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.2", port: 50_062]
        ]
      )

      :ok
    end

    test "still schedules when all nodes are degraded, uses existing ranking" do
      node_a =
        insert_node!(%{
          advertise_addr: "10.0.0.1",
          rpc_port: 50_061,
          health: :degraded
        })

      node_b =
        insert_node!(%{
          advertise_addr: "10.0.0.2",
          rpc_port: 50_062,
          health: :degraded
        })

      # Node B has lower request count — should win among degraded peers
      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          active_request_count: 3,
          health: %{ready: true, health_code: "warn", health_message: "degraded"}
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id,
          host: "10.0.0.2",
          port: 50_062,
          active_request_count: 1,
          health: %{ready: true, health_code: "warn", health_message: "degraded"}
        )
      )

      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_b.id
      assert schedule.candidate_count == 2
    end

    test "prefers loaded model even when all degraded" do
      node_a =
        insert_node!(%{
          advertise_addr: "10.0.0.1",
          rpc_port: 50_061,
          health: :degraded
        })

      node_b =
        insert_node!(%{
          advertise_addr: "10.0.0.2",
          rpc_port: 50_062,
          health: :degraded
        })

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          health: %{ready: true, health_code: "warn", health_message: "degraded"}
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id,
          host: "10.0.0.2",
          port: 50_062,
          health: %{ready: true, health_code: "warn", health_message: "degraded"}
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_a.id
      assert schedule.selected_tier == "loaded"
    end
  end

  describe "edge case: all nodes unreachable" do
    test "falls back to SingleNode when all persisted nodes are unreachable" do
      put_inference(
        runtime_client_targets: [
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.2", port: 50_062]
        ]
      )

      # Nodes exist but are unreachable (not schedulable)
      insert_node!(%{
        advertise_addr: "10.0.0.1",
        rpc_port: 50_061,
        health: :unreachable
      })

      insert_node!(%{
        advertise_addr: "10.0.0.2",
        rpc_port: 50_062,
        health: :unreachable
      })

      # Probes also fail — no stubs configured
      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :single_node
    end
  end

  describe "edge case: mixed legacy and modern agents" do
    setup do
      put_inference(
        runtime_client_targets: [
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.2", port: 50_062]
        ]
      )

      :ok
    end

    test "schedules to modern node when legacy returns no metadata" do
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      # Legacy agent: successful probe but no metadata
      stub_probe("10.0.0.1", 50_061, %{
        node_metadata: nil,
        runtime_health: nil,
        loaded_models: [],
        active_request_count: 0
      })

      # Modern agent: full metadata
      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_b.id
      assert schedule.candidate_count == 1
    end

    test "falls back to SingleNode when all probes return legacy (no metadata)" do
      # Both targets return successful probes but with no metadata
      stub_probe("10.0.0.1", 50_061, %{
        node_metadata: nil,
        runtime_health: nil,
        loaded_models: [],
        active_request_count: 0
      })

      stub_probe("10.0.0.2", 50_062, %{
        node_metadata: nil,
        runtime_health: nil,
        loaded_models: [],
        active_request_count: 0
      })

      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :single_node
    end
  end

  # -- Probe-failure health persistence (M3c Session 1) --

  describe "probe-failure health persistence" do
    setup do
      put_inference(
        runtime_client_targets: [
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.2", port: 50_062]
        ]
      )

      :ok
    end

    test "status transport failure marks fresh node as degraded" do
      now = DateTime.utc_now()
      observed_at = DateTime.add(now, 5, :second)

      node_a =
        insert_node!(%{
          advertise_addr: "10.0.0.1",
          rpc_port: 50_061,
          health: :healthy,
          last_heartbeat_at: now
        })

      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      # Target A: status returns transport failure
      stub_probe("10.0.0.1", 50_061, {:error, :node_timeout})

      # Target B: healthy
      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request()

      assert {:ok, schedule} =
               MultiNode.schedule(request,
                 status_client: StubClient,
                 observed_at: observed_at
               )

      # Node B wins scheduling
      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_b.id

      # Node A health was updated to degraded
      reloaded = Repo.get!(Node, node_a.id)
      assert reloaded.health == :degraded
    end

    test "connect transport failure marks stale node as unreachable" do
      stale_hb = DateTime.add(DateTime.utc_now(), -120_000, :millisecond)
      observed_at = DateTime.utc_now()

      node_a =
        insert_node!(%{
          advertise_addr: "10.0.0.1",
          rpc_port: 50_061,
          health: :healthy,
          last_heartbeat_at: stale_hb
        })

      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      # Target A: connect fails
      stub_connect_failure("10.0.0.1", 50_061, {:connect_failed, :econnrefused})

      # Target B: healthy
      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request()

      assert {:ok, schedule} =
               MultiNode.schedule(request,
                 status_client: StubClient,
                 observed_at: observed_at
               )

      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_b.id

      # Node A marked unreachable (stale heartbeat beyond threshold)
      reloaded = Repo.get!(Node, node_a.id)
      assert reloaded.health == :unreachable
    end

    test "successful probe with missing metadata does NOT mutate failure health" do
      now = DateTime.utc_now()

      node_a =
        insert_node!(%{
          advertise_addr: "10.0.0.1",
          rpc_port: 50_061,
          health: :healthy,
          last_heartbeat_at: now
        })

      # Successful status but no metadata — not a transport failure
      stub_probe("10.0.0.1", 50_061, %{
        node_metadata: nil,
        runtime_health: nil,
        loaded_models: [],
        active_request_count: 0
      })

      # Second target also fails probe (no stub)
      request = canonical_request()

      _schedule =
        MultiNode.schedule(request,
          status_client: StubClient,
          observed_at: DateTime.add(now, 5, :second)
        )

      # Node A health unchanged — no transport failure occurred
      reloaded = Repo.get!(Node, node_a.id)
      assert reloaded.health == :healthy
    end

    test "non-transport status error does not mutate health" do
      now = DateTime.utc_now()

      node_a =
        insert_node!(%{
          advertise_addr: "10.0.0.1",
          rpc_port: 50_061,
          health: :healthy,
          last_heartbeat_at: now
        })

      # :error stub returns {:error, :probe_failed} — not a transport reason
      stub_probe("10.0.0.1", 50_061, :error)

      # Second target also fails
      request = canonical_request()

      _schedule =
        MultiNode.schedule(request,
          status_client: StubClient,
          observed_at: DateTime.add(now, 5, :second)
        )

      # Node A health unchanged
      reloaded = Repo.get!(Node, node_a.id)
      assert reloaded.health == :healthy
    end

    test "mixed cluster: failed target downgraded, healthy target wins scheduling" do
      now = DateTime.utc_now()
      observed_at = DateTime.add(now, 5, :second)

      node_a =
        insert_node!(%{
          advertise_addr: "10.0.0.1",
          rpc_port: 50_061,
          health: :healthy,
          last_heartbeat_at: now
        })

      node_b =
        insert_node!(%{
          advertise_addr: "10.0.0.2",
          rpc_port: 50_062,
          health: :healthy,
          last_heartbeat_at: now
        })

      # Target A: connect fails with transport error
      stub_connect_failure("10.0.0.1", 50_061, :node_timeout)

      # Target B: healthy and schedulable
      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request()

      assert {:ok, schedule} =
               MultiNode.schedule(request,
                 status_client: StubClient,
                 observed_at: observed_at
               )

      # Node B wins
      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_b.id
      assert schedule.candidate_count == 1

      # Node A degraded
      reloaded_a = Repo.get!(Node, node_a.id)
      assert reloaded_a.health == :degraded

      # Node B still healthy
      reloaded_b = Repo.get!(Node, node_b.id)
      assert reloaded_b.health == :healthy
    end
  end

  # -- Fallback target mismatch regression (P1-1 review fix) --

  describe "fallback target mismatch" do
    test "single plural target uses that target, not the singular config" do
      # Plural target differs from singular target
      put_inference(
        runtime_client_targets: [[host: "10.0.0.99", port: 50_099]],
        runtime_client_target: [host: "127.0.0.1", port: 50_071]
      )

      # Insert a node matching the plural target so node_id resolves
      node =
        insert_node!(%{
          advertise_addr: "10.0.0.99",
          rpc_port: 50_099
        })

      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :single_node
      assert schedule.runtime_client_target == [host: "10.0.0.99", port: 50_099]
      assert schedule.node_id == node.id
    end

    test "no-candidate fallback preserves the plural target" do
      put_inference(
        runtime_client_targets: [
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.1", port: 50_061]
        ],
        runtime_client_target: [host: "127.0.0.1", port: 50_071]
      )

      # Both targets are duplicates → dedup to 1 → fallback should use that target
      insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})

      # Probes succeed but nodes are not schedulable (no stubs → probes fail)
      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :single_node
      assert schedule.runtime_client_target == [host: "10.0.0.1", port: 50_061]
    end
  end
end
