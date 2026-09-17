defmodule Orchard.WorkerRecovery.CheckpointsTest do
  use Orchard.DataCase, async: false

  alias Orchard.BeamPeerGrants
  alias Orchard.Models.Model
  alias Orchard.Node.{ModelManager, WorkerRecoveryCheckpointClient}
  alias Orchard.Node.Supervisor, as: NodeSupervisor
  alias Orchard.NodeEnrollment.PKI
  alias Orchard.Nodes.{Enrollment, Node}
  alias Orchard.NodeTrust.PKI, as: NodeTrustPKI
  alias Orchard.RuntimeEndpoint.WorkerRecoveryCheckpoint
  alias Orchard.TransportTLS.CertificateIdentity
  alias Orchard.WorkerRecovery.{Checkpoint, Checkpoints}

  setup do
    now = DateTime.utc_now()
    cluster = Ecto.UUID.generate()
    controller = Ecto.UUID.generate()
    authority = Ecto.UUID.generate()

    node =
      Repo.insert!(%Node{display_name: Ecto.UUID.generate(), state: :active, health: :healthy})

    model =
      Repo.insert!(%Model{
        model_id: "recovery-model",
        version: "v1",
        state: :active,
        format: "mlx",
        artifact_uri: "file:///models/test",
        artifact_sha256: String.duplicate("a", 64),
        artifact_size_bytes: 1,
        resident_memory_bytes: 1,
        kv_cache_bytes_per_token: 0,
        prefill_workspace_bytes_per_token: 0
      })

    {:ok, ca} =
      NodeTrustPKI.generate(cluster, controller, authority, Ecto.UUID.generate(), now)

    {:ok, csr} = PKI.generate_csr(cluster, node.id)

    {:ok, issued} =
      PKI.issue_node_certificate(%{
        csr_pem: csr.csr_pem,
        cluster_id: cluster,
        node_id: node.id,
        ca_private_key_pem: ca.ca_private_key_pem,
        ca_certificate_pem: ca.ca_certificate_pem,
        now: now,
        serial: 379,
        certificate_identifier: "serial:379"
      })

    enrollment =
      Repo.insert!(%Enrollment{
        node_id: node.id,
        cluster_id: cluster,
        expected_controller_id: controller,
        trust_authority_id: authority,
        token_prefix: "test379",
        token_hash: "test-only",
        state: :consumed,
        creator_type: "operator",
        issued_at: now,
        published_at: now,
        consumed_at: now,
        expires_at: DateTime.add(now, 3600),
        certificate_issuance_outcome: :issued,
        certificate_identifier: "serial:379",
        certificate_result: %{
          "node_certificate_pem" => issued.certificate_pem,
          "node_uri_san" => issued.node_uri_san,
          "runtime_trust_spki_sha256" => ca.ca_spki_fingerprint
        }
      })

    [{:Certificate, certificate, :not_encrypted}] = :public_key.pem_decode(issued.certificate_pem)

    %{
      key: %{node_id: node.id, model_id: model.model_id, version: model.version},
      node: node,
      model: model,
      certificate: certificate,
      enrollment: enrollment,
      ca: ca,
      csr: csr,
      issued: issued
    }
  end

  test "SPEC §12.2 authoritative absence, write-ahead ownership, and lost-ack replay", ctx do
    assert {:ok, :absent} = Checkpoints.read(ctx.key, ctx.certificate)
    record = record("loading")
    assert {:ok, first} = commit(ctx, nil, 0, "transition-1", record)
    assert first.revision == 1
    assert {:ok, ^first} = commit(ctx, nil, 0, "transition-1", record)
    assert {:error, :stale_checkpoint} = commit(ctx, nil, 0, "transition-2", record)
    assert {:ok, ^first} = Checkpoints.read(ctx.key, ctx.certificate)
    refute WorkerRecoveryCheckpoint.clean?(first.record)
  end

  test "SPEC §12.2 epoch claim cannot erase open/history or unresolved ownership", ctx do
    open = %{record("loaded") | "state" => "open", "crashes" => [-1, -2], "delay_index" => 2}
    assert {:ok, _} = commit(ctx, nil, 0, "open", open)

    assert {:error, :unresolved_epoch_claim} =
             commit(ctx, "epoch-1", 1, "unsafe", %{open | "epoch" => "epoch-2"})

    clean = %{record("resolved") | "epoch" => "epoch-2"}
    assert {:error, :unresolved_epoch_claim} = commit(ctx, "epoch-1", 1, "erase", clean)

    resolved =
      put_in(open, ["ownership", "phase"], "operator_terminated") |> Map.put("epoch", "epoch-2")

    assert {:ok, %{revision: 2}} = commit(ctx, "epoch-1", 1, "claim", resolved)
    assert {:error, :stale_checkpoint} = commit(ctx, "epoch-1", 1, "late", open)
  end

  test "SPEC §12.2 authenticated exact Node/model/version and revoked enrollment", ctx do
    wrong_node = %{ctx.key | node_id: Ecto.UUID.generate()}
    assert {:error, :unauthorized_checkpoint} = Checkpoints.read(wrong_node, ctx.certificate)

    assert {:error, :unauthorized_checkpoint} =
             Checkpoints.read(%{ctx.key | version: "unknown"}, ctx.certificate)

    assert {:error, :unauthorized_checkpoint} = Checkpoints.read(ctx.key, <<>>)

    ctx.enrollment
    |> Ecto.Changeset.change(state: :revoked, revoked_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:error, :unauthorized_checkpoint} = commit(ctx, nil, 0, "late", record("loading"))
  end

  test "SPEC §12.2 deletes checkpoints when the referenced model is deleted", ctx do
    assert {:ok, _checkpoint} = commit(ctx, nil, 0, "transition-1", record("loading"))

    Repo.delete!(ctx.model)

    assert [] = Repo.all(Checkpoint)
  end

  test "SPEC §12.2 deletes checkpoints when the referenced node is deleted", ctx do
    assert {:ok, _checkpoint} = commit(ctx, nil, 0, "transition-1", record("loading"))

    Repo.delete!(ctx.enrollment)
    Repo.delete!(ctx.node)

    assert [] = Repo.all(Checkpoint)
  end

  test "SPEC §12.2 checkpoint rejects unbounded or content-bearing fields", ctx do
    assert {:error, :invalid_checkpoint} =
             commit(ctx, nil, 0, "bad", Map.put(record("resolved"), "prompt", "secret"))

    assert {:error, :invalid_checkpoint} =
             commit(ctx, nil, 0, "bad", %{record("resolved") | "crashes" => Enum.to_list(1..6)})

    assert {:ok, :absent} = Checkpoints.read(ctx.key, ctx.certificate)
  end

  test "SPEC §12.2 real Node manager hydrates and commits through authenticated Controller Postgres RPC",
       ctx do
    root = Path.join(System.tmp_dir!(), "orchard-checkpoint-wire-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)

    paths =
      Map.new(
        [
          ca: ctx.ca.ca_certificate_pem,
          server: ctx.ca.controller_certificate_pem,
          server_key: ctx.ca.controller_private_key_pem,
          node: ctx.issued.certificate_pem,
          node_key: ctx.csr.private_key_pem
        ],
        fn {name, pem} ->
          path = Path.join(root, Atom.to_string(name) <> ".pem")
          File.write!(path, pem)
          File.chmod!(path, 0o600)
          {name, path}
        end
      )

    {:ok, socket} = :gen_tcp.listen(0, active: false)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    credential =
      GRPC.Credential.new(
        ssl: [
          certfile: paths.server,
          keyfile: paths.server_key,
          cacertfile: paths.ca,
          verify: :verify_peer,
          fail_if_no_peer_cert: true,
          versions: [:"tlsv1.3"]
        ]
      )

    start_supervised!(
      {GRPC.Server.Supervisor,
       endpoint: BeamPeerGrants.ControlEndpoint,
       port: port,
       start_server: true,
       adapter_opts: [ip: {127, 0, 0, 1}, cred: credential]}
    )

    {:ok, certificate} =
      CertificateIdentity.from_pem(ctx.ca.controller_certificate_pem)

    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)
    :ok = Supervisor.terminate_child(NodeSupervisor, ModelManager)

    identity = %{
      node_id: ctx.key.node_id,
      certfile: paths.node,
      keyfile: paths.node_key,
      cacertfile: paths.ca,
      controller_uri_san: hd(certificate.uri_sans),
      controller_certificate_identifier: "serial:#{certificate.serial}",
      controller_certificate_fingerprint: certificate.fingerprint
    }

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(runtime,
        node_id: ctx.key.node_id,
        grpc_security: :mutual_tls,
        runtime_tls_identity: identity,
        worker_recovery_checkpoint_client: WorkerRecoveryCheckpointClient,
        worker_recovery_control_endpoint: "127.0.0.1:#{port}"
      )
    )

    start_supervised!(ModelManager)

    on_exit(fn ->
      Application.put_env(:orchard_node_agent, :runtime, runtime)
      Supervisor.restart_child(NodeSupervisor, ModelManager)
      File.rm_rf!(root)
    end)

    assert {:ok, %{revision: 0, hydrated: true, eligible: true} = evidence} =
             ModelManager.inspect_worker_recovery(ctx.key.model_id, ctx.key.version)

    command = %{
      key: ctx.key,
      expected_epoch: evidence.epoch,
      expected_revision: 0,
      command_id: "wire-clear",
      action: "clear",
      reason: "authenticated exercise"
    }

    assert {:ok, %{eligible: true, revision: revision}} =
             ModelManager.recover_worker_placement(command)

    assert revision >= 3
    assert {:ok, saved} = Checkpoints.read(ctx.key, ctx.certificate)
    assert saved.record["command"]["phase"] == "completed"
    assert saved.record["command"]["outcome"] == "ok"

    assert {:ok, %{revision: ^revision}} =
             ModelManager.recover_worker_placement(command)
  end

  defp commit(ctx, epoch, revision, id, record),
    do: Checkpoints.commit(ctx.key, epoch, revision, id, record, ctx.certificate)

  defp record(phase) do
    %{
      "epoch" => "epoch-1",
      "state" => "armed",
      "delay_index" => 0,
      "crashes" => [],
      "stable_since" => nil,
      "ownership" => %{"phase" => phase, "incarnation" => "worker-1", "custody" => nil},
      "command" => nil
    }
  end
end
