defmodule Orchard.API.Ops.WorkerRecoveryControllerTest do
  use Orchard.ConnCase, async: false

  import Ecto.Query
  alias Orchard.API.Router
  alias Orchard.{Governance, Repo}
  alias Orchard.Governance.AuditLog
  alias Orchard.Models.Model
  alias Orchard.Nodes.Node
  alias Orchard.RuntimeEndpoint.{ModelRef, Operation, Target}

  @moduletag :db

  defmodule Client do
    def connect(target), do: {:ok, target}

    def disconnect(_connection) do
      case Process.get(:recovery_disconnect) do
        :raise -> raise "cleanup failure"
        :exit -> exit(:cleanup_failure)
        _ -> :ok
      end
    end

    def inspect_worker_recovery(connection, ref, opts) do
      send(self(), {:recovery_deadline, :inspect, opts[:timeout]})
      send(self(), {:inspect_recovery, connection.node_id, ref})
      Process.get(:recovery_result)
    end

    def recover_worker_placement(_connection, command, opts) do
      send(self(), {:recovery_deadline, command.action, opts[:timeout]})
      send(self(), {:recover, command})
      Process.get(:recovery_result)
    end
  end

  defmodule FailingAudit do
    def changeset(log, attrs) do
      changeset = AuditLog.changeset(log, attrs)

      if attrs.action == Process.get(:fail_audit_action),
        do: Ecto.Changeset.add_error(changeset, :action, "unavailable"),
        else: changeset
    end
  end

  setup do
    node =
      %Node{}
      |> Node.changeset(%{
        id: Ecto.UUID.generate(),
        hostname: "recovery.local",
        display_name: "Recovery",
        advertise_addr: "10.253.1.2",
        rpc_port: 9444,
        state: :active,
        health: :healthy,
        capabilities: %{},
        tool_readiness: %{}
      })
      |> Repo.insert!()

    model =
      %Model{}
      |> Model.changeset(%{
        model_id: "recovery-model",
        version: "exact-v1",
        state: :active,
        format: "mlx",
        capabilities: ["text"],
        tokenizer: %{"type" => "huggingface", "ref" => "test/tokenizer"},
        artifact_uri: "file:///tmp/recovery-model",
        artifact_source_uri: "https://example.com/model",
        artifact_sha256: String.duplicate("a", 64),
        artifact_size_bytes: 1,
        resident_memory_bytes: 1,
        kv_cache_bytes_per_token: 1,
        prefill_workspace_bytes_per_token: 1,
        runtime_requirements: %{}
      })
      |> Repo.insert!()

    {:ok, tenant} = Governance.create_tenant(%{slug: "recovery-ops", name: "Recovery"})

    {:ok, account} =
      Governance.upsert_api_client(tenant, %{name: "operator", owner_contact: "ops@example.com"})

    {:ok, _binding} = Governance.ensure_cluster_admin_access(account)
    {:ok, %{token: token}} = Governance.create_api_client_api_token(account, %{name: "Primary"})

    configure(
      :inference,
      Keyword.merge(Application.get_env(:orchard_controller, :inference, []),
        runtime_endpoint_client_impl: Client,
        runtime_endpoint_targets: [
          %Target{id: "recovery", transport: :beam, address: node(), node_id: node.id}
        ]
      )
    )

    evidence = %{
      key: %{node_id: node.id, model_id: model.model_id, version: model.version},
      epoch: "epoch-1",
      owner_epoch: "epoch-1",
      revision: 4,
      state: "open",
      hydrated: true,
      eligible: false,
      reason: "placement_crash_breaker_open"
    }

    Process.put(:recovery_result, {:ok, evidence})

    %{
      node: node,
      model: model,
      token: token,
      evidence: evidence,
      path: "/ops/v1/worker-recovery/nodes/#{node.id}/models/#{model.id}"
    }
  end

  test "SPEC §12.2 status uses the exact catalog runtime identity and bounded evidence", ctx do
    Process.put(:recovery_result, {:ok, Map.put(ctx.evidence, :checkpoint, "not public")})
    conn = request(:get, ctx.path <> "?version=exact-v1", ctx.token)
    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert Jason.decode!(conn.resp_body) == Jason.decode!(Jason.encode!(ctx.evidence))

    assert_received {:inspect_recovery, node_id,
                     %ModelRef{model_id: "recovery-model", version: "exact-v1"}}

    assert node_id == ctx.node.id
  end

  test "SPEC §12.2 disconnect failure cannot mask an acknowledged recovery outcome", ctx do
    for failure <- [:raise, :exit] do
      Process.put(:recovery_disconnect, failure)
      assert request(:post, ctx.path, ctx.token, body()).status == 200
    end

    assert audit_actions() == [
             "worker_recovery.accepted",
             "worker_recovery.completed",
             "worker_recovery.accepted",
             "worker_recovery.completed"
           ]
  end

  test "mismatched endpoint evidence cannot relabel the catalog placement", ctx do
    evidence = put_in(ctx.evidence, [:key, :version], "other-version")
    Process.put(:recovery_result, {:ok, evidence})
    assert request(:get, ctx.path <> "?version=exact-v1", ctx.token).status == 503
    assert request(:post, ctx.path, ctx.token, body()).status == 503
    assert audit_actions() == ["worker_recovery.accepted", "worker_recovery.failed"]
  end

  test "Operator API refuses evidence outside the closed recovery state and reason vocabulary",
       ctx do
    for patch <- [
          %{state: "unknown_state"},
          %{reason: "worker_restart_backoff"},
          %{reason: nil},
          %{eligible: true}
        ] do
      Process.put(:recovery_result, {:ok, Map.merge(ctx.evidence, patch)})
      assert request(:get, ctx.path <> "?version=exact-v1", ctx.token).status == 503
    end
  end

  test "an unconfigured exact Node endpoint is unavailable without forwarding", ctx do
    configure(:inference, runtime_endpoint_client_impl: Client, runtime_endpoint_targets: [])
    assert request(:get, ctx.path <> "?version=exact-v1", ctx.token).status == 503
    refute_received {:inspect_recovery, _, _}
  end

  test "exact version and canonical catalog UUID are required", ctx do
    for path <- [
          ctx.path,
          ctx.path <> "?version=wrong",
          String.replace(ctx.path, ctx.model.id, ctx.model.model_id) <> "?version=exact-v1"
        ] do
      assert request(:get, path, ctx.token).status == 422
    end

    refute_received {:inspect_recovery, _, _}
  end

  test "SPEC §12.2 forced reload receives only catalog artifacts and audits both phases", ctx do
    assert request(:post, ctx.path, ctx.token, body("reload")).status == 200
    assert_received {:recover, command}
    assert command.key == ctx.evidence.key
    assert command.expected_epoch == "epoch-1"
    assert command.expected_revision == 4
    assert %Operation.EnsureModelLoadedRequest{} = command.load_request
    assert command.load_request.artifact_sha256 == ctx.model.artifact_sha256
    assert command.load_request.artifact_source_uri == ctx.model.artifact_source_uri
    assert command.load_request.model_ref == ModelRef.new!(ctx.model.model_id, ctx.model.version)
    assert command.load_request.deadline_unix_ms > System.system_time(:millisecond)
    assert audit_actions() == ["worker_recovery.accepted", "worker_recovery.completed"]
  end

  test "SPEC §12.2 only a forced reload spends the model load budget on the endpoint", ctx do
    configure(
      :inference,
      Keyword.merge(Application.get_env(:orchard_controller, :inference, []),
        model_load_timeout_ms: 90_000
      )
    )

    assert request(:get, ctx.path <> "?version=exact-v1", ctx.token).status == 200
    assert_received {:recovery_deadline, :inspect, 2_000}

    for action <- ["clear", "unload"] do
      assert request(:post, ctx.path, ctx.token, body(action)).status == 200
      assert_received {:recovery_deadline, ^action, 2_000}
    end

    assert request(:post, ctx.path, ctx.token, body("reload")).status == 200
    assert_received {:recovery_deadline, "reload", 90_000}
  end

  test "clear and unload never build a load request", ctx do
    for action <- ["clear", "unload"] do
      assert request(:post, ctx.path, ctx.token, body(action)).status == 200
      assert_received {:recover, %{action: ^action, load_request: nil}}
    end
  end

  test "rejects caller artifacts, checkpoint data, missing fences and unbounded input", ctx do
    for invalid <- [
          Map.put(body(), "load_request", %{}),
          Map.put(body(), "checkpoint", %{}),
          Map.delete(body(), "expected_epoch"),
          Map.put(body(), "expected_revision", "4"),
          Map.put(body(), "reason", " "),
          Map.put(body(), "reason", String.duplicate("a", 513)),
          Map.put(body(), "action", "force"),
          Map.put(body(), "version", "wrong")
        ] do
      assert request(:post, ctx.path, ctx.token, invalid).status == 422
    end

    refute_received {:recover, _}
    assert audit_actions() == []
  end

  test "stale epoch/revision and busy map to conflict without changing the command", ctx do
    Process.put(:recovery_result, {:error, :conflict})
    assert request(:post, ctx.path, ctx.token, body()).status == 409
    assert_received {:recover, %{expected_epoch: "epoch-1", expected_revision: 4}}
    assert audit_actions() == ["worker_recovery.accepted", "worker_recovery.failed"]
  end

  test "endpoint failures preserve stable status mappings", ctx do
    for {reason, status} <- [unavailable: 503, invalid_command: 422, permission_denied: 403] do
      Process.put(:recovery_result, {:error, reason})
      assert request(:post, ctx.path, ctx.token, body()).status == status
      assert request(:get, ctx.path <> "?version=exact-v1", ctx.token).status == status
    end
  end

  test "acceptance audit failure prevents forwarding", ctx do
    configure(:governance_audit_log_impl, FailingAudit)
    Process.put(:fail_audit_action, "worker_recovery.accepted")
    conn = request(:post, ctx.path, ctx.token, body())
    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "worker_recovery_audit_unavailable"
    refute_received {:recover, _}
  end

  test "completion audit failure cannot report success after forwarding", ctx do
    configure(:governance_audit_log_impl, FailingAudit)
    Process.put(:fail_audit_action, "worker_recovery.completed")
    assert request(:post, ctx.path, ctx.token, body()).status == 503
    assert_received {:recover, _}
    assert audit_actions() == ["worker_recovery.accepted"]
  end

  test "Operator authentication and Active Controller checks precede forwarding", ctx do
    assert request(:get, ctx.path <> "?version=exact-v1", nil).status == 401
    {:ok, tenant} = Governance.create_tenant(%{slug: "recovery-denied", name: "Denied"})
    {:ok, %{token: token}} = Governance.create_api_key(tenant, %{name: "Tenant"})
    assert request(:post, ctx.path, token, body()).status == 403
    configure(:control_plane, role: :standby)

    for {method, path, params} <- [
          {:get, ctx.path <> "?version=exact-v1", nil},
          {:post, ctx.path, body()}
        ] do
      conn = request(method, path, ctx.token, params)
      assert conn.status == 503
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "controller_standby"
    end

    refute_received {:recover, _}
    refute_received {:inspect_recovery, _, _}
  end

  defp body(action \\ "clear"),
    do: %{
      "version" => "exact-v1",
      "action" => action,
      "expected_epoch" => "epoch-1",
      "expected_revision" => 4,
      "command_id" => "command-1",
      "reason" => "Operator recovery"
    }

  defp request(method, path, token, body \\ nil) do
    conn =
      build_conn(method, path, body)
      |> Plug.Conn.fetch_query_params()
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn =
      if token,
        do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token),
        else: conn

    Router.call(conn, Router.init([]))
  end

  defp audit_actions do
    Repo.all(
      from(a in AuditLog,
        where: like(a.action, "worker_recovery.%"),
        order_by: [asc: a.occurred_at],
        select: a.action
      )
    )
  end

  defp configure(key, value) do
    previous = Application.get_env(:orchard_controller, key)
    Application.put_env(:orchard_controller, key, value)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:orchard_controller, key),
        else: Application.put_env(:orchard_controller, key, previous)
    end)
  end
end
