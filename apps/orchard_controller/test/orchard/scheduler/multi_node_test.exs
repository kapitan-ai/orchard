defmodule Orchard.Scheduler.MultiNodeTest do
  use Orchard.DataCase, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
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
      {:ok, target}
    end

    def status(target, _opts) do
      key = {Keyword.fetch!(target, :host), Keyword.fetch!(target, :port)}

      case Process.get({:stub_status, key}) do
        nil -> {:error, :unavailable}
        :error -> {:error, :probe_failed}
        response -> {:ok, response}
      end
    end

    def disconnect(_channel), do: :ok
  end

  # -- Helpers --

  defp canonical_request(model_id \\ "test-model", version \\ "v1") do
    CanonicalRequest.new(%{
      internal_id: "int_#{System.unique_integer([:positive])}",
      public_id: "pub_#{System.unique_integer([:positive])}",
      endpoint: :chat_completions,
      tenant_id: "tenant_test",
      model_ref: %ModelRef{model_id: model_id, version: version}
    })
  end

  defp insert_node!(overrides \\ %{}) do
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

  defp make_status(node_id, opts \\ []) do
    loaded_models = Keyword.get(opts, :loaded_models, [])
    active_request_count = Keyword.get(opts, :active_request_count, 0)
    health = Keyword.get(opts, :health, nil)
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
      active_request_count: active_request_count
    }
  end

  defp stub_probe(host, port, response) do
    Process.put({:stub_status, {host, port}}, response)
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
end
