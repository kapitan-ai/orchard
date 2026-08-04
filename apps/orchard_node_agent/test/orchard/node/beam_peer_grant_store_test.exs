defmodule Orchard.Node.BeamPeerGrantStoreTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [band: 2]

  alias Orchard.Cluster.V1.{RetrieveBeamPeerGrantRequest, RetrieveBeamPeerGrantResponse}
  alias Orchard.Node.{BeamPeerGrantClient, BeamPeerGrantStore}
  alias Orchard.Node.BeamPeerGrantClient.GRPCTransport

  @fixture_activation_backdate_seconds 60
  @fixture_validity_seconds 30 * 24 * 60 * 60
  @fixture_anchor_tolerance_seconds 3600

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
    assert private_mode(Path.join(root, ".beam-peer-grants.install.lock")) == 0o600

    grant_path = Path.join([root, "beam-peer-grants", "#{identity.controller_id}.json"])
    assert private_mode(grant_path) == 0o600
    assert File.stat!(grant_path).uid == File.stat!(root).uid
  end

  test "SPEC.md §7.5.0 install narrows a store directory a concurrent creator left wide" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-narrow-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)

    # `File.mkdir/1` applies the umask, so this is exactly what a concurrent
    # installer sees between another installer creating the store directory and
    # narrowing it to owner-only.
    store_root = Path.join(root, "beam-peer-grants")
    File.mkdir!(store_root)
    File.chmod!(store_root, 0o755)

    assert {:ok, ^delivery} =
             BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)

    assert private_mode(store_root) == 0o700
  end

  test "SPEC.md §7.5.0 first-store initialization is serialized before permission narrowing" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-first-store-race-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    identity_root_uid = File.stat!(root).uid
    on_exit(fn -> File.rm_rf!(root) end)

    marker_path = Path.join(root, "second-lock-attempted")
    wrapper = Path.join(root, "lockf-marker-wrapper")

    File.write!(
      wrapper,
      """
      #!/bin/sh
      : > "#{marker_path}"
      exec /usr/bin/lockf "$@"
      """
    )

    File.chmod!(wrapper, 0o700)
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
          after_store_directory_created: fn store_root ->
            File.chmod!(store_root, 0o755)
            send(parent, {:store_directory_created, self(), store_root})

            receive do
              :resume_first_installer -> :ok
            end
          end
        )
      end)

    assert_receive {:store_directory_created, first_pid, store_root}, 5_000
    assert private_mode(store_root) == 0o755

    second =
      Task.async(fn ->
        result =
          BeamPeerGrantStore.install(
            root,
            identity,
            delivery,
            delivery.node_beam_name,
            lock_command: wrapper
          )

        send(parent, {:second_installer_finished, result})
        result
      end)

    try do
      wait_until(fn -> File.exists?(marker_path) end, 250)
      assert private_mode(store_root) == 0o755

      send(first_pid, :resume_first_installer)
      assert {:ok, ^delivery} = Task.await(first, 5_000)
      assert {:ok, ^delivery} = Task.await(second, 5_000)

      grant_path = Path.join(store_root, "#{identity.controller_id}.json")
      lock_path = Path.join(root, ".beam-peer-grants.install.lock")

      assert private_mode(store_root) == 0o700
      assert File.stat!(store_root).uid == identity_root_uid
      assert private_mode(grant_path) == 0o600
      assert private_mode(lock_path) == 0o600
      assert {:ok, ^delivery} = BeamPeerGrantStore.load(root, identity, delivery.node_beam_name)
    after
      send(first_pid, :resume_first_installer)
      Task.shutdown(first, :brutal_kill)
      Task.shutdown(second, :brutal_kill)
    end
  end

  test "SPEC.md §7.5.0 load waits for first-install publication and returns its exact grant" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-load-race-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)
    store_root = Path.join(root, "beam-peer-grants")
    grant_path = Path.join(store_root, "#{identity.controller_id}.json")
    parent = self()

    installer =
      Task.async(fn ->
        BeamPeerGrantStore.install(
          root,
          identity,
          delivery,
          delivery.node_beam_name,
          sync_directory: fn path ->
            if path == root do
              send(parent, {:first_store_ready_for_publication, self()})

              receive do
                :resume_publication -> :ok
              end
            end

            :ok
          end
        )
      end)

    assert_receive {:first_store_ready_for_publication, installer_pid}, 5_000
    assert private_mode(store_root) == 0o700
    refute File.exists?(grant_path)

    loader =
      Task.async(fn ->
        send(parent, :loader_started)
        BeamPeerGrantStore.load(root, identity, delivery.node_beam_name)
      end)

    try do
      assert_receive :loader_started
      assert Task.yield(loader, 250) == nil

      send(installer_pid, :resume_publication)
      assert {:ok, ^delivery} = Task.await(installer, 5_000)
      assert {:ok, ^delivery} = Task.await(loader, 5_000)
    after
      send(installer_pid, :resume_publication)
      Task.shutdown(installer, :brutal_kill)
      Task.shutdown(loader, :brutal_kill)
    end
  end

  test "SPEC.md §7.5.0 load preserves genuine absence without creating grant custody" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-missing-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root_uid = File.stat!(root).uid
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)

    assert {:error, :beam_peer_grant_missing} =
             BeamPeerGrantStore.load(root, identity, delivery.node_beam_name)

    refute File.exists?(Path.join(root, "beam-peer-grants"))

    lock_path = Path.join(root, ".beam-peer-grants.install.lock")
    assert File.lstat!(lock_path).type == :regular
    assert private_mode(lock_path) == 0o600
    assert File.stat!(lock_path).uid == root_uid
  end

  test "SPEC.md §7.5.0 load fails closed without repairing unsafe custody" do
    Enum.each([:wide_store, :store_symlink, :wide_grant, :grant_symlink], fn unsafe_kind ->
      root =
        Path.join(
          System.tmp_dir!(),
          "orchard-node-peer-grant-unsafe-load-#{unsafe_kind}-#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir!(root)
      File.chmod!(root, 0o700)
      on_exit(fn -> File.rm_rf!(root) end)

      identity = identity()
      delivery = delivery(identity)
      store_root = Path.join(root, "beam-peer-grants")
      grant_path = Path.join(store_root, "#{identity.controller_id}.json")

      case unsafe_kind do
        :wide_store ->
          File.mkdir!(store_root)
          File.chmod!(store_root, 0o755)

        :store_symlink ->
          target = Path.join(root, "store-target")
          File.mkdir!(target)
          File.chmod!(target, 0o700)
          File.ln_s!(target, store_root)

        :wide_grant ->
          assert {:ok, ^delivery} =
                   BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)

          File.chmod!(grant_path, 0o644)

        :grant_symlink ->
          assert {:ok, ^delivery} =
                   BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)

          target = Path.join(root, "grant-target")
          File.write!(target, "unchanged")
          File.chmod!(target, 0o600)
          File.rm!(grant_path)
          File.ln_s!(target, grant_path)
      end

      assert {:error, :beam_peer_grant_store_invalid} =
               BeamPeerGrantStore.load(root, identity, delivery.node_beam_name)

      case unsafe_kind do
        :wide_store -> assert private_mode(store_root) == 0o755
        :store_symlink -> assert File.lstat!(store_root).type == :symlink
        :wide_grant -> assert private_mode(grant_path) == 0o644
        :grant_symlink -> assert File.lstat!(grant_path).type == :symlink
      end
    end)
  end

  test "SPEC.md §7.5.0 load rejects malformed persisted grants" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-malformed-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)

    assert {:ok, ^delivery} =
             BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)

    grant_path = Path.join([root, "beam-peer-grants", "#{identity.controller_id}.json"])
    File.write!(grant_path, "not-json")
    File.chmod!(grant_path, 0o600)

    assert {:error, :beam_peer_grant_store_invalid} =
             BeamPeerGrantStore.load(root, identity, delivery.node_beam_name)

    assert File.read!(grant_path) == "not-json"
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

    # `install/5` spawns the `lockf` OS process before it reaches `remove_file`,
    # so the default 100ms `assert_receive` window is too tight under load.
    assert_receive {:publisher_cleanup, first_pid, temporary}, 5_000
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

    # `install/5` spawns the `lockf` OS process before it reaches `remove_file`,
    # so the default 100ms `assert_receive` window is too tight under load.
    assert_receive {:child_test_publisher_cleanup, first_pid, temporary}, 5_000
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

    lock_path = Path.join(root, ".beam-peer-grants.install.lock")
    File.write!(lock_path, "99999999\ndead-owner-token\n")
    File.chmod!(lock_path, 0o644)

    install =
      Task.async(fn ->
        BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)
      end)

    assert {:ok, ^delivery} = Task.await(install, 1_000)
    assert File.exists?(lock_path)
    assert private_mode(lock_path) == 0o600
  end

  test "SPEC.md §7.5.0 install rejects non-regular parent lock candidates before store creation" do
    Enum.each([:directory, :symlink], fn candidate_type ->
      root =
        Path.join(
          System.tmp_dir!(),
          "orchard-node-peer-grant-lock-candidate-#{candidate_type}-#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir!(root)
      File.chmod!(root, 0o700)
      on_exit(fn -> File.rm_rf!(root) end)

      lock_path = Path.join(root, ".beam-peer-grants.install.lock")

      target_path =
        case candidate_type do
          :directory ->
            File.mkdir!(lock_path)
            nil

          :symlink ->
            target = Path.join(root, "lock-target")
            File.write!(target, "unchanged")
            File.chmod!(target, 0o600)
            File.ln_s!(target, lock_path)
            target
        end

      identity = identity()
      delivery = delivery(identity)

      assert {:error, :beam_peer_grant_store_invalid} =
               BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)

      refute File.exists?(Path.join(root, "beam-peer-grants"))
      assert File.lstat!(lock_path).type == candidate_type

      if target_path do
        assert File.read!(target_path) == "unchanged"
      end
    end)
  end

  test "SPEC.md §7.5.0 a failed creation hook still narrows the store directory" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-hook-failure-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)
    store_root = Path.join(root, "beam-peer-grants")

    assert {:error, :beam_peer_grant_store_invalid} =
             BeamPeerGrantStore.install(
               root,
               identity,
               delivery,
               delivery.node_beam_name,
               after_store_directory_created: fn ^store_root ->
                 File.chmod!(store_root, 0o755)
                 {:error, :test_hook_failed}
               end
             )

    assert private_mode(store_root) == 0o700
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
             Path.join(root, ".beam-peer-grants.install.lock"),
             "/bin/cat"
           ]
  end

  test "SPEC.md §7.5.0 install fails closed when the lock process exits before teardown" do
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

    assert {:error, :beam_peer_grant_store_invalid} =
             BeamPeerGrantStore.install(
               root,
               identity,
               delivery,
               delivery.node_beam_name,
               lock_command: wrapper
             )

    grant_path = Path.join([root, "beam-peer-grants", "#{identity.controller_id}.json"])
    assert File.exists?(grant_path)

    assert {:ok, ^delivery} =
             BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)
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

  test "SPEC.md §7.5.0 the ordinary store fixture anchors its window to the current clock" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-calendar-independent-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    before_build = DateTime.utc_now()
    delivery = delivery(identity)

    assert DateTime.compare(delivery.not_before_at, before_build) == :lt

    assert DateTime.diff(before_build, delivery.not_before_at, :second) <
             @fixture_anchor_tolerance_seconds

    assert DateTime.diff(delivery.expires_at, delivery.not_before_at, :second) ==
             @fixture_validity_seconds

    assert {:ok, _stored} =
             BeamPeerGrantStore.install(root, identity, delivery, delivery.node_beam_name)

    assert {:ok, loaded} = BeamPeerGrantStore.load(root, identity, delivery.node_beam_name)
    assert loaded.grant_id == delivery.grant_id
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
             BeamPeerGrantStore.install(
               root,
               identity,
               expired,
               expired.node_beam_name,
               now: fn -> now end
             )

    refute File.exists?(Path.join([root, "beam-peer-grants", "#{identity.controller_id}.json"]))
  end

  test "SPEC.md §7.5.0 a not-yet-active grant is never persisted" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-peer-grant-not-active-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    identity = identity()
    delivery = delivery(identity)
    before_activation = DateTime.add(delivery.not_before_at, -1, :second)

    assert {:error, :beam_peer_grant_not_active} =
             BeamPeerGrantStore.install(
               root,
               identity,
               delivery,
               delivery.node_beam_name,
               now: fn -> before_activation end
             )

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

  defp delivery(identity), do: delivery(identity, DateTime.utc_now())

  defp delivery(identity, reference_time) do
    encoded_secret = Base.url_encode64(:binary.copy(<<5>>, 32), padding: false)
    not_before_at = DateTime.add(reference_time, -@fixture_activation_backdate_seconds, :second)

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
      issued_at: not_before_at,
      not_before_at: not_before_at,
      cutover_at: nil,
      expires_at: DateTime.add(not_before_at, @fixture_validity_seconds, :second),
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
