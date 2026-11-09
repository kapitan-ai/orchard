defmodule Orchard.API.Ops.ClusterReadsControllerTest do
  use Orchard.ConnCase, async: false

  alias Orchard.API.Router
  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, ApiKeySecret, RoleBinding}
  alias Orchard.Nodes.{AdmissionDecision, Node}
  alias Orchard.PackagedNodeCommand
  alias Orchard.Repo

  @moduletag :db

  defmodule RuntimeClient do
    @moduledoc false

    def connect(_target), do: {:ok, :channel}
    def disconnect(_channel), do: :ok

    def status(_channel, _opts) do
      {:ok, Application.fetch_env!(:orchard_controller, :operator_reads_runtime_response)}
    end
  end

  setup do
    previous = Application.get_env(:orchard_controller, :control_plane)
    previous_console = Application.get_env(:orchard_controller, :console, [])
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(:orchard_controller, :control_plane,
      role: :leader,
      this_controller_identity: "serving-controller",
      control_plane_status_provider: fn ->
        %{leader_identity: "serving-controller", advisory_lock_status: :held}
      end
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous_console)
      Application.put_env(:orchard_controller, :inference, previous_inference)
      Application.delete_env(:orchard_controller, :operator_reads_runtime_response)

      if is_nil(previous),
        do: Application.delete_env(:orchard_controller, :control_plane),
        else: Application.put_env(:orchard_controller, :control_plane, previous)
    end)

    node =
      %Node{}
      |> Node.changeset(%{
        id: Ecto.UUID.generate(),
        hostname: "operator-read.local",
        display_name: "Operator read",
        advertise_addr: "10.20.30.40",
        rpc_port: 9444,
        state: :registered,
        health: :healthy
      })
      |> Repo.insert!()

    %AdmissionDecision{}
    |> AdmissionDecision.changeset(%{
      node_id: node.id,
      decision: :admitted,
      actor_type: "service_account",
      reason: "Private admission reason",
      metadata: %{"private" => "admission metadata"},
      decided_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    {:ok, node: node}
  end

  for route <- [:cluster, :nodes, :node] do
    @route route

    test "SPEC.md §7.3 #{@route} rejects missing and invalid credentials with no-store",
         context do
      for token <- [
            nil,
            "invalid",
            ApiKeySecret.generate().token,
            client_token!(:operator, :cluster, expires_at: ~U[2020-01-01 00:00:00.000000Z]),
            client_token!(:operator, :cluster, revoked_at: ~U[2020-01-01 00:00:00.000000Z])
          ] do
        conn = request(path(@route, context.node), token)
        assert_error(conn, 401, "invalid_api_key")
      end

      malformed =
        build_conn(:get, path(@route, context.node))
        |> put_req_header("authorization", "Token invalid")
        |> Router.call(Router.init([]))

      assert_error(malformed, 401, "invalid_api_key")
    end

    test "SPEC.md §7.3 #{@route} refuses tenant-direct and tenant-scoped authority", context do
      {:ok, tenant} = Governance.create_tenant(%{slug: "tenant-direct", name: "Tenant"})
      {:ok, %{token: direct_token}} = Governance.create_api_key(tenant, %{name: "Direct"})

      for token <- [
            direct_token,
            client_token!(:operator, :tenant),
            client_token!(:admin, :tenant),
            client_token!(nil, :cluster)
          ] do
        assert_error(request(path(@route, context.node), token), 403, "operator_required")
      end
    end

    test "SPEC.md §7.3 #{@route} refuses a disabled cluster API Client", context do
      token = client_token!(:operator, :cluster, disabled: true)
      assert_error(request(path(@route, context.node), token), 403, "operator_required")
    end

    test "SPEC.md §7.3 #{@route} allows cluster operator and admin reads on Active", context do
      for role <- [:operator, :admin] do
        conn = request(path(@route, context.node), client_token!(role, :cluster))
        assert conn.status == 200
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert_payload(@route, Jason.decode!(conn.resp_body), context.node)
      end
    end
  end

  test "SPEC.md §7.3 only cluster status is served on Standby or with unproven leadership", %{
    node: node
  } do
    token = client_token!(:operator, :cluster)

    for {role, code} <- [standby: "controller_standby", leader: "controller_leadership_unproven"] do
      Application.put_env(:orchard_controller, :control_plane,
        role: role,
        this_controller_identity: "serving-controller"
      )

      before_state = domain_rows()

      for route <- [:nodes, :node] do
        assert_error(request(path(route, node), token), 503, code)
      end

      conn = request("/ops/v1/cluster", token)
      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      expected_role = if role == :standby, do: "standby", else: "unknown"
      assert Jason.decode!(conn.resp_body)["control_plane"]["controller_role"] == expected_role
      assert domain_rows() == before_state
    end
  end

  test "SPEC.md §7.3 successful inspect probes do not mutate domain rows, including CLI", %{
    node: node
  } do
    configure_successful_probe(node)
    token = client_token!(:operator, :cluster)
    before_state = domain_rows()

    for route <- [:cluster, :nodes, :node] do
      conn = request(path(route, node), token)
      assert conn.status == 200

      if route == :node do
        assert [%{"recommended_context_tokens" => 4096}] =
                 Jason.decode!(conn.resp_body)["memory_budget"]["runtime_memory_budgets"]
      end
    end

    assert {:ok, output} =
             PackagedNodeCommand.run(["inspect", node.id, "--json"], fn fun, _opts -> fun.() end)

    assert Jason.decode!(output)["memory_budget"]["runtime_memory_budgets"] != []

    for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
      assert request("/ops/v1/nodes/#{id}", token).status == 404
    end

    assert domain_rows() == before_state

    # Control: the existing observing path must still persist a successful probe.
    assert [%{status: :ok}] = OrchardConsole.Runtime.cluster_snapshot()
    refute domain_rows() == before_state
  end

  for route <- [:nodes, :node] do
    @route route

    test "SPEC.md §7.3 #{@route} read-time Repo failure returns database_unavailable", %{
      node: node
    } do
      token = client_token!(:operator, :cluster)
      Repo.query!("ALTER TABLE nodes RENAME TO unavailable_nodes")
      conn = request(path(@route, node), token)
      assert_error(conn, 503, "database_unavailable")
      refute conn.resp_body =~ "unavailable_nodes"
    end
  end

  test "SPEC.md §7.3 missing and malformed Node IDs have identical errors" do
    token = client_token!(:operator, :cluster)

    errors =
      for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        conn = request("/ops/v1/nodes/#{id}", token)
        assert_error(conn, 404, "node_not_found")
        Jason.decode!(conn.resp_body)
      end

    assert errors ==
             List.duplicate(
               %{"error" => %{"code" => "node_not_found", "message" => "Node was not found."}},
               2
             )
  end

  test "SPEC.md §7.3 empty inventory returns the shared empty list", %{node: node} do
    Repo.delete!(node)
    conn = request("/ops/v1/nodes", client_token!(:operator, :cluster))
    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert %{
             "object" => "cluster_management.node_status_list",
             "contract_version" => "orchard.cluster_management.status.v1",
             "data" => [],
             "summary" => %{"total" => 0, "by_state" => states, "by_health" => health}
           } = Jason.decode!(conn.resp_body)

    assert Enum.all?(Map.values(states), &(&1 == 0))
    assert Enum.all?(Map.values(health), &(&1 == 0))
  end

  defp assert_payload(:cluster, body, _node) do
    assert body["object"] == "cluster_management.cluster_status"
    assert body["summary"]["controller_role"] == "leader"
    assert body["control_plane"]["this_controller_identity"] == "serving-controller"
    assert body["control_plane"]["leader_identity"] == "serving-controller"
    assert body["control_plane"]["advisory_lock_status"] == "held"
  end

  defp assert_payload(:nodes, body, node) do
    assert body["object"] == "cluster_management.node_status_list"
    assert body["summary"]["total"] == 1
    assert [status] = body["data"]
    assert status["resource"] == %{"type" => "node", "id" => node.id}
  end

  defp assert_payload(:node, body, node) do
    assert body["object"] == "node"
    assert body["id"] == node.id
    assert body["hostname"] == node.hostname
    assert body["status"]["admission"]["category"] == "pending_registered"
    assert Enum.sort(Map.keys(body["latest_decision"])) == ["decided_at", "decision", "object"]
    assert body["latest_decision"]["decision"] == "admitted"
    assert body["latest_decision"]["object"] == "node_admission_decision"
  end

  defp assert_error(conn, status, code) do
    assert conn.status == status
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert %{"error" => %{"code" => ^code, "message" => message}} = Jason.decode!(conn.resp_body)
    assert is_binary(message)
  end

  defp path(:cluster, _node), do: "/ops/v1/cluster"
  defp path(:nodes, _node), do: "/ops/v1/nodes"
  defp path(:node, node), do: "/ops/v1/nodes/#{node.id}"

  defp request(path, token) do
    conn = build_conn(:get, path) |> put_req_header("accept", "application/json")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, Router.init([]))
  end

  defp client_token!(role, scope, opts \\ []) do
    slug = "ops-reads-#{System.unique_integer([:positive])}"
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: slug})

    {:ok, client} =
      Governance.upsert_api_client(tenant, %{name: slug, owner_contact: "owner@example.com"})

    if role do
      %RoleBinding{}
      |> RoleBinding.changeset(%{
        principal_type: :service_account,
        principal_id: client.id,
        role: role,
        tenant_scope_id: if(scope == :tenant, do: tenant.id)
      })
      |> Repo.insert!()
    end

    {:ok, %{token: token}} = Governance.create_api_client_api_token(client, %{name: "Primary"})
    {:ok, prefix} = ApiKeySecret.token_prefix(token)

    ApiKey
    |> Repo.get_by!(token_prefix: prefix)
    |> Ecto.Changeset.change(Keyword.take(opts, [:expires_at, :revoked_at]))
    |> Repo.update!()

    if opts[:disabled] do
      {:ok, _client} = Governance.disable_api_client(tenant, client)
    end

    token
  end

  defp configure_successful_probe(node) do
    Application.put_env(:orchard_controller, :console,
      enabled: false,
      runtime_impl: OrchardConsole.Runtime,
      runtime_client_impl: RuntimeClient,
      nodes_impl: Orchard.Nodes
    )

    Application.put_env(:orchard_controller, :operator_reads_runtime_response, %{
      worker_state: :WORKER_STATE_IDLE,
      loaded_models: [],
      active_request_count: 0,
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        listen_host: node.advertise_addr,
        listen_port: node.rpc_port,
        agent_version: "test",
        worker_backend: "stub"
      },
      runtime_health: %{ready: true},
      runtime_memory_budgets: [%{model_ref: "test@v1", recommended_context_tokens: 4096}]
    })

    inference = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(inference,
        runtime_endpoint_targets: [],
        runtime_client_targets: [[host: node.advertise_addr, port: node.rpc_port]],
        allow_static_runtime_target_fallback: true
      )
    )
  end

  defp domain_rows do
    %{rows: tables} = Repo.query!("SELECT tablename FROM pg_tables WHERE schemaname = 'public'")

    Map.new(tables, fn [table] ->
      quoted = String.replace(table, "\"", "\"\"")
      %{rows: rows} = Repo.query!(~s|SELECT to_jsonb(t) FROM "#{quoted}" t|)

      {table, rows |> Enum.map(&domain_row(table, &1)) |> Enum.sort()}
    end)
  end

  defp domain_row("api_keys", [row]), do: Map.delete(row, "last_used_at")
  defp domain_row(_table, [row]), do: row
end
