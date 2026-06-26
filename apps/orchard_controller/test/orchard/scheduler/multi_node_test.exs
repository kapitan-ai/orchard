defmodule Orchard.Scheduler.MultiNodeTest do
  use Orchard.DataCase, async: false

  import ExUnit.CaptureLog
  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.Cluster.V1.ScorePrefixCacheResponse
  alias Orchard.Inference.CacheAffinity
  alias Orchard.Inference.QueueManager
  alias Orchard.Nodes.Node

  alias Orchard.RuntimeEndpoint.{
    GrpcCompatibilityMapper,
    Observation,
    Placement,
    PlacementCapacity,
    Target
  }

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
      key = target_key(target)

      case Process.get({:stub_connect, key}) do
        nil -> {:ok, target}
        error -> error
      end
    end

    def status(target, opts) do
      key = target_key(target)
      calls = Process.get(:stub_status_calls, [])
      Process.put(:stub_status_calls, [{key, opts} | calls])

      case Process.get({:stub_status, key}) do
        nil -> {:error, :unavailable}
        :error -> {:error, :probe_failed}
        {:error, _} = error -> error
        response -> {:ok, response}
      end
    end

    def disconnect(_channel), do: :ok

    def score_prefix_cache(target, request, _opts) do
      key = target_key(target)
      calls = Process.get(:stub_score_calls, [])
      Process.put(:stub_score_calls, [{key, request} | calls])

      case Process.get({:stub_score, key}) do
        nil -> {:ok, %{status_code: "unavailable", score_tier: "unknown"}}
        {:error, _reason} = error -> error
        response -> {:ok, response}
      end
    end

    def target_key(%Orchard.RuntimeEndpoint.Target{transport: :grpc_compat, address: address}) do
      target_key(address)
    end

    def target_key(%Orchard.RuntimeEndpoint.Target{transport: :beam, id: id}) do
      {:beam, id}
    end

    def target_key(target) do
      {Keyword.fetch!(target, :host), Keyword.fetch!(target, :port)}
    end
  end

  defmodule StubClientWithoutScore do
    @moduledoc false

    def connect(target), do: StubClient.connect(target)
    def status(target, opts), do: StubClient.status(target, opts)
    def disconnect(channel), do: StubClient.disconnect(channel)
  end

  defmodule StubClientDisconnectRaises do
    @moduledoc false

    def connect(target), do: StubClient.connect(target)
    def status(target, opts), do: StubClient.status(target, opts)

    def disconnect(_channel) do
      raise FunctionClauseError, module: __MODULE__, function: :disconnect, arity: 1
    end

    def score_prefix_cache(target, request, opts),
      do: StubClient.score_prefix_cache(target, request, opts)
  end

  defmodule StubClientRaiseScore do
    @moduledoc false

    def connect(target), do: StubClient.connect(target)
    def status(target, opts), do: StubClient.status(target, opts)
    def disconnect(channel), do: StubClient.disconnect(channel)

    def score_prefix_cache(_target, _request, _opts) do
      raise "score call crashed"
    end
  end

  defmodule StubClientExitScore do
    @moduledoc false

    def connect(target), do: StubClient.connect(target)
    def status(target, opts), do: StubClient.status(target, opts)
    def disconnect(channel), do: StubClient.disconnect(channel)

    def score_prefix_cache(_target, _request, _opts) do
      exit(:score_call_exit)
    end
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

  defp queue_admission_request(public_id, model_id \\ "test-model", version \\ "v1") do
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
    max_concurrency = Keyword.get(opts, :max_concurrency, 16)
    health = Keyword.get(opts, :health, nil)
    prefix_cache_statuses = Keyword.get(opts, :runtime_prefix_cache_statuses, [])
    memory_budgets = Keyword.get(opts, :runtime_memory_budgets, [])
    model_placements = Keyword.get(opts, :runtime_model_placements, [])
    supports_prompt_token_ids = Keyword.get(opts, :supports_prompt_token_ids, false)
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
      max_concurrency: max_concurrency,
      runtime_memory_budgets: memory_budgets,
      runtime_prefix_cache_statuses: prefix_cache_statuses,
      runtime_model_placements: model_placements,
      supports_prompt_token_ids: supports_prompt_token_ids
    }
  end

  defp model_placement(model_id, version, active_request_count, max_concurrency) do
    %{
      model_ref: %{model_id: model_id, version: version},
      active_request_count: active_request_count,
      max_concurrency: max_concurrency
    }
  end

  defp stub_probe(host, port, response) do
    Process.put({:stub_status, {host, port}}, response)
  end

  defp stub_probe(%Target{} = target, response) do
    Process.put({:stub_status, StubClient.target_key(target)}, response)
  end

  defp stub_connect_failure(host, port, reason) do
    Process.put({:stub_connect, {host, port}}, {:error, reason})
  end

  defp stub_score(host, port, response) do
    Process.put({:stub_score, {host, port}}, response)
  end

  defp score_calls do
    Process.get(:stub_score_calls, [])
    |> Enum.reverse()
  end

  defp status_calls do
    Process.get(:stub_status_calls, [])
    |> Enum.reverse()
  end

  defp reset_score_calls do
    Process.delete(:stub_score_calls)
  end

  defp put_tie_only_scoring_config(overrides \\ []) do
    put_inference(
      cache_affinity: [
        enabled: true,
        live_fingerprint_match_enabled: true,
        max_age_ms: 300_000,
        max_recent_requests: 8
      ],
      prefix_cache_scoring:
        Keyword.merge(
          [enabled: true, timeout_ms: 123, ranking_mode: :tie_only, max_ranking_candidates: 2],
          overrides
        )
    )
  end

  defp insert_ordered_nodes!(
         id_a \\ "00000000-0000-0000-0000-000000000001",
         id_b \\ "00000000-0000-0000-0000-000000000002"
       ) do
    insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
    insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})
    {id_a, id_b}
  end

  defp set_node_health!(node_id, health) do
    Node
    |> Repo.get!(node_id)
    |> Node.changeset(%{health: health})
    |> Repo.update!()
  end

  defp stub_tied_cold_nodes(id_a, id_b, model_id \\ "test-model", version \\ "v1") do
    stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
    stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))
    canonical_request(model_id, version)
  end

  defp ok_non_resident_score(attrs \\ []) do
    attrs
    |> Map.new()
    |> Map.merge(%{status_code: "ok", resident_fingerprint_match: false, score_tier: "no_match"})
  end

  defp ok_resident_score(attrs \\ []) do
    attrs
    |> Map.new()
    |> Map.merge(%{
      status_code: "ok",
      resident_fingerprint_match: true,
      score_tier: "resident_fingerprint"
    })
  end

  defp non_ok_score(status_code), do: %{status_code: status_code, score_tier: "unknown"}

  defp assert_score_does_not_invert_signal(signal, id_a, id_b) do
    reset_score_calls()
    set_node_health!(id_a, :healthy)
    set_node_health!(id_b, if(signal == :health, do: :degraded, else: :healthy))

    model_id = "test-model-#{signal}"
    version = "v1"
    request = canonical_request(model_id, version)
    affinity_key = cache_affinity_key!(request)

    stub_non_inversion_probes(signal, id_a, id_b, model_id, version, request, affinity_key)
    stub_score("10.0.0.1", 50_061, ok_non_resident_score())
    stub_score("10.0.0.2", 50_062, ok_resident_score())

    assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

    assert schedule.node_id == id_a
    assert [{{"10.0.0.1", 50_061}, _incumbent}] = score_calls()
  end

  defp stub_non_inversion_probes(:loadedness, id_a, id_b, model_id, version, _request, _key) do
    stub_probe(
      "10.0.0.1",
      50_061,
      make_status(id_a,
        host: "10.0.0.1",
        port: 50_061,
        loaded_models: [%{model_id: model_id, version: version}]
      )
    )

    stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))
  end

  defp stub_non_inversion_probes(:active_count, id_a, id_b, _model_id, _version, _request, _key) do
    stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))

    stub_probe(
      "10.0.0.2",
      50_062,
      make_status(id_b, host: "10.0.0.2", port: 50_062, active_request_count: 1)
    )
  end

  defp stub_non_inversion_probes(:health, id_a, id_b, _model_id, _version, _request, _key) do
    stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))

    stub_probe(
      "10.0.0.2",
      50_062,
      make_status(id_b,
        host: "10.0.0.2",
        port: 50_062,
        health: %{ready: true, health_code: "warn", health_message: "degraded"}
      )
    )
  end

  defp stub_non_inversion_probes(:live_fingerprint, id_a, id_b, model_id, version, _request, key) do
    stub_probe(
      "10.0.0.1",
      50_061,
      make_status(id_a,
        host: "10.0.0.1",
        port: 50_061,
        runtime_prefix_cache_statuses: [
          prefix_cache_status(model_id, version, %{prefix_cache_fingerprints: [key]})
        ]
      )
    )

    stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))
  end

  defp stub_non_inversion_probes(
         :historical_affinity,
         id_a,
         id_b,
         model_id,
         version,
         request,
         key
       ) do
    insert_recent_cache_affinity_request!(
      request.tenant_id,
      model_id,
      version,
      id_a,
      key,
      DateTime.utc_now()
    )

    stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
    stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))
  end

  defp stub_non_inversion_probes(:memory_headroom, id_a, id_b, model_id, version, _request, _key) do
    stub_probe(
      "10.0.0.1",
      50_061,
      make_status(id_a,
        host: "10.0.0.1",
        port: 50_061,
        runtime_memory_budgets: [memory_budget(model_id, version, %{})]
      )
    )

    stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))
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

  defp memory_budget(model_id, version, attrs) do
    Map.merge(
      %{
        model_ref: %{model_id: model_id, version: version},
        mode: "observe",
        budget_available: true,
        headroom_available: true,
        status_code: "ok",
        target_working_set_bytes: 8_000,
        resident_memory_bytes: 4_000,
        estimated_headroom_bytes: 4_000,
        kv_cache_bytes_per_token: 1,
        prefill_workspace_bytes_per_token: 2
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
    Process.delete(:stub_status_calls)
    Process.delete(:stub_score_calls)
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

    test "forwards status client options to no-candidate fallback" do
      target = [host: "127.0.0.1", port: 1]

      put_inference(
        runtime_client_targets: [target],
        runtime_client_target: [host: "127.0.0.1", port: 50_071]
      )

      stub_probe(
        "127.0.0.1",
        1,
        make_status(Ecto.UUID.generate(),
          host: "127.0.0.1",
          port: 1,
          health: %{ready: false, health_code: "unhealthy", health_message: "down"},
          active_request_count: 1,
          max_concurrency: 1
        )
      )

      assert {:error, :model_busy} =
               MultiNode.schedule(canonical_request(),
                 status_client: StubClient,
                 status_timeout_ms: 17
               )

      assert status_calls() == [
               {{"127.0.0.1", 1}, [timeout: 17]},
               {{"127.0.0.1", 1}, [timeout: 17]}
             ]
    end

    test "does not re-probe single-node capacity after all probes fail" do
      target = [host: "127.0.0.1", port: 1]

      put_inference(
        runtime_client_targets: [target],
        runtime_client_target: [host: "127.0.0.1", port: 50_071]
      )

      assert {:ok, schedule} =
               MultiNode.schedule(canonical_request(),
                 status_client: StubClient,
                 status_timeout_ms: 17
               )

      assert schedule.strategy == :single_node
      assert schedule.runtime_client_target == target
      assert status_calls() == [{{"127.0.0.1", 1}, [timeout: 17]}]
    end

    test "single BEAM target fallback emits a runtime endpoint schedule" do
      node = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      target = Target.beam(node.id, address: :orchard_node_agent@localhost)

      put_inference(
        runtime_endpoint_targets: [target],
        runtime_client_targets: [],
        runtime_client_target: [host: "127.0.0.1", port: 50_071]
      )

      assert {:ok, schedule} =
               MultiNode.schedule(canonical_request(),
                 status_client: StubClient,
                 status_timeout_ms: 17
               )

      assert schedule.strategy == :single_node
      assert schedule.runtime_endpoint_target == target
      refute Map.has_key?(schedule, :runtime_client_target)
      assert schedule.node_id == node.id
      assert status_calls() == [{{:beam, target.id}, [timeout: 17]}]
    end

    test "returns cluster_busy for one live full target instead of bypassing capacity checks" do
      put_inference(runtime_client_targets: [[host: "10.0.0.1", port: 50_061]])
      node = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node.id,
          host: "10.0.0.1",
          port: 50_061,
          active_request_count: 1,
          max_concurrency: 1
        )
      )

      assert {:error, :cluster_busy} =
               MultiNode.schedule(canonical_request(), status_client: StubClient)
    end

    test "uses spare aggregate capacity for one live cold target" do
      put_inference(runtime_client_targets: [[host: "10.0.0.1", port: 50_061]])
      node = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node.id,
          host: "10.0.0.1",
          port: 50_061,
          active_request_count: 1,
          max_concurrency: 2
        )
      )

      assert {:ok, schedule} = MultiNode.schedule(canonical_request(), status_client: StubClient)
      assert schedule.strategy == :multi_node
      assert schedule.node_id == node.id
      assert schedule.selected_tier == "cold"
      assert schedule.candidate_count == 1
    end

    test "uses runtime endpoint observation aggregate capacity for active cold target" do
      put_inference(runtime_client_targets: [[host: "10.0.0.1", port: 50_061]])
      node = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      target = Target.grpc_compat(host: "10.0.0.1", port: 50_061)

      observation =
        GrpcCompatibilityMapper.observation_from_status(
          target,
          make_status(node.id,
            host: "10.0.0.1",
            port: 50_061,
            active_request_count: 1,
            max_concurrency: 2
          )
        )

      stub_probe("10.0.0.1", 50_061, observation)

      assert {:ok, schedule} = MultiNode.schedule(canonical_request(), status_client: StubClient)
      assert schedule.strategy == :multi_node
      assert schedule.node_id == node.id
      assert schedule.selected_tier == "cold"
      assert schedule.candidate_count == 1
    end

    test "SPEC.md §7.5 excludes unavailable runtime endpoint observations" do
      put_inference(runtime_client_targets: [[host: "10.0.0.1", port: 50_061]])
      node = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      target = Target.grpc_compat(host: "10.0.0.1", port: 50_061)

      observation =
        %{
          GrpcCompatibilityMapper.observation_from_status(
            target,
            make_status(node.id,
              host: "10.0.0.1",
              port: 50_061,
              active_request_count: 0,
              max_concurrency: 16
            )
          )
          | availability: :unavailable
        }

      stub_probe("10.0.0.1", 50_061, observation)

      assert {:error, :cluster_busy} =
               MultiNode.schedule(canonical_request(), status_client: StubClient)
    end

    test "returns cluster_busy for one live cold target at aggregate capacity" do
      put_inference(runtime_client_targets: [[host: "10.0.0.1", port: 50_061]])
      node = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node.id,
          host: "10.0.0.1",
          port: 50_061,
          active_request_count: 2,
          max_concurrency: 2
        )
      )

      assert {:error, :cluster_busy} =
               MultiNode.schedule(canonical_request(), status_client: StubClient)
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

    test "keeps probe candidates when disconnect cleanup raises" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          loaded_models: [%{model_id: "test-model", version: "v1"}]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request("test-model", "v1")

      log =
        capture_log(fn ->
          assert {:ok, schedule} =
                   MultiNode.schedule(request, status_client: StubClientDisconnectRaises)

          send(self(), {:schedule, schedule})
        end)

      assert log =~ "Runtime endpoint disconnect failed"
      assert_receive {:schedule, schedule}
      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_a.id
      assert schedule.selected_tier == "loaded"
      assert schedule.candidate_count == 2
      assert Repo.get!(Node, node_a.id).health == :healthy
      assert Repo.get!(Node, node_b.id).health == :healthy
    end

    test "consumes runtime endpoint observations and preserves legacy dispatch target" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})
      endpoint_target = Target.grpc_compat(host: "10.0.0.1", port: 50_061)

      observation =
        GrpcCompatibilityMapper.observation_from_status(
          endpoint_target,
          make_status(node_a.id,
            host: "10.0.0.1",
            port: 50_061,
            loaded_models: [%{model_id: "test-model", version: "v1"}],
            runtime_model_placements: [model_placement("test-model", "v1", 0, 2)]
          )
        )

      stub_probe("10.0.0.1", 50_061, observation)
      stub_probe("10.0.0.2", 50_062, make_status(node_b.id, host: "10.0.0.2", port: 50_062))

      assert {:ok, schedule} =
               MultiNode.schedule(canonical_request("test-model", "v1"),
                 status_client: StubClient
               )

      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_a.id
      assert schedule.runtime_endpoint_target == endpoint_target
      assert schedule.runtime_client_target == [host: "10.0.0.1", port: 50_061]
      assert schedule.selected_tier == "loaded"
    end

    test "consumes BEAM runtime endpoint observations without legacy dispatch target" do
      node = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      endpoint_target = Target.beam(node.id, address: :orchard_node_agent@localhost)
      model_ref = Orchard.RuntimeEndpoint.ModelRef.new!("test-model", "v1")

      observation =
        Observation.new(%{
          endpoint_id: endpoint_target.id,
          target: endpoint_target,
          availability: :available,
          aggregate_active_request_count: 0,
          aggregate_max_concurrency: 2,
          metadata: %{
            node_id: node.id,
            display_name: node.display_name,
            hostname: node.hostname,
            listen_host: node.advertise_addr,
            listen_port: node.rpc_port
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
                  max_concurrency: 2,
                  source: :beam_runtime_endpoint_status
                })
            })
          ]
        })

      put_inference(runtime_endpoint_targets: [endpoint_target], runtime_client_targets: [])
      stub_probe(endpoint_target, observation)

      assert {:ok, schedule} =
               MultiNode.schedule(canonical_request("test-model", "v1"),
                 status_client: StubClient
               )

      assert schedule.strategy == :multi_node
      assert schedule.node_id == node.id
      assert schedule.runtime_endpoint_target == endpoint_target
      refute Map.has_key?(schedule, :runtime_client_target)
      assert schedule.selected_tier == "loaded"
    end

    test "SPEC.md §7.5 rejects configured BEAM observations before persisting mismatched metadata identity" do
      configured_node = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      reported_node_id = Ecto.UUID.generate()
      endpoint_target = Target.beam(configured_node.id, address: :orchard_node_agent@localhost)
      model_ref = Orchard.RuntimeEndpoint.ModelRef.new!("test-model", "v1")

      observation =
        Observation.new(%{
          endpoint_id: endpoint_target.id,
          target: endpoint_target,
          availability: :available,
          aggregate_active_request_count: 0,
          aggregate_max_concurrency: 2,
          metadata: %{
            node_id: reported_node_id,
            display_name: "reported-beam-mismatch",
            hostname: "reported-beam-mismatch.local",
            listen_host: "10.0.0.2",
            listen_port: 50_062
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
                  max_concurrency: 2,
                  source: :beam_runtime_endpoint_status
                })
            })
          ]
        })

      put_inference(runtime_endpoint_targets: [endpoint_target], runtime_client_targets: [])
      stub_probe(endpoint_target, observation)

      assert {:error, :cluster_busy} =
               MultiNode.schedule(canonical_request("test-model", "v1"),
                 status_client: StubClient
               )

      assert Repo.get(Node, reported_node_id) == nil
    end

    test "SPEC.md §5.5 BEAM identity rejection clears stale cold queue capacity" do
      QueueManager.reset()
      stale_hb = DateTime.add(DateTime.utc_now(), -120_000, :millisecond)
      observed_at = DateTime.utc_now()
      model_id = "beam-identity-clear-model"

      configured_node =
        insert_node!(%{
          advertise_addr: "10.0.0.1",
          rpc_port: 50_061,
          health: :healthy,
          last_heartbeat_at: stale_hb
        })

      reported_node_id = Ecto.UUID.generate()
      endpoint_target = Target.beam(configured_node.id, address: :orchard_node_agent@localhost)
      model_ref = Orchard.RuntimeEndpoint.ModelRef.new!(model_id, "v1")

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-beam-identity-clear-a", model_id),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-beam-identity-clear-b", model_id),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_beam_identity_clear_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)

      assert :ok =
               QueueManager.refresh_capacity(model_id, "v1", 1,
                 source: {:node, configured_node.id, :cold}
               )

      assert_receive {:first_beam_identity_clear_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      observation =
        Observation.new(%{
          endpoint_id: endpoint_target.id,
          target: endpoint_target,
          availability: :available,
          aggregate_active_request_count: 0,
          aggregate_max_concurrency: 2,
          metadata: %{
            node_id: reported_node_id,
            display_name: "reported-beam-mismatch",
            hostname: "reported-beam-mismatch.local",
            listen_host: "10.0.0.2",
            listen_port: 50_062
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
                  max_concurrency: 2,
                  source: :beam_runtime_endpoint_status
                })
            })
          ]
        })

      put_inference(runtime_endpoint_targets: [endpoint_target], runtime_client_targets: [])
      stub_probe(endpoint_target, observation)

      assert {:error, :cluster_busy} =
               MultiNode.schedule(canonical_request(model_id),
                 status_client: StubClient,
                 observed_at: observed_at
               )

      assert Repo.get(Node, reported_node_id) == nil
      assert QueueManager.active_capacity_source_lanes({:node, configured_node.id, :cold}) == []

      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      assert :ok = QueueManager.refresh_capacity(model_id, "v1", 1, source: {:test, :restore})
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_key == "#{model_id}@v1"

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end

    test "address-only BEAM schedules carry observed node identity for failure cleanup" do
      node = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})

      endpoint_target =
        Target.normalize(
          transport: :beam,
          id: "source-dev-node-agent",
          address: :orchard_node_agent@localhost
        )

      model_ref = Orchard.RuntimeEndpoint.ModelRef.new!("test-model", "v1")

      observation =
        Observation.new(%{
          endpoint_id: endpoint_target.id,
          target: endpoint_target,
          availability: :available,
          aggregate_active_request_count: 0,
          aggregate_max_concurrency: 2,
          metadata: %{
            node_id: node.id,
            display_name: node.display_name,
            hostname: node.hostname,
            listen_host: node.advertise_addr,
            listen_port: node.rpc_port
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
                  max_concurrency: 2,
                  source: :beam_runtime_endpoint_status
                })
            })
          ]
        })

      put_inference(runtime_endpoint_targets: [endpoint_target], runtime_client_targets: [])
      stub_probe(endpoint_target, observation)

      assert {:ok, schedule} =
               MultiNode.schedule(canonical_request("test-model", "v1"),
                 status_client: StubClient
               )

      node_id = node.id

      assert schedule.node_id == node.id

      assert %Target{
               id: "source-dev-node-agent",
               transport: :beam,
               address: :orchard_node_agent@localhost,
               node_id: ^node_id
             } = schedule.runtime_endpoint_target
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

    test "keeps active loaded node eligible when matching placement capacity has room" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          active_request_count: 1,
          runtime_model_placements: [model_placement("test-model", "v1", 1, 2)]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_a.id
      assert schedule.selected_tier == "loaded"
      assert schedule.candidate_count == 2
    end

    test "SPEC.md §5.5 queue capacity includes eligible cold nodes when loaded tier wins" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          runtime_model_placements: [model_placement("test-model", "v1", 0, 1)]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id,
          host: "10.0.0.2",
          port: 50_062,
          active_request_count: 0,
          max_concurrency: 1,
          loaded_models: [],
          runtime_model_placements: []
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_a.id
      assert schedule.selected_tier == "loaded"
      assert schedule.candidate_count == 2
      assert schedule.queue_lane_capacity == 2
    end

    test "SPEC.md §5.5 excludes nodes when reported node max concurrency is exhausted" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          active_request_count: 2,
          max_concurrency: 2,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          runtime_model_placements: [model_placement("test-model", "v1", 0, 2)]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id,
          host: "10.0.0.2",
          port: 50_062,
          active_request_count: 0,
          max_concurrency: 2,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          runtime_model_placements: [model_placement("test-model", "v1", 0, 2)]
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_b.id
      assert schedule.selected_tier == "loaded"
      assert schedule.candidate_count == 1
    end

    test "SPEC.md §5.5 treats missing node max concurrency conservatively" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      status_a =
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          active_request_count: 1,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          runtime_model_placements: [model_placement("test-model", "v1", 0, 2)]
        )
        |> Map.delete(:max_concurrency)

      stub_probe("10.0.0.1", 50_061, status_a)

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id,
          host: "10.0.0.2",
          port: 50_062,
          active_request_count: 0,
          max_concurrency: 2,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          runtime_model_placements: [model_placement("test-model", "v1", 0, 2)]
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_b.id
      assert schedule.candidate_count == 1
    end

    test "SPEC.md §5.5 constrains queue admission capacity by node max concurrency" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      for {node, host, port, node_active, model_active} <- [
            {node_a, "10.0.0.1", 50_061, 0, 0},
            {node_b, "10.0.0.2", 50_062, 1, 0}
          ] do
        stub_probe(
          host,
          port,
          make_status(node.id,
            host: host,
            port: port,
            active_request_count: node_active,
            max_concurrency: 2,
            loaded_models: [%{model_id: "test-model", version: "v1"}],
            runtime_model_placements: [model_placement("test-model", "v1", model_active, 4)]
          )
        )
      end

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.selected_tier == "loaded"
      assert schedule.queue_lane_capacity == 3
    end

    test "SPEC.md §5.5 excludes full candidates from queue admission capacity" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          active_request_count: 2,
          max_concurrency: 2,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          runtime_model_placements: [model_placement("test-model", "v1", 2, 2)]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id,
          host: "10.0.0.2",
          port: 50_062,
          active_request_count: 0,
          max_concurrency: 2,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          runtime_model_placements: [model_placement("test-model", "v1", 0, 2)]
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_b.id
      assert schedule.candidate_count == 1
      assert schedule.queue_lane_capacity == 2
    end

    test "SPEC.md §5.5 returns cluster_busy for cold requests when all nodes are at max concurrency" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      for {node, host, port} <- [
            {node_a, "10.0.0.1", 50_061},
            {node_b, "10.0.0.2", 50_062}
          ] do
        stub_probe(
          host,
          port,
          make_status(node.id,
            host: host,
            port: port,
            active_request_count: 2,
            max_concurrency: 2
          )
        )
      end

      request = canonical_request("cold-capacity-model", "v1")

      assert {:error, :cluster_busy} = MultiNode.schedule(request, status_client: StubClient)
    end

    test "SPEC.md §5.5 reports cold-tier queue capacity from eligible node concurrency" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      for {node, host, port, active_count, max_concurrency} <- [
            {node_a, "10.0.0.1", 50_061, 0, 2},
            {node_b, "10.0.0.2", 50_062, 1, 3}
          ] do
        stub_probe(
          host,
          port,
          make_status(node.id,
            host: host,
            port: port,
            active_request_count: active_count,
            max_concurrency: max_concurrency,
            loaded_models: [],
            runtime_model_placements: []
          )
        )
      end

      request = canonical_request("cold-capacity-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.selected_tier == "cold"
      assert schedule.queue_lane_capacity == 2
    end

    test "SPEC.md §5.5 scheduler probe does not reuse unassigned active grant slot" do
      QueueManager.reset()

      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})
      queue_config = [enabled: true, capacity: 1, max_wait_ms: 1_000, owner_runtime: true]

      assert {:ok, active_grant} =
               QueueManager.acquire(queue_admission_request("req-scheduler-probe-active"),
                 config: queue_config
               )

      assert {:queued, ticket} =
               QueueManager.acquire(queue_admission_request("req-scheduler-probe-queued"),
                 config: queue_config
               )

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket) end)

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          active_request_count: 0,
          max_concurrency: 1,
          loaded_models: [],
          runtime_model_placements: []
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id,
          host: "10.0.0.2",
          port: 50_062,
          active_request_count: 1,
          max_concurrency: 1,
          loaded_models: [],
          runtime_model_placements: []
        )
      )

      assert {:ok, schedule} =
               MultiNode.schedule(canonical_request("test-model", "v1"),
                 status_client: StubClient
               )

      assert schedule.node_id == node_a.id
      refute Task.yield(awaiter, 50)

      assert :ok = QueueManager.release(active_grant)
      assert {:ok, queued_grant} = Task.await(awaiter, 2_000)
      assert :ok = QueueManager.release(queued_grant)
      QueueManager.reset()
    end

    test "prefers lower matching placement active count before health and node_id" do
      node_a =
        insert_node!(%{
          id: "00000000-0000-0000-0000-000000000001",
          advertise_addr: "10.0.0.1",
          rpc_port: 50_061,
          health: :healthy
        })

      node_b =
        insert_node!(%{
          id: "00000000-0000-0000-0000-000000000002",
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
          active_request_count: 2,
          runtime_model_placements: [model_placement("test-model", "v1", 2, 3)]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id,
          host: "10.0.0.2",
          port: 50_062,
          health: %{ready: true, health_code: "warn", health_message: "degraded"},
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          active_request_count: 1,
          runtime_model_placements: [model_placement("test-model", "v1", 1, 3)]
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_b.id
      assert schedule.selected_tier == "loaded"
      assert schedule.candidate_count == 2
    end

    test "excludes active loaded node at matching placement capacity" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          active_request_count: 2,
          runtime_model_placements: [model_placement("test-model", "v1", 2, 2)]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_b.id
      assert schedule.selected_tier == "cold"
      assert schedule.candidate_count == 1
    end

    test "excludes active loaded node with malformed placement capacity" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          active_request_count: 1,
          runtime_model_placements: [model_placement("other-model", "v1", 0, 2), %{}]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_b.id
      assert schedule.selected_tier == "cold"
      assert schedule.candidate_count == 1
    end

    test "SPEC.md §5.5 excludes active loaded node with invalid matching placement max concurrency" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          active_request_count: 1,
          runtime_model_placements: [model_placement("test-model", "v1", 0, 0)]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_b.id
      assert schedule.selected_tier == "cold"
      assert schedule.candidate_count == 1
      assert schedule.queue_lane_capacity == 1
    end

    test "excludes active loaded node with duplicate matching placement capacity" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})
      duplicate = model_placement("test-model", "v1", 0, 2)

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          active_request_count: 1,
          runtime_model_placements: [duplicate, duplicate]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_b.id
      assert schedule.selected_tier == "cold"
      assert schedule.candidate_count == 1
    end

    test "excludes active loaded node with ambiguous matching placement capacity" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          active_request_count: 1,
          runtime_model_placements: [
            model_placement("test-model", "v1", 1, 2),
            %{model_ref: %{model_id: "test-model", version: "v1"}}
          ]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_b.id
      assert schedule.selected_tier == "cold"
      assert schedule.candidate_count == 1
    end

    test "keeps active cold node eligible when aggregate capacity has room" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          active_request_count: 1,
          max_concurrency: 2,
          runtime_model_placements: [model_placement("test-model", "v1", 0, 2)]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id,
          host: "10.0.0.2",
          port: 50_062,
          active_request_count: 2,
          max_concurrency: 2
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_a.id
      assert schedule.selected_tier == "cold"
      assert schedule.candidate_count == 1
    end

    test "excludes active loaded node in favor of idle cold node when capacity is unknown" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          active_request_count: 1
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == node_b.id
      assert schedule.selected_tier == "cold"
      assert schedule.candidate_count == 1
    end

    test "returns cluster_busy when all joined candidates exhaust aggregate capacity" do
      node_a = insert_node!(%{advertise_addr: "10.0.0.1", rpc_port: 50_061})
      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          active_request_count: 1,
          max_concurrency: 1
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id,
          host: "10.0.0.2",
          port: 50_062,
          active_request_count: 2,
          max_concurrency: 2
        )
      )

      assert {:error, :cluster_busy} =
               MultiNode.schedule(canonical_request(), status_client: StubClient)
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

    test "prefix cache scoring probes only the selected candidate when enabled" do
      put_inference(
        cache_affinity: [
          enabled: true,
          live_fingerprint_match_enabled: true,
          max_age_ms: 300_000,
          max_recent_requests: 8
        ],
        prefix_cache_scoring: [enabled: true, timeout_ms: 123]
      )

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
          loaded_models: [%{model_id: "test-model", version: "v1"}]
        )
      )

      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      stub_score("10.0.0.1", 50_061, %{
        status_code: "ok",
        resident_fingerprint_match: true,
        score_tier: "resident_fingerprint",
        session_started_unix_ms: 123
      })

      stub_score("10.0.0.2", 50_062, %{status_code: "error", score_tier: "unknown"})

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.prefix_cache_score.status_code == "ok"
      assert schedule.prefix_cache_score.score_tier == "resident_fingerprint"

      assert [{{"10.0.0.1", 50_061}, score_request}] = score_calls()
      assert score_request.request_id == request.public_id
      assert score_request.controller_session_id == request.internal_id
      assert score_request.model_ref.model_id == request.model_ref.model_id
      assert score_request.model_ref.version == request.model_ref.version
    end

    test "observe-only scoring preserves deterministic node_id parity for tied candidates" do
      put_inference(
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true],
        prefix_cache_scoring: [enabled: true, timeout_ms: 123]
      )

      {id_a, id_b} = insert_ordered_nodes!()
      request = stub_tied_cold_nodes(id_a, id_b)

      stub_score("10.0.0.1", 50_061, ok_non_resident_score())
      stub_score("10.0.0.2", 50_062, ok_resident_score())

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.prefix_cache_score.status_code == "ok"
      assert schedule.prefix_cache_score.resident_fingerprint_match == false
      assert [{{"10.0.0.1", 50_061}, _incumbent}] = score_calls()
    end

    test "tie-only scoring promotes authoritative resident challenger over non-resident incumbent" do
      put_inference(
        cache_affinity: [
          enabled: true,
          live_fingerprint_match_enabled: true,
          max_age_ms: 300_000,
          max_recent_requests: 8
        ],
        memory_admission: [enabled: true],
        prefix_cache_scoring: [
          enabled: true,
          timeout_ms: 123,
          ranking_mode: :tie_only,
          max_ranking_candidates: 2
        ]
      )

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

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
            prefix_cache_status("test-model", "v1", %{entry_count: 77, total_bytes: 7_700})
          ],
          runtime_memory_budgets: [
            memory_budget("test-model", "v1", %{
              status_code: "resident_memory_unavailable",
              budget_available: false,
              headroom_available: false
            })
          ]
        )
      )

      stub_score("10.0.0.1", 50_061, %{
        status_code: "ok",
        resident_fingerprint_match: false,
        score_tier: "no_match",
        session_started_unix_ms: 111
      })

      stub_score("10.0.0.2", 50_062, %{
        status_code: "ok",
        resident_fingerprint_match: true,
        score_tier: "resident_fingerprint",
        session_started_unix_ms: 222
      })

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_b
      assert schedule.runtime_client_target == [host: "10.0.0.2", port: 50_062]
      assert schedule.selected_tier == "cold"
      assert schedule.prefix_cache_fingerprint_match? == false
      assert schedule.cache_affinity_selected_match == false
      assert schedule.selected_cache_tier == "no_hint"
      assert schedule.prefix_cache_status.entry_count == 77
      assert schedule.memory_admission_tier == "headroom_unavailable"
      assert schedule.memory_budget.status_code == "resident_memory_unavailable"
      assert schedule.prefix_cache_score.status_code == "ok"
      assert schedule.prefix_cache_score.resident_fingerprint_match == true
      assert schedule.prefix_cache_score.score_tier == "resident_fingerprint"
      assert schedule.prefix_cache_score.session_started_unix_ms == 222

      assert [{{"10.0.0.1", 50_061}, _incumbent}, {{"10.0.0.2", 50_062}, _challenger}] =
               score_calls()
    end

    test "tie-only scoring preserves base order when incumbent score is non-ok" do
      put_inference(
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true],
        prefix_cache_scoring: [enabled: true, timeout_ms: 123, ranking_mode: :tie_only]
      )

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      stub_score("10.0.0.1", 50_061, %{status_code: "error", score_tier: "unknown"})

      stub_score("10.0.0.2", 50_062, %{
        status_code: "ok",
        resident_fingerprint_match: true,
        score_tier: "resident_fingerprint"
      })

      assert {:ok, schedule} = MultiNode.schedule(canonical_request(), status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.prefix_cache_score.status_code == "error"

      assert [{{"10.0.0.1", 50_061}, _incumbent}, {{"10.0.0.2", 50_062}, _challenger}] =
               score_calls()
    end

    test "tie-only scoring preserves base order when challenger has no authoritative match" do
      put_tie_only_scoring_config()

      {id_a, id_b} = insert_ordered_nodes!()
      request = stub_tied_cold_nodes(id_a, id_b)

      stub_score("10.0.0.1", 50_061, ok_non_resident_score())
      stub_score("10.0.0.2", 50_062, ok_non_resident_score())

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.prefix_cache_score.resident_fingerprint_match == false

      assert [{{"10.0.0.1", 50_061}, _incumbent}, {{"10.0.0.2", 50_062}, _challenger}] =
               score_calls()
    end

    test "tie-only scoring treats recent_fingerprint_only incumbent as comparable non-resident" do
      put_tie_only_scoring_config()

      {id_a, id_b} = insert_ordered_nodes!()
      request = stub_tied_cold_nodes(id_a, id_b)

      stub_score(
        "10.0.0.1",
        50_061,
        ok_non_resident_score(score_tier: "recent_fingerprint_only")
      )

      stub_score("10.0.0.2", 50_062, ok_resident_score())

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_b
      assert schedule.prefix_cache_score.resident_fingerprint_match == true
    end

    test "tie-only scoring preserves incumbent for contradictory ok score shapes" do
      put_tie_only_scoring_config()

      {id_a, id_b} = insert_ordered_nodes!()
      request = stub_tied_cold_nodes(id_a, id_b)

      for contradictory_incumbent <- [
            %{status_code: "ok", resident_fingerprint_match: true, score_tier: "no_match"},
            %{
              status_code: "ok",
              resident_fingerprint_match: false,
              score_tier: "resident_fingerprint"
            }
          ] do
        reset_score_calls()
        stub_score("10.0.0.1", 50_061, contradictory_incumbent)
        stub_score("10.0.0.2", 50_062, ok_resident_score())

        assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

        assert schedule.node_id == id_a
      end
    end

    test "tie-only scoring preserves incumbent when both candidates are authoritative resident" do
      put_tie_only_scoring_config()

      {id_a, id_b} = insert_ordered_nodes!()
      request = stub_tied_cold_nodes(id_a, id_b)

      stub_score("10.0.0.1", 50_061, ok_resident_score(session_started_unix_ms: 111))
      stub_score("10.0.0.2", 50_062, ok_resident_score(session_started_unix_ms: 222))

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.prefix_cache_score.resident_fingerprint_match == true
      assert schedule.prefix_cache_score.session_started_unix_ms == 111
    end

    test "tie-only scoring preserves incumbent when incumbent ok score is malformed" do
      put_tie_only_scoring_config()

      {id_a, id_b} = insert_ordered_nodes!()
      request = stub_tied_cold_nodes(id_a, id_b)

      for malformed_incumbent <- [
            %{status_code: "ok"},
            %{status_code: "ok", resident_fingerprint_match: false},
            %{status_code: "ok", resident_fingerprint_match: false, score_tier: "unknown"}
          ] do
        reset_score_calls()
        stub_score("10.0.0.1", 50_061, malformed_incumbent)
        stub_score("10.0.0.2", 50_062, ok_resident_score())

        assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

        assert schedule.node_id == id_a
        assert schedule.prefix_cache_score.status_code == "ok"

        assert [{{"10.0.0.1", 50_061}, _incumbent}, {{"10.0.0.2", 50_062}, _challenger}] =
                 score_calls()
      end
    end

    test "tie-only scoring fail-opens for non-ok scores from either candidate" do
      put_tie_only_scoring_config()

      {id_a, id_b} = insert_ordered_nodes!()
      request = stub_tied_cold_nodes(id_a, id_b)

      for status <- [
            "timeout",
            "error",
            "unsupported_version",
            "disabled",
            "unavailable",
            "model_not_loaded",
            "invalid_request"
          ] do
        reset_score_calls()
        stub_score("10.0.0.1", 50_061, ok_non_resident_score())
        stub_score("10.0.0.2", 50_062, non_ok_score(status))

        assert {:ok, challenger_non_ok_schedule} =
                 MultiNode.schedule(request, status_client: StubClient)

        assert challenger_non_ok_schedule.node_id == id_a
        assert challenger_non_ok_schedule.prefix_cache_score.status_code == "ok"

        assert [{{"10.0.0.1", 50_061}, _incumbent}, {{"10.0.0.2", 50_062}, _challenger}] =
                 score_calls()

        reset_score_calls()
        stub_score("10.0.0.1", 50_061, non_ok_score(status))
        stub_score("10.0.0.2", 50_062, ok_resident_score())

        assert {:ok, incumbent_non_ok_schedule} =
                 MultiNode.schedule(request, status_client: StubClient)

        assert incumbent_non_ok_schedule.node_id == id_a
        assert incumbent_non_ok_schedule.prefix_cache_score.status_code == status

        assert [{{"10.0.0.1", 50_061}, _incumbent}, {{"10.0.0.2", 50_062}, _challenger}] =
                 score_calls()
      end
    end

    test "tie-only scoring caps leading tie scoring to two candidates" do
      put_inference(
        runtime_client_targets: [
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.2", port: 50_062],
          [host: "10.0.0.3", port: 50_063]
        ],
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true],
        prefix_cache_scoring: [
          enabled: true,
          timeout_ms: 123,
          ranking_mode: :tie_only,
          max_ranking_candidates: 3
        ]
      )

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"
      id_c = "00000000-0000-0000-0000-000000000003"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})
      insert_node!(%{id: id_c, advertise_addr: "10.0.0.3", rpc_port: 50_063})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))
      stub_probe("10.0.0.3", 50_063, make_status(id_c, host: "10.0.0.3", port: 50_063))

      stub_score("10.0.0.1", 50_061, ok_non_resident_score())
      stub_score("10.0.0.2", 50_062, ok_non_resident_score())
      stub_score("10.0.0.3", 50_063, ok_resident_score())

      assert Orchard.Inference.prefix_cache_scoring_max_ranking_candidates() == 2
      assert {:ok, schedule} = MultiNode.schedule(canonical_request(), status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.candidate_count == 3

      assert [{{"10.0.0.1", 50_061}, _incumbent}, {{"10.0.0.2", 50_062}, _challenger}] =
               score_calls()
    end

    test "tie-only score never inverts loadedness active-count health cache affinity or memory signals" do
      put_inference(
        cache_affinity: [
          enabled: true,
          live_fingerprint_match_enabled: true,
          max_age_ms: 300_000,
          max_recent_requests: 8
        ],
        memory_admission: [enabled: true],
        prefix_cache_scoring: [enabled: true, timeout_ms: 123, ranking_mode: :tie_only]
      )

      {id_a, id_b} = insert_ordered_nodes!()

      assert_score_does_not_invert_signal(:loadedness, id_a, id_b)
      assert_score_does_not_invert_signal(:active_count, id_a, id_b)
      assert_score_does_not_invert_signal(:health, id_a, id_b)
      assert_score_does_not_invert_signal(:live_fingerprint, id_a, id_b)
      assert_score_does_not_invert_signal(:historical_affinity, id_a, id_b)
      assert_score_does_not_invert_signal(:memory_headroom, id_a, id_b)
    end

    test "tie-only scoring does not score challenger when stronger signals are not tied" do
      put_inference(
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true],
        prefix_cache_scoring: [enabled: true, timeout_ms: 123, ranking_mode: :tie_only]
      )

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
          loaded_models: [%{model_id: "test-model", version: "v1"}]
        )
      )

      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      stub_score("10.0.0.1", 50_061, %{
        status_code: "ok",
        resident_fingerprint_match: false,
        score_tier: "no_match"
      })

      stub_score("10.0.0.2", 50_062, %{
        status_code: "ok",
        resident_fingerprint_match: true,
        score_tier: "resident_fingerprint"
      })

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.selected_tier == "loaded"
      assert [{{"10.0.0.1", 50_061}, _incumbent}] = score_calls()
    end

    test "tie-only scoring with leading tie preserves base order when derive_key is unavailable" do
      put_tie_only_scoring_config()

      {id_a, id_b} = insert_ordered_nodes!()

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      request = canonical_request("test-model", "v1", rendered_prompt: nil)

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.candidate_count == 2
      assert schedule.node_id == id_a
      assert schedule.runtime_client_target == [host: "10.0.0.1", port: 50_061]
      assert score_calls() == []
      refute Map.has_key?(schedule, :prefix_cache_score)
    end

    test "prefix cache scoring is a no-op when live fingerprint matching is disabled" do
      put_inference(
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: false],
        prefix_cache_scoring: [enabled: true, timeout_ms: 123]
      )

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      assert {:ok, schedule} = MultiNode.schedule(canonical_request(), status_client: StubClient)

      refute Map.has_key?(schedule, :prefix_cache_score)
      assert score_calls() == []
    end

    test "prefix cache scoring skips RPC when affinity key is unavailable" do
      put_inference(
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true],
        prefix_cache_scoring: [enabled: true, timeout_ms: 123]
      )

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      assert {:ok, schedule} =
               MultiNode.schedule(
                 canonical_request("test-model", "v1", rendered_prompt: nil),
                 status_client: StubClient
               )

      refute Map.has_key?(schedule, :prefix_cache_score)
      assert score_calls() == []
    end

    test "issues exactly one selected-candidate score RPC when all gates are enabled" do
      put_inference(
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true],
        prefix_cache_scoring: [enabled: true, timeout_ms: 120]
      )

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_a, host: "10.0.0.1", port: 50_061, active_request_count: 1)
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_b,
          host: "10.0.0.2",
          port: 50_062,
          runtime_prefix_cache_statuses: [
            prefix_cache_status("test-model", "v1", %{prefix_cache_fingerprints: []})
          ]
        )
      )

      stub_score(
        "10.0.0.2",
        50_062,
        %ScorePrefixCacheResponse{
          status_code: "ok",
          resident_fingerprint_match: true,
          score_tier: "resident_fingerprint",
          session_started_unix_ms: 1_713_726_400_000
        }
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == id_b
      assert schedule.prefix_cache_score.status_code == "ok"
      assert [{{"10.0.0.2", 50_062}, _score_request}] = score_calls()
    end

    test "scoring enabled but live fingerprint disabled is an explicit no-op" do
      put_inference(
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: false],
        prefix_cache_scoring: [enabled: true, timeout_ms: 120]
      )

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == id_a
      assert score_calls() == []
      refute Map.has_key?(schedule, :prefix_cache_score)
    end

    test "derive_key unavailable skips score RPC without changing ranking" do
      put_inference(
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true],
        prefix_cache_scoring: [enabled: true, timeout_ms: 120]
      )

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      request = canonical_request("test-model", "v1", rendered_prompt: nil)

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == id_a
      assert score_calls() == []
      refute Map.has_key?(schedule, :prefix_cache_score)
    end

    test "derive_key unavailable skips tie-only challenger score RPC without changing ranking" do
      put_inference(
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true],
        prefix_cache_scoring: [enabled: true, timeout_ms: 120, ranking_mode: :tie_only]
      )

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      request = canonical_request("test-model", "v1", rendered_prompt: nil)

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.node_id == id_a
      assert score_calls() == []
      refute Map.has_key?(schedule, :prefix_cache_score)
    end

    test "prefix cache scoring normalizes unsupported client versions without affecting selection" do
      put_inference(
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true],
        prefix_cache_scoring: [enabled: true, timeout_ms: 120]
      )

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
          loaded_models: [%{model_id: "test-model", version: "v1"}]
        )
      )

      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      request =
        canonical_request("test-model", "v1", rendered_prompt: "secret-prefix-cache-input")

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, schedule} =
                   MultiNode.schedule(request, status_client: StubClientWithoutScore)

          assert schedule.node_id == id_a
          assert schedule.prefix_cache_score.status_code == "unsupported_version"
          assert score_calls() == []
        end)

      assert log =~ "prefix cache score RPC fail-open"
      assert log =~ "status_code=unsupported_version"
      assert log =~ "reason=unsupported_version"
      assert log =~ "target=10.0.0.1:50061"
      assert log =~ "request_id=#{request.public_id}"
      refute log =~ "secret-prefix-cache-input"
    end

    test "prefix cache scoring normalizes rescue and exit failures to error" do
      put_inference(
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true],
        prefix_cache_scoring: [enabled: true, timeout_ms: 120]
      )

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
          loaded_models: [%{model_id: "test-model", version: "v1"}]
        )
      )

      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      request = canonical_request("test-model", "v1")

      raise_log =
        capture_log([level: :debug], fn ->
          assert {:ok, raise_schedule} =
                   MultiNode.schedule(request, status_client: StubClientRaiseScore)

          assert raise_schedule.node_id == id_a
          assert raise_schedule.prefix_cache_score.status_code == "error"
        end)

      assert raise_log =~ "prefix cache score RPC fail-open"
      assert raise_log =~ "status_code=error"
      assert raise_log =~ "reason=rescued_exception"
      assert raise_log =~ "target=10.0.0.1:50061"
      assert raise_log =~ "request_id=#{request.public_id}"
      refute raise_log =~ "score call crashed"

      exit_log =
        capture_log([level: :debug], fn ->
          assert {:ok, exit_schedule} =
                   MultiNode.schedule(request, status_client: StubClientExitScore)

          assert exit_schedule.node_id == id_a
          assert exit_schedule.prefix_cache_score.status_code == "error"
        end)

      assert exit_log =~ "prefix cache score RPC fail-open"
      assert exit_log =~ "status_code=error"
      assert exit_log =~ "reason=exit"
      assert exit_log =~ "target=10.0.0.1:50061"
      assert exit_log =~ "request_id=#{request.public_id}"
      refute exit_log =~ "score_call_exit"
      refute exit_log =~ ":score_call_exit"
    end

    test "does not let cache-affinity make an active candidate eligible" do
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
        make_status(id_b,
          host: "10.0.0.2",
          port: 50_062,
          active_request_count: 3,
          loaded_models: [%{model_id: "test-model", version: "v1"}]
        )
      )

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.cache_affinity_hint_available == true
      assert schedule.cache_affinity_selected_match == false
      assert schedule.cache_affinity_candidate_count == 0
      assert schedule.selected_cache_tier == "hint_not_selected"
    end

    test "uses memory admission only as an enabled positive tie-breaker" do
      put_inference(memory_admission: [enabled: true])

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_b,
          host: "10.0.0.2",
          port: 50_062,
          runtime_memory_budgets: [memory_budget("test-model", "v1", %{})]
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_b
      assert schedule.memory_admission_enabled == true
      assert schedule.memory_admission_tier == "headroom_ok"
      assert schedule.memory_budget.status_code == "ok"
    end

    test "keeps memory telemetry rank-neutral and hidden when disabled" do
      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_b,
          host: "10.0.0.2",
          port: 50_062,
          runtime_memory_budgets: [memory_budget("test-model", "v1", %{})]
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      refute Map.has_key?(schedule, :memory_budget)
      refute Map.has_key?(schedule, :memory_admission_enabled)
      refute Map.has_key?(schedule, :memory_admission_tier)
    end

    test "keeps memory admission below historical cache-affinity" do
      put_inference(
        cache_affinity: [enabled: true, max_age_ms: 300_000, max_recent_requests: 8],
        memory_admission: [enabled: true]
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
          runtime_memory_budgets: [memory_budget("test-model", "v1", %{})]
        )
      )

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.cache_affinity_selected_match == true
      assert schedule.memory_admission_tier == "headroom_unknown"
    end

    test "keeps memory admission below live prefix-cache fingerprint matching" do
      put_inference(
        cache_affinity: [
          enabled: true,
          live_fingerprint_match_enabled: true,
          max_age_ms: 300_000,
          max_recent_requests: 8
        ],
        memory_admission: [enabled: true]
      )

      id_a = "00000000-0000-0000-0000-000000000002"
      id_b = "00000000-0000-0000-0000-000000000001"
      request = canonical_request("test-model", "v1")
      affinity_key = cache_affinity_key!(request)

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_a,
          host: "10.0.0.1",
          port: 50_061,
          runtime_prefix_cache_statuses: [
            prefix_cache_status("test-model", "v1", %{prefix_cache_fingerprints: [affinity_key]})
          ]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_b,
          host: "10.0.0.2",
          port: 50_062,
          runtime_memory_budgets: [memory_budget("test-model", "v1", %{})]
        )
      )

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.prefix_cache_fingerprint_match? == true
      assert schedule.memory_admission_tier == "headroom_unknown"
    end

    test "does not let memory admission outrank loaded model residency" do
      put_inference(memory_admission: [enabled: true])

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
          loaded_models: [%{model_id: "test-model", version: "v1"}]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_b,
          host: "10.0.0.2",
          port: 50_062,
          runtime_memory_budgets: [memory_budget("test-model", "v1", %{})]
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.memory_admission_tier == "headroom_unknown"
    end

    test "does not let memory admission outrank health" do
      put_inference(memory_admission: [enabled: true])

      id_a = "00000000-0000-0000-0000-000000000002"
      id_b = "00000000-0000-0000-0000-000000000001"

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
          runtime_memory_budgets: [memory_budget("test-model", "v1", %{})]
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.memory_admission_tier == "headroom_unknown"
    end

    test "memory headroom does not make loaded unknown-capacity candidate eligible" do
      put_inference(memory_admission: [enabled: true])

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_b,
          host: "10.0.0.2",
          port: 50_062,
          loaded_models: [%{model_id: "test-model", version: "v1"}],
          active_request_count: 1,
          runtime_memory_budgets: [memory_budget("test-model", "v1", %{})]
        )
      )

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.candidate_count == 1
      assert schedule.memory_admission_tier == "headroom_unknown"
    end

    test "treats non-matching and malformed memory telemetry as fail-open unknown" do
      put_inference(memory_admission: [enabled: true])

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
          runtime_memory_budgets: [
            "not a budget map",
            memory_budget("other-model", "v1", %{})
          ]
        )
      )

      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      request = canonical_request("test-model", "v1")

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_a
      assert schedule.memory_admission_tier == "headroom_unknown"
    end

    test "prefers prompt-token-capable worker when opt-in flag and safe mode are enabled" do
      put_inference(tokenizer_safe_mode: :on, tokenizer_safe_mode_prefer_capable: true)

      id_legacy = "00000000-0000-0000-0000-000000000001"
      id_capable = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_legacy, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_capable, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_legacy, host: "10.0.0.1", port: 50_061, supports_prompt_token_ids: false)
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_capable, host: "10.0.0.2", port: 50_062, supports_prompt_token_ids: true)
      )

      assert {:ok, schedule} = MultiNode.schedule(canonical_request(), status_client: StubClient)

      assert schedule.node_id == id_capable
      assert schedule.runtime_client_target == [host: "10.0.0.2", port: 50_062]
    end

    test "keeps prompt-token capability rank-neutral when preference flag is disabled" do
      put_inference(tokenizer_safe_mode: :on, tokenizer_safe_mode_prefer_capable: false)

      id_legacy = "00000000-0000-0000-0000-000000000001"
      id_capable = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_legacy, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_capable, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_legacy, host: "10.0.0.1", port: 50_061, supports_prompt_token_ids: false)
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_capable, host: "10.0.0.2", port: 50_062, supports_prompt_token_ids: true)
      )

      assert {:ok, schedule} = MultiNode.schedule(canonical_request(), status_client: StubClient)

      assert schedule.node_id == id_legacy
      assert schedule.runtime_client_target == [host: "10.0.0.1", port: 50_061]
    end

    test "keeps prompt-token capability rank-neutral when safe mode is off" do
      put_inference(tokenizer_safe_mode: :off, tokenizer_safe_mode_prefer_capable: true)

      id_legacy = "00000000-0000-0000-0000-000000000001"
      id_capable = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_legacy, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_capable, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_legacy, host: "10.0.0.1", port: 50_061, supports_prompt_token_ids: false)
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_capable, host: "10.0.0.2", port: 50_062, supports_prompt_token_ids: true)
      )

      assert {:ok, schedule} = MultiNode.schedule(canonical_request(), status_client: StubClient)

      assert schedule.node_id == id_legacy
    end

    test "keeps capable-worker preference below historical cache-affinity" do
      put_inference(
        tokenizer_safe_mode: :on,
        tokenizer_safe_mode_prefer_capable: true,
        cache_affinity: [enabled: true, max_age_ms: 300_000, max_recent_requests: 8]
      )

      id_cache_match_legacy = "00000000-0000-0000-0000-000000000001"
      id_capable = "00000000-0000-0000-0000-000000000002"
      tenant_id = Ecto.UUID.generate()
      request = canonical_request("test-model", "v1", tenant_id: tenant_id)
      affinity_key = cache_affinity_key!(request)

      insert_node!(%{id: id_cache_match_legacy, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_capable, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      insert_recent_cache_affinity_request!(
        tenant_id,
        "test-model",
        "v1",
        id_cache_match_legacy,
        affinity_key,
        DateTime.utc_now()
      )

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_cache_match_legacy,
          host: "10.0.0.1",
          port: 50_061,
          supports_prompt_token_ids: false
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_capable, host: "10.0.0.2", port: 50_062, supports_prompt_token_ids: true)
      )

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_cache_match_legacy
      assert schedule.cache_affinity_selected_match == true
    end

    test "keeps capable-worker preference below live prefix-cache fingerprint matching" do
      put_inference(
        tokenizer_safe_mode: :on,
        tokenizer_safe_mode_prefer_capable: true,
        cache_affinity: [
          enabled: true,
          live_fingerprint_match_enabled: true,
          max_age_ms: 300_000,
          max_recent_requests: 8
        ]
      )

      id_live_match_legacy = "00000000-0000-0000-0000-000000000001"
      id_capable = "00000000-0000-0000-0000-000000000002"
      request = canonical_request("test-model", "v1")
      affinity_key = cache_affinity_key!(request)

      insert_node!(%{id: id_live_match_legacy, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_capable, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_live_match_legacy,
          host: "10.0.0.1",
          port: 50_061,
          supports_prompt_token_ids: false,
          runtime_prefix_cache_statuses: [
            prefix_cache_status("test-model", "v1", %{prefix_cache_fingerprints: [affinity_key]})
          ]
        )
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_capable, host: "10.0.0.2", port: 50_062, supports_prompt_token_ids: true)
      )

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_live_match_legacy
      assert schedule.prefix_cache_fingerprint_match? == true
    end

    test "keeps capable-worker preference above memory admission" do
      put_inference(
        tokenizer_safe_mode: :on,
        tokenizer_safe_mode_prefer_capable: true,
        memory_admission: [enabled: true]
      )

      id_capable = "00000000-0000-0000-0000-000000000002"
      id_memory = "00000000-0000-0000-0000-000000000001"

      insert_node!(%{id: id_capable, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_memory, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_capable, host: "10.0.0.1", port: 50_061, supports_prompt_token_ids: true)
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_memory,
          host: "10.0.0.2",
          port: 50_062,
          supports_prompt_token_ids: false,
          runtime_memory_budgets: [memory_budget("test-model", "v1", %{})]
        )
      )

      assert {:ok, schedule} = MultiNode.schedule(canonical_request(), status_client: StubClient)

      assert schedule.node_id == id_capable
      assert schedule.memory_admission_tier == "headroom_unknown"
    end

    test "ranker uses live capability annotation instead of persisted node capabilities" do
      id_persisted_capable_live_legacy = "00000000-0000-0000-0000-000000000001"
      id_live_capable_persisted_legacy = "00000000-0000-0000-0000-000000000002"

      persisted_capable_live_legacy = %{
        node_id: id_persisted_capable_live_legacy,
        loaded_model?: false,
        active_request_count: 0,
        cache_affinity_match?: false,
        capable_worker_preferred?: false,
        node: %{health: :healthy, capabilities: %{"supports_prompt_token_ids" => true}}
      }

      live_capable_persisted_legacy = %{
        node_id: id_live_capable_persisted_legacy,
        loaded_model?: false,
        active_request_count: 0,
        cache_affinity_match?: false,
        capable_worker_preferred?: true,
        node: %{health: :healthy, capabilities: %{"supports_prompt_token_ids" => false}}
      }

      assert [first, second] =
               MultiNode.rank_candidates(
                 [persisted_capable_live_legacy, live_capable_persisted_legacy],
                 prefer_capable_workers?: true
               )

      assert first.node_id == id_live_capable_persisted_legacy
      assert second.node_id == id_persisted_capable_live_legacy
    end

    test "still schedules deterministically when all workers are legacy" do
      put_inference(tokenizer_safe_mode: :on, tokenizer_safe_mode_prefer_capable: true)

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe("10.0.0.1", 50_061, make_status(id_a, host: "10.0.0.1", port: 50_061))
      stub_probe("10.0.0.2", 50_062, make_status(id_b, host: "10.0.0.2", port: 50_062))

      assert {:ok, schedule} = MultiNode.schedule(canonical_request(), status_client: StubClient)
      assert schedule.node_id == id_a
    end

    test "keeps deterministic tie order when all workers are capable" do
      put_inference(tokenizer_safe_mode: :on, tokenizer_safe_mode_prefer_capable: true)

      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_a, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_b, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_a, host: "10.0.0.1", port: 50_061, supports_prompt_token_ids: true)
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_b, host: "10.0.0.2", port: 50_062, supports_prompt_token_ids: true)
      )

      assert {:ok, schedule} = MultiNode.schedule(canonical_request(), status_client: StubClient)
      assert schedule.node_id == id_a
    end

    test "tie-only prefix scoring does not invert capable-worker preference" do
      put_inference(
        tokenizer_safe_mode: :on,
        tokenizer_safe_mode_prefer_capable: true,
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true],
        prefix_cache_scoring: [enabled: true, timeout_ms: 123, ranking_mode: :tie_only]
      )

      id_legacy = "00000000-0000-0000-0000-000000000001"
      id_capable = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{id: id_legacy, advertise_addr: "10.0.0.1", rpc_port: 50_061})
      insert_node!(%{id: id_capable, advertise_addr: "10.0.0.2", rpc_port: 50_062})

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(id_legacy, host: "10.0.0.1", port: 50_061, supports_prompt_token_ids: false)
      )

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(id_capable, host: "10.0.0.2", port: 50_062, supports_prompt_token_ids: true)
      )

      stub_score("10.0.0.1", 50_061, ok_resident_score())
      stub_score("10.0.0.2", 50_062, ok_non_resident_score())

      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)

      assert schedule.node_id == id_capable
      assert [{{"10.0.0.2", 50_062}, score_request}] = score_calls()
      assert score_request.request_id == request.public_id
      assert score_request.controller_session_id == request.internal_id
      assert score_request.model_ref.model_id == request.model_ref.model_id
      assert score_request.model_ref.version == request.model_ref.version
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

      stub_probe(
        "10.0.0.1",
        50_061,
        make_status(node_a.id,
          host: "10.0.0.1",
          port: 50_061,
          active_request_count: 0,
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
          max_concurrency: 2,
          health: %{ready: true, health_code: "warn", health_message: "degraded"}
        )
      )

      request = canonical_request()

      assert {:ok, schedule} = MultiNode.schedule(request, status_client: StubClient)
      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_a.id
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

    test "SPEC.md §5.5 scheduler connect failure clears stale cold queue capacity" do
      QueueManager.reset()
      stale_hb = DateTime.add(DateTime.utc_now(), -120_000, :millisecond)
      observed_at = DateTime.utc_now()
      model_id = "scheduler-connect-clear-model"

      node_a =
        insert_node!(%{
          advertise_addr: "10.0.0.1",
          rpc_port: 50_061,
          health: :healthy,
          last_heartbeat_at: stale_hb
        })

      node_b = insert_node!(%{advertise_addr: "10.0.0.2", rpc_port: 50_062})

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-scheduler-connect-clear-a", model_id),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-scheduler-connect-clear-b", model_id),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_scheduler_clear_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)

      assert :ok =
               QueueManager.refresh_capacity(model_id, "v1", 1, source: {:node, node_a.id, :cold})

      assert_receive {:first_scheduler_clear_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      stub_connect_failure("10.0.0.1", 50_061, {:connect_failed, :econnrefused})

      stub_probe(
        "10.0.0.2",
        50_062,
        make_status(node_b.id, host: "10.0.0.2", port: 50_062)
      )

      assert {:ok, schedule} =
               MultiNode.schedule(canonical_request(model_id),
                 status_client: StubClient,
                 observed_at: observed_at
               )

      assert schedule.strategy == :multi_node
      assert schedule.node_id == node_b.id
      assert Repo.get!(Node, node_a.id).health == :unreachable

      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      assert :ok = QueueManager.refresh_capacity(model_id, "v1", 1, source: {:test, :restore})
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_key == "#{model_id}@v1"

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
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
end
