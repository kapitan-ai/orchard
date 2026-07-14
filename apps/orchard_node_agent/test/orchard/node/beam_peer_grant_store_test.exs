defmodule Orchard.Node.BeamPeerGrantStoreTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [band: 2]

  alias Orchard.Cluster.V1.{RetrieveBeamPeerGrantRequest, RetrieveBeamPeerGrantResponse}
  alias Orchard.Node.{BeamPeerGrantClient, BeamPeerGrantStore}
  alias Orchard.Node.BeamPeerGrantClient.GRPCTransport

  defmodule FakeControlTransport do
    def retrieve(target, credential, request) do
      send(self(), {:grant_control_retrieve, target, credential, request})
      Process.get(:beam_peer_grant_response)
    end
  end

  defmodule RaisingControlTransport do
    def retrieve(_target, _credential, _request), do: raise("transport failed")
  end

  defmodule DisconnectingGRPCConnector do
    def connect(_target, _opts), do: {:ok, :channel}
    def disconnect(:channel), do: raise("disconnect failed")
  end

  defmodule SuccessfulPeerGrantStub do
    def retrieve_beam_peer_grant(:channel, request, _opts) do
      send(self(), {:peer_grant_rpc, request})
      {:ok, Process.get(:beam_peer_grant_response)}
    end
  end

  defmodule RecordingGRPCConnector do
    def connect(_target, _opts), do: {:ok, :recording_channel}

    def disconnect(:recording_channel) do
      send(self(), :peer_grant_disconnect)
      :ok
    end
  end

  defmodule RaisingPeerGrantStub do
    def retrieve_beam_peer_grant(:recording_channel, _request, _opts), do: raise("rpc failed")
  end

  defmodule BoundedGRPCConnector do
    def connect(target, opts) do
      send(self(), {:peer_grant_connect, target, opts})
      {:ok, :bounded_channel}
    end

    def disconnect(:bounded_channel) do
      send(self(), :bounded_peer_grant_disconnect)
      :ok
    end
  end

  defmodule BoundedPeerGrantStub do
    def retrieve_beam_peer_grant(:bounded_channel, request, opts) do
      send(self(), {:bounded_peer_grant_rpc, request, opts})
      {:ok, Process.get(:beam_peer_grant_response)}
    end
  end

  test "SPEC.md §7.5.0 stores one exact delivered grant atomically under owner-only modes" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)

    assert {:ok, stored} =
             BeamPeerGrantStore.install(
               root,
               identity,
               delivery,
               delivery.node_beam_name
             )

    assert {:ok, ^stored} =
             BeamPeerGrantStore.install(
               root,
               identity,
               delivery,
               delivery.node_beam_name
             )

    assert {:ok, ^stored} = BeamPeerGrantStore.load(root, identity, delivery.node_beam_name)
    assert stored.encoded_secret == delivery.encoded_secret
    assert stored.generation == delivery.generation
    assert private_mode(Path.join(root, "beam-peer-grants")) == 0o700

    grant_path = Path.join([root, "beam-peer-grants", "#{identity.controller_id}.json"])
    assert private_mode(grant_path) == 0o600
    assert File.stat!(grant_path).uid == File.stat!(root).uid
  end

  test "SPEC.md §7.5.0 install sweeps orphaned plaintext temporaries left by a crash" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-sweep-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)

    assert {:ok, _stored} =
             BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)

    store_root = Path.join(root, "beam-peer-grants")

    orphan =
      Path.join(store_root, "#{identity.controller_id}.json.tmp-0123456789abcdef")

    File.write!(orphan, "plaintext-secret")
    File.chmod!(orphan, 0o600)
    assert File.exists?(orphan)

    assert {:ok, _stored} =
             BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)

    refute File.exists?(orphan)

    assert File.exists?(Path.join(store_root, "#{identity.controller_id}.json"))
  end

  test "SPEC.md §7.5.0 install fails closed when plaintext temporary cleanup fails" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-sweep-failure-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)

    assert {:ok, _stored} =
             BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)

    orphan =
      Path.join([
        root,
        "beam-peer-grants",
        "#{identity.controller_id}.json.tmp-fedcba9876543210"
      ])

    File.write!(orphan, "plaintext-secret")
    File.chmod!(orphan, 0o600)

    assert {:error, :beam_peer_grant_store_invalid} =
             BeamPeerGrantStore.install(
               root,
               identity,
               delivery,
               delivery.node_beam_name,
               remove_file: fn ^orphan -> {:error, :eacces} end
             )

    assert File.exists?(orphan)
  end

  test "SPEC.md §7.5.0 install fails closed when published temporary cleanup fails" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-publish-cleanup-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)

    assert {:error, :beam_peer_grant_store_invalid} =
             BeamPeerGrantStore.install(
               root,
               identity,
               delivery,
               delivery.node_beam_name,
               remove_file: fn _temporary -> {:error, :eacces} end
             )

    store_root = Path.join(root, "beam-peer-grants")

    assert Enum.any?(File.ls!(store_root), &String.contains?(&1, ".json.tmp-"))
  end

  test "SPEC.md §7.5.0 rejects an abbreviated IPv4 in a delivered grant name" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-abbreviated-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()

    delivery =
      identity
      |> delivery()
      |> Map.put(
        :controller_beam_name,
        "orchard_controller_bbbbbbbbbbbb4bbb8bbbbbbbbbbbbbbb@10.1"
      )

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)
  end

  test "SPEC.md §7.5.0 first installation syncs both durable directory entries" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-durable-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)
    test_pid = self()

    assert {:ok, _stored} =
             BeamPeerGrantStore.install(
               root,
               identity,
               delivery,
               delivery.node_beam_name,
               sync_directory: fn path ->
                 send(test_pid, {:directory_synced, path})
                 :ok
               end
             )

    store_root = Path.join(root, "beam-peer-grants")
    assert_receive {:directory_synced, ^root}
    assert_receive {:directory_synced, ^store_root}
    refute_receive {:directory_synced, _other}
  end

  test "SPEC.md §7.5.0 concurrent identical installations are idempotent" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-concurrent-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)
    parent = self()

    tasks =
      for _index <- 1..16 do
        Task.async(fn ->
          send(parent, {:installer_ready, self()})

          receive do
            :install ->
              BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)
          end
        end)
      end

    installers =
      for _index <- 1..16 do
        assert_receive {:installer_ready, installer}
        installer
      end

    Enum.each(installers, &send(&1, :install))
    results = Enum.map(tasks, &Task.await/1)

    assert Enum.all?(results, &match?({:ok, ^delivery}, &1))
    assert {:ok, ^delivery} = BeamPeerGrantStore.load(root, identity, delivery.node_beam_name)
  end

  test "SPEC.md §7.5.0 concurrent install cannot sweep an active publisher temporary" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-active-publisher-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)
    parent = self()

    first =
      Task.async(fn ->
        BeamPeerGrantStore.install(
          root,
          identity,
          delivery,
          delivery.node_beam_name,
          remove_file: fn temporary ->
            send(parent, {:publisher_cleanup, self(), temporary})

            receive do
              :continue_cleanup -> File.rm(temporary)
            end
          end
        )
      end)

    assert_receive {:publisher_cleanup, first_pid, temporary}
    assert File.exists?(temporary)

    second =
      Task.async(fn ->
        result = BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)
        send(parent, {:second_installer_finished, result})
        result
      end)

    refute_receive {:second_installer_finished, _result}, 100
    assert File.exists?(temporary)

    send(first_pid, :continue_cleanup)
    assert {:ok, ^delivery} = Task.await(first)
    assert {:ok, ^delivery} = Task.await(second)
  end

  test "SPEC.md §7.5.0 a child BEAM cannot sweep an active publisher temporary" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-child-publisher-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)
    parent = self()

    first =
      Task.async(fn ->
        BeamPeerGrantStore.install(
          root,
          identity,
          delivery,
          delivery.node_beam_name,
          remove_file: fn temporary ->
            send(parent, {:child_test_publisher_cleanup, self(), temporary})

            receive do
              :continue_cleanup -> File.rm(temporary)
            end
          end
        )
      end)

    assert_receive {:child_test_publisher_cleanup, first_pid, temporary}
    assert File.exists?(temporary)

    ready_path = Path.join(root, "child-ready")
    result_path = Path.join(root, "child-result")

    payload =
      {root, identity, delivery, delivery.node_beam_name, ready_path, result_path}
      |> :erlang.term_to_binary()
      |> Base.url_encode64(padding: false)

    child =
      Task.async(fn ->
        System.cmd(
          "elixir",
          child_elixir_args(payload),
          stderr_to_stdout: true
        )
      end)

    wait_until(fn -> File.exists?(ready_path) end)
    Process.sleep(250)
    refute File.exists?(result_path)
    assert File.exists?(temporary)

    send(first_pid, :continue_cleanup)
    assert {:ok, ^delivery} = Task.await(first)
    assert {_output, 0} = Task.await(child, 5_000)

    assert {:ok, ^delivery} =
             result_path
             |> File.read!()
             |> :erlang.binary_to_term([:safe])
  end

  test "SPEC.md §7.5.0 install reuses a lock file left by a dead BEAM OS process" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-dead-lock-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)

    assert {:ok, ^delivery} =
             BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)

    lock_path = Path.join([root, "beam-peer-grants", ".install.lock"])
    File.write!(lock_path, "99999999\ndead-owner-token\n")
    File.chmod!(lock_path, 0o600)

    install =
      Task.async(fn ->
        BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)
      end)

    assert {:ok, ^delivery} = Task.await(install, 1_000)
    assert File.exists?(lock_path)
    assert private_mode(lock_path) == 0o600
  end

  test "SPEC.md §7.5.0 install uses baseline macOS lockf arguments" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-lockf-args-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    wrapper = Path.join(root, "lockf-wrapper")
    args_path = wrapper <> ".args"

    File.write!(
      wrapper,
      """
      #!/bin/sh
      printf '%s\n' "$@" > "${0}.args"
      for argument in "$@"; do
        if [ "$argument" = "-w" ]; then
          exit 64
        fi
      done
      exec /usr/bin/lockf "$@"
      """
    )

    File.chmod!(wrapper, 0o700)
    identity = identity()
    delivery = delivery(identity)

    assert {:ok, ^delivery} =
             BeamPeerGrantStore.install(
               root,
               identity,
               delivery,
               delivery.node_beam_name,
               lock_command: wrapper
             )

    arguments = args_path |> File.read!() |> String.split("\n", trim: true)
    refute "-w" in arguments

    assert arguments == [
             "-k",
             "-s",
             "-t",
             "5",
             Path.join([root, "beam-peer-grants", ".install.lock"]),
             "/bin/cat"
           ]
  end

  test "SPEC.md §7.5.0 install returns the published grant when the lock process exits before teardown" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-lock-teardown-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    wrapper = Path.join(root, "lockf-exit-wrapper")

    File.write!(
      wrapper,
      """
      #!/bin/sh
      lockpath="$5"
      : > "$lockpath"
      chmod 600 "$lockpath"
      head -n 1
      exit 0
      """
    )

    File.chmod!(wrapper, 0o700)
    identity = identity()
    delivery = delivery(identity)

    assert {:ok, ^delivery} =
             BeamPeerGrantStore.install(
               root,
               identity,
               delivery,
               delivery.node_beam_name,
               lock_command: wrapper
             )

    grant_path = Path.join([root, "beam-peer-grants", "#{identity.controller_id}.json"])
    assert File.exists?(grant_path)
  end

  test "SPEC.md §7.5.0 restart rejects a stored secret that no longer matches its hash" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-corrupt-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)

    assert {:ok, _stored} =
             BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)

    path = Path.join([root, "beam-peer-grants", "#{identity.controller_id}.json"])
    persisted = path |> File.read!() |> Jason.decode!()
    forged_secret = Base.url_encode64(:binary.copy(<<9>>, 32), padding: false)
    File.write!(path, Jason.encode!(Map.put(persisted, "encoded_secret", forged_secret)))
    File.chmod!(path, 0o600)

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrantStore.load(root, identity, delivery.node_beam_name)
  end

  test "SPEC.md §7.5.0 a freshly delivered expired grant is never persisted" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-expired-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    now = DateTime.utc_now()

    expired =
      identity
      |> delivery()
      |> Map.merge(%{
        issued_at: DateTime.add(now, -120, :second),
        not_before_at: DateTime.add(now, -120, :second),
        expires_at: DateTime.add(now, -1, :second)
      })

    assert {:error, :beam_peer_grant_expired} =
             BeamPeerGrantStore.install(root, identity, expired, expired.node_beam_name)

    refute File.exists?(Path.join([root, "beam-peer-grants", "#{identity.controller_id}.json"]))
  end

  test "SPEC.md §7.5.0 a grant expiring before publication is never persisted" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-prepublish-expiry-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)
    calls = :atomics.new(1, signed: false)

    now = fn ->
      case :atomics.add_get(calls, 1, 1) do
        1 -> delivery.not_before_at
        _later -> delivery.expires_at
      end
    end

    assert {:error, :beam_peer_grant_expired} =
             BeamPeerGrantStore.install(
               root,
               identity,
               delivery,
               delivery.node_beam_name,
               now: now
             )

    refute File.exists?(Path.join([root, "beam-peer-grants", "#{identity.controller_id}.json"]))
  end

  test "SPEC.md §7.5.0 a newly published grant expiring before return is removed" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-final-expiry-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)
    calls = :atomics.new(1, signed: false)

    now = fn ->
      case :atomics.add_get(calls, 1, 1) do
        call when call <= 2 -> delivery.not_before_at
        _later -> delivery.expires_at
      end
    end

    assert {:error, :beam_peer_grant_expired} =
             BeamPeerGrantStore.install(
               root,
               identity,
               delivery,
               delivery.node_beam_name,
               now: now
             )

    store_root = Path.join(root, "beam-peer-grants")
    refute File.exists?(Path.join(store_root, "#{identity.controller_id}.json"))
    refute Enum.any?(File.ls!(store_root), &String.contains?(&1, ".json.tmp-"))
  end

  test "SPEC.md §7.5.0 installs the certificate-authenticated control response owner-only" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-response-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)

    response = response(delivery)

    assert {:ok, installed} =
             BeamPeerGrantClient.install_response(
               root,
               identity,
               delivery.node_beam_name,
               response
             )

    assert installed.encoded_secret == delivery.encoded_secret

    assert {:ok, ^installed} =
             BeamPeerGrantStore.load(root, identity, delivery.node_beam_name)
  end

  test "SPEC.md §7.5.0 Node retrieves with its certificate and exact Controller verifier" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-client-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity =
      identity()
      |> Map.merge(%{
        cacertfile: "/protected/runtime-ca.pem",
        certfile: "/protected/node-certificate.pem",
        controller_uri_san:
          "urn:orchard:cluster:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:controller:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        keyfile: "/protected/node-private-key.pem"
      })

    delivery = delivery(identity)
    response = response(delivery)
    Process.put(:beam_peer_grant_response, {:ok, response})

    request = %RetrieveBeamPeerGrantRequest{
      grant_id: delivery.grant_id,
      generation: delivery.generation,
      controller_id: delivery.controller_id
    }

    assert {:ok, installed} =
             BeamPeerGrantClient.retrieve_and_install(
               root,
               identity,
               delivery.node_beam_name,
               "10.0.0.10:50072",
               request,
               transport: FakeControlTransport
             )

    assert installed.grant_id == delivery.grant_id

    assert_receive {:grant_control_retrieve, "10.0.0.10:50072", %GRPC.Credential{ssl: ssl},
                    ^request}

    assert ssl[:certfile] == identity.certfile
    assert ssl[:keyfile] == identity.keyfile
    assert ssl[:cacertfile] == identity.cacertfile
    assert ssl[:verify] == :verify_peer
    assert ssl[:versions] == [:"tlsv1.3"]
  end

  test "SPEC.md §7.5.0 Node maps transport exceptions to one stable control error" do
    identity =
      identity()
      |> Map.merge(%{
        cacertfile: "/protected/runtime-ca.pem",
        certfile: "/protected/node-certificate.pem",
        controller_uri_san:
          "urn:orchard:cluster:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:controller:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        keyfile: "/protected/node-private-key.pem"
      })

    request = %RetrieveBeamPeerGrantRequest{
      grant_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      generation: 1,
      controller_id: identity.controller_id
    }

    assert {:error, :beam_peer_grant_control_unavailable} =
             BeamPeerGrantClient.retrieve_and_install(
               "/protected/identity",
               identity,
               "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20",
               "10.0.0.10:50072",
               request,
               transport: RaisingControlTransport
             )
  end

  test "SPEC.md §7.5.0 a response for another descriptor cannot mutate Node custody" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-response-scope-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity =
      identity()
      |> Map.merge(%{
        cacertfile: "/protected/runtime-ca.pem",
        certfile: "/protected/node-certificate.pem",
        controller_uri_san:
          "urn:orchard:cluster:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa:controller:bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        keyfile: "/protected/node-private-key.pem"
      })

    delivered = delivery(identity)
    Process.put(:beam_peer_grant_response, {:ok, response(delivered)})

    request = %RetrieveBeamPeerGrantRequest{
      grant_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
      generation: delivered.generation,
      controller_id: delivered.controller_id
    }

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrantClient.retrieve_and_install(
               root,
               identity,
               delivered.node_beam_name,
               "10.0.0.10:50072",
               request,
               transport: FakeControlTransport
             )

    refute File.exists?(Path.join([root, "beam-peer-grants", "#{identity.controller_id}.json"]))
  end

  test "SPEC.md §7.5.0 transport cleanup cannot erase a successful control response" do
    request = %RetrieveBeamPeerGrantRequest{
      grant_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      generation: 1,
      controller_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    }

    response = response(delivery(identity()))
    Process.put(:beam_peer_grant_response, response)

    assert {:ok, ^response} =
             GRPCTransport.retrieve(
               "10.0.0.10:50072",
               :credential,
               request,
               connector: DisconnectingGRPCConnector,
               service_stub: SuccessfulPeerGrantStub
             )

    assert_received {:peer_grant_rpc, ^request}
  end

  test "SPEC.md §7.5.0 transport cleanup closes the channel when the control RPC raises" do
    request = %RetrieveBeamPeerGrantRequest{
      grant_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      generation: 1,
      controller_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    }

    assert {:error, :beam_peer_grant_control_unavailable} =
             GRPCTransport.retrieve(
               "10.0.0.10:50072",
               :credential,
               request,
               connector: RecordingGRPCConnector,
               service_stub: RaisingPeerGrantStub
             )

    assert_received :peer_grant_disconnect
  end

  test "SPEC.md §7.5.0 grant control connect and RPC operations have explicit deadlines" do
    request = %RetrieveBeamPeerGrantRequest{
      grant_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      generation: 1,
      controller_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    }

    response = response(delivery(identity()))
    Process.put(:beam_peer_grant_response, response)

    assert {:ok, ^response} =
             GRPCTransport.retrieve(
               "10.0.0.10:50072",
               :credential,
               request,
               connector: BoundedGRPCConnector,
               service_stub: BoundedPeerGrantStub,
               connect_timeout_ms: 321,
               rpc_timeout_ms: 654
             )

    assert_received {:peer_grant_connect, "10.0.0.10:50072",
                     [cred: :credential, adapter_opts: [transport_opts: [timeout: 321]]]}

    assert_received {:bounded_peer_grant_rpc, ^request, [timeout: 654]}
    assert_received :bounded_peer_grant_disconnect
  end

  defp identity do
    %{
      cluster_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      controller_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      controller_certificate_identifier: "serial:100",
      controller_certificate_fingerprint: "sha256-controller",
      node_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      certificate_identifier: "node-cert-1",
      certificate_fingerprint: "sha256-node"
    }
  end

  defp delivery(identity) do
    encoded_secret = Base.url_encode64(:binary.copy(<<5>>, 32), padding: false)

    %{
      grant_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      generation: 1,
      cluster_id: identity.cluster_id,
      controller_id: identity.controller_id,
      controller_beam_name: "orchard_controller_bbbbbbbbbbbb4bbb8bbbbbbbbbbbbbbb@10.0.0.10",
      controller_certificate_identifier: identity.controller_certificate_identifier,
      controller_certificate_fingerprint_sha256: identity.controller_certificate_fingerprint,
      beam_authorization_root_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      node_id: identity.node_id,
      node_beam_name: "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20",
      node_certificate_identifier: identity.certificate_identifier,
      node_certificate_fingerprint_sha256: identity.certificate_fingerprint,
      contract_version: 1,
      purpose: "runtime_endpoint",
      issued_at: ~U[2026-07-13 08:00:00.000000Z],
      not_before_at: ~U[2026-07-13 08:00:00.000000Z],
      cutover_at: nil,
      expires_at: ~U[2026-08-12 08:00:00.000000Z],
      encoded_secret: encoded_secret,
      secret_hash: :crypto.hash(:sha256, encoded_secret)
    }
  end

  defp response(delivery) do
    struct!(
      RetrieveBeamPeerGrantResponse,
      delivery
      |> Map.update!(:issued_at, &DateTime.to_iso8601/1)
      |> Map.update!(:not_before_at, &DateTime.to_iso8601/1)
      |> Map.update!(:cutover_at, fn nil -> "" end)
      |> Map.update!(:expires_at, &DateTime.to_iso8601/1)
    )
  end

  defp private_mode(path) do
    {:ok, stat} = File.stat(path)
    band(stat.mode, 0o777)
  end

  defp child_elixir_args(payload) do
    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    script = """
    [payload] = System.argv()

    {root, identity, delivery, node_name, ready_path, result_path} =
      payload
      |> Base.url_decode64!(padding: false)
      |> :erlang.binary_to_term([:safe])

    File.write!(ready_path, "ready")
    result = Orchard.Node.BeamPeerGrantStore.install(root, identity, delivery, node_name)
    File.write!(result_path, :erlang.term_to_binary(result))
    """

    code_paths ++ ["-e", script, "--", payload]
  end

  defp wait_until(condition, attempts \\ 100)

  defp wait_until(condition, attempts) when attempts > 0 do
    if condition.() do
      :ok
    else
      Process.sleep(20)
      wait_until(condition, attempts - 1)
    end
  end

  defp wait_until(_condition, 0), do: flunk("condition not reached before timeout")
end
