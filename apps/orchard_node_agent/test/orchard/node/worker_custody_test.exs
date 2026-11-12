defmodule Orchard.Node.WorkerCustodyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.Node.CustodyTestHelpers
  alias Orchard.Node.ModelManager
  alias Orchard.Node.RuntimeProcessReaper
  alias Orchard.Node.Worker.V1.{WorkerRuntimeService, WorkerStatusResponse}
  alias Orchard.Node.WorkerManagerStub
  alias Orchard.Node.WorkerProcess
  alias Orchard.Node.WorkerProcessLifecycle
  alias Orchard.Node.WorkerRuntimeAdapter
  alias Orchard.Node.WorkerSupervisor

  defmodule ReadyWorkerService do
    use GRPC.Server, service: WorkerRuntimeService.Service

    def get_status(_request, _stream), do: %WorkerStatusResponse{ready: true}
    def load_model(_request, _stream), do: %Orchard.Cluster.V1.Ack{ok: true}
  end

  defmodule ReadyWorkerEndpoint do
    use GRPC.Endpoint

    run(ReadyWorkerService)
  end

  @shutdown_timeout_ms 200
  @stale_identity "0 Thu Jan 1 00:00:00 1970"
  @closed_port_budget_ms 600
  @kill_confirm_reserve_ms 250
  @escalation_slack_ms 150

  setup do
    assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
    CustodyTestHelpers.assert_reaper_empty!(1_000)

    root = unique_tmp_root!()

    models_root = Path.join(root, "models")
    model_ref = %ModelRef{model_id: "custody/test", version: "v1"}
    File.mkdir_p!(Path.join([models_root, model_ref.model_id, model_ref.version]))

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      log_path: Path.join(root, "worker.log"),
      model_ref: model_ref,
      models_root: models_root,
      root: root,
      socket_path: Path.join(root, "worker.sock")
    }
  end

  defp unique_tmp_root! do
    root =
      Path.join(
        "/tmp",
        "oc-#{System.unique_integer([:positive, :monotonic])}"
      )

    case File.mkdir(root) do
      :ok -> root
      {:error, :eexist} -> unique_tmp_root!()
      {:error, reason} -> raise "could not create custody test root #{root}: #{inspect(reason)}"
    end
  end

  test "SPEC.md §4.9 worker readiness honors its budget when the UDS never appears", context do
    executable = waiting_worker!(context)
    escalation_overhead_ms = measure_escalation_overhead!(context)
    started = System.monotonic_time(:millisecond)

    assert {:error, :worker_ready_timeout} =
             load_runtime(context, executable: executable, ready_timeout_ms: 100)

    assert System.monotonic_time(:millisecond) - started < 2_000 + 2 * escalation_overhead_ms
    CustodyTestHelpers.assert_reaper_empty!(1_000)
    refute File.exists?(context.socket_path)
  end

  test "SPEC.md §4.9 readiness accepts a worker UDS that starts asynchronously",
       context do
    executable = waiting_worker!(context)
    test_pid = self()

    server =
      Task.async(fn ->
        send(test_pid, {:worker_server_waiting, self()})

        receive do
          :start -> run_delayed_worker_server(context)
          :stop -> :ok
        end
      end)

    try do
      assert_receive {:worker_server_waiting, server_pid}, 2_000
      send(server_pid, :start)

      assert {:ok, state} =
               load_runtime(context, executable: executable, ready_timeout_ms: 2_000)

      assert :ok = WorkerRuntimeAdapter.unload_model(state, skip_rpc: true)
      CustodyTestHelpers.assert_reaper_empty!(1_000)
    after
      send(server.pid, :stop)
      Task.await(server)
    end
  end

  defp run_delayed_worker_server(context) do
    Process.sleep(150)

    {:ok, supervisor} =
      GRPC.Server.Supervisor.start_link(
        endpoint: ReadyWorkerEndpoint,
        port: 0,
        start_server: true,
        adapter_opts: [ip: {:local, context.socket_path}]
      )

    receive do
      :stop -> Supervisor.stop(supervisor)
    end
  end

  defp waiting_worker!(context) do
    executable = Path.join(context.root, "waiting-worker")
    File.write!(executable, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(executable, 0o755)
    executable
  end

  test "SPEC.md §4.9 explicit unload reaps the exact stub runtime PID and socket", context do
    state = load_stub_runtime!(context)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(state.port, state.os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
    end)

    assert WorkerProcessLifecycle.os_process_alive?(state.os_pid)
    assert File.exists?(state.socket_path)
    assert :ok = WorkerRuntimeAdapter.unload_model(state, [])

    CustodyTestHelpers.assert_os_pid_dead!(state.os_pid, 2_000)
    refute File.exists?(state.socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    CustodyTestHelpers.assert_reaper_empty!(1_000)

    assert CustodyTestHelpers.wait_until(
             fn ->
               case File.read(state.log_path) do
                 {:ok, contents} -> String.contains?(contents, "worker stopping")
                 {:error, _reason} -> false
               end
             end,
             1_000
           )
  end

  test "SPEC.md §4.9 loaded runtime lease reports the loaded phase", context do
    state = load_stub_runtime!(context)
    on_exit(fn -> CustodyTestHelpers.stop_child(state.port, state.os_pid) end)

    assert %{phase: :loaded} = :sys.get_state(RuntimeProcessReaper).leases[state.reaper_ref]
    assert :ok = WorkerRuntimeAdapter.unload_model(state, [])
    CustodyTestHelpers.assert_reaper_empty!(1_000)
  end

  test "SPEC.md §4.9 owner shutdown during unload reaps with the unloading phase", context do
    parent = self()

    owner =
      spawn(fn ->
        state = load_stub_runtime!(context)
        send(parent, {:loaded, state})

        receive do
          :unload -> WorkerRuntimeAdapter.unload_model(state, [])
        end
      end)

    assert_receive {:loaded, state}, 10_000
    on_exit(fn -> CustodyTestHelpers.stop_child(state.port, state.os_pid) end)

    # A stopped Worker holds the unload RPC open, so the owner exits mid-unload.
    {_output, 0} = System.cmd("kill", ["-STOP", Integer.to_string(state.os_pid)])
    send(owner, :unload)

    assert CustodyTestHelpers.wait_until(
             fn ->
               match?(
                 %{phase: :unloading},
                 :sys.get_state(RuntimeProcessReaper).leases[state.reaper_ref]
               )
             end,
             500
           )

    previous_level = Logger.level()
    Logger.configure(level: :info)

    log =
      try do
        capture_log([level: :info], fn ->
          Process.exit(owner, :shutdown)
          CustodyTestHelpers.assert_os_pid_dead!(state.os_pid, 2_000)
          CustodyTestHelpers.assert_reaper_empty!(1_000)
        end)
      after
        Logger.configure(level: previous_level)
      end

    assert log =~ "[info] reaping worker process after its owner stopped"
    assert log =~ "phase: :unloading"
  end

  test "SPEC.md §4.9 closed BEAM port still reaps its live recorded PID", context do
    state = load_stub_runtime!(context)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(state.port, state.os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
    end)

    Port.close(state.port)
    assert is_nil(Port.info(state.port))
    assert WorkerProcessLifecycle.os_process_alive?(state.os_pid)

    assert :ok = WorkerRuntimeAdapter.unload_model(state, skip_rpc: true)

    CustodyTestHelpers.assert_os_pid_dead!(state.os_pid, 2_000)
    refute File.exists?(state.socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    CustodyTestHelpers.assert_reaper_empty!(1_000)
  end

  test "SPEC.md §4.9 open and closed BEAM ports refuse to signal a recycled PID", context do
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(control_port, control_pid) end)

    File.write!(context.socket_path, "owned runtime artifact")

    state = %{
      backend: "stub",
      channel: nil,
      executable: Path.expand("../../support/custody-signal-child", __DIR__),
      generations: %{},
      model_ref: context.model_ref,
      os_identity: @stale_identity,
      os_pid: control_pid,
      port: exited_port!(),
      reaper_ref: nil,
      shutdown_timeout_ms: @shutdown_timeout_ms,
      socket_path: context.socket_path
    }

    for port <- [control_port, state.port] do
      log =
        capture_log(fn ->
          assert :ok = WorkerRuntimeAdapter.unload_model(%{state | port: port}, skip_rpc: true)
        end)

      assert log =~ "worker custody identity mismatch"
      assert log =~ "os_pid=#{control_pid}"
      assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    end

    refute File.exists?(context.socket_path)
  end

  test "SPEC.md §4.9 open and closed ports without launch identity do not signal a recorded PID or claim it stopped",
       context do
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(control_port, control_pid) end)

    File.write!(context.socket_path, "owned runtime artifact")

    state = %{
      backend: "stub",
      channel: nil,
      executable: Path.expand("../../support/custody-signal-child", __DIR__),
      generations: %{},
      model_ref: context.model_ref,
      os_identity: nil,
      os_pid: control_pid,
      port: exited_port!(),
      reaper_ref: nil,
      shutdown_timeout_ms: @shutdown_timeout_ms,
      socket_path: context.socket_path
    }

    for port <- [control_port, state.port] do
      log =
        capture_log(fn ->
          assert {:error, :worker_custody_unconfirmed} =
                   WorkerRuntimeAdapter.unload_model(%{state | port: port}, skip_rpc: true)
        end)

      assert log =~ "worker custody identity unavailable"
      assert log =~ "os_pid=#{control_pid}"
      assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    end

    refute File.exists?(context.socket_path)
    CustodyTestHelpers.assert_reaper_empty!(1_000)
  end

  test "SPEC.md §4.9 an unconfirmed unload hands its lease to the reaper instead of releasing it",
       context do
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()
    owner_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      Process.exit(owner_pid, :kill)
      CustodyTestHelpers.stop_child(control_port, control_pid)
    end)

    {:ok, reaper_ref} =
      RuntimeProcessReaper.watch(owner_pid, control_pid, %{
        shutdown_timeout_ms: @shutdown_timeout_ms,
        model_ref: context.model_ref,
        os_identity: nil,
        phase: :loaded,
        socket_path: context.socket_path
      })

    state = %{
      backend: "stub",
      channel: nil,
      executable: Path.expand("../../support/custody-signal-child", __DIR__),
      generations: %{},
      model_ref: context.model_ref,
      os_identity: nil,
      os_pid: control_pid,
      port: exited_port!(),
      reaper_ref: reaper_ref,
      shutdown_timeout_ms: @shutdown_timeout_ms,
      socket_path: context.socket_path
    }

    key = {context.model_ref.model_id, context.model_ref.version}

    for port <- [control_port, state.port] do
      capture_log(fn ->
        assert {:error, :worker_custody_unconfirmed} =
                 WorkerRuntimeAdapter.unload_model(%{state | port: port}, skip_rpc: true)
      end)

      # The stop could not confirm exit, so the lease stays and the model stays
      # pending; a replacement for it must not start yet.
      assert {:ok, keys} = RuntimeProcessReaper.custody_model_keys()
      assert MapSet.member?(keys, key)
      assert Map.has_key?(:sys.get_state(RuntimeProcessReaper).leases, reaper_ref)
    end

    CustodyTestHelpers.stop_child(control_port, control_pid)
    CustodyTestHelpers.assert_reaper_empty!(10_000)
    assert {:ok, keys} = RuntimeProcessReaper.custody_model_keys()
    refute MapSet.member?(keys, key)
  end

  @tag :macos
  test "SPEC.md §4.9 failed launch identity retains custody and blocks replacement without signalling",
       context do
    assert :ok = ModelManager.reset()
    fake_bin = Path.join(context.root, "fake-bin")
    fake_ps = Path.join(fake_bin, "ps")
    worker = Path.join(context.root, "identity-unavailable-worker")
    worker_pid_file = Path.join(context.root, "unconfirmed-worker.pid")
    signals = Path.join(context.root, "signals")
    real_kill = System.find_executable("kill")
    owner = spawn(fn -> Process.sleep(:infinity) end)
    File.mkdir_p!(fake_bin)

    File.write!(fake_ps, """
    #!/bin/sh
    if [ "$1" = '-o' ]; then echo "$6" > '#{worker_pid_file}'; fi
    exit 1
    """)

    File.chmod!(fake_ps, 0o755)

    File.write!(Path.join(fake_bin, "kill"), """
    #!/bin/sh
    if [ "$1" != '-0' ]; then printf '%s %s\n' "$1" "$2" >> '#{signals}'; fi
    exec '#{real_kill}' "$@"
    """)

    File.chmod!(Path.join(fake_bin, "kill"), 0o755)
    File.write!(worker, "#!/bin/sh\ntrap 'exit 0' TERM\nwhile :; do sleep 1; done\n")
    File.chmod!(worker, 0o755)
    File.write!(context.socket_path, "owned runtime artifact")
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()
    previous_path = System.fetch_env!("PATH")

    on_exit(fn ->
      Process.exit(owner, :kill)
      CustodyTestHelpers.stop_child(control_port, control_pid)

      with {:ok, pid} <- File.read(worker_pid_file) do
        WorkerProcessLifecycle.kill_process_tree(pid |> String.trim() |> String.to_integer())
      end

      CustodyTestHelpers.assert_reaper_empty!(10_000)
    end)

    result =
      try do
        System.put_env("PATH", fake_bin <> ":" <> previous_path)

        WorkerRuntimeAdapter.load_model(context.model_ref,
          backend: "stub",
          executable: worker,
          load_timeout_ms: 5_000,
          log_path: context.log_path,
          models_root: context.models_root,
          owner: owner,
          ready_timeout_ms: 100,
          shutdown_timeout_ms: @shutdown_timeout_ms,
          socket_path: context.socket_path
        )
      after
        System.put_env("PATH", previous_path)
      end

    assert result == {:error, :identity_unavailable}
    refute File.exists?(context.socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    os_pid = worker_pid_file |> File.read!() |> String.trim() |> String.to_integer()
    assert WorkerProcessLifecycle.os_process_alive?(os_pid)

    assert [%{os_identity: nil, phase: :loading, os_pid: ^os_pid}] =
             Map.values(:sys.get_state(RuntimeProcessReaper).leases)

    Process.exit(owner, :kill)
    key = {context.model_ref.model_id, context.model_ref.version}
    assert {:ok, keys} = RuntimeProcessReaper.custody_model_keys()
    assert MapSet.member?(keys, key)

    assert %{failure_code: "model_capacity_exhausted"} =
             ModelManager.ensure_model_loaded(%EnsureModelLoadedRequest{
               node_id: "node-local",
               model_id: context.model_ref.model_id,
               version: context.model_ref.version,
               artifact_sha256: String.duplicate("0", 64),
               preload: true,
               deadline_unix_ms: System.system_time(:millisecond) + 5_000,
               artifact_source_uri: "file:///nonexistent"
             })

    assert :sys.get_state(ModelManager).inflight_loads == %{}
    refute File.exists?(signals)
    assert WorkerProcessLifecycle.os_process_alive?(os_pid)
    WorkerProcessLifecycle.kill_process_tree(os_pid)
    CustodyTestHelpers.assert_reaper_empty!(10_000)
  end

  test "SPEC.md §4.9 launch identity failure retains a deterministic worker exit status",
       context do
    fake_bin = Path.join(context.root, "slow-ps-bin")
    fake_ps = Path.join(fake_bin, "ps")
    worker = Path.join(context.root, "immediate-exit-worker")
    File.mkdir_p!(fake_bin)
    # macOS delays identity capture here. Linux reads /proc for identity; this
    # fixture only delays its ps -p liveness fallback after a failed kill -0.
    File.write!(fake_ps, "#!/bin/sh\nsleep 0.5\nexit 1\n")
    File.chmod!(fake_ps, 0o755)
    File.write!(worker, "#!/bin/sh\nexit 42\n")
    File.chmod!(worker, 0o755)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()
    previous_path = System.fetch_env!("PATH")

    on_exit(fn -> CustodyTestHelpers.stop_child(control_port, control_pid) end)

    result =
      try do
        System.put_env("PATH", fake_bin <> ":" <> previous_path)

        WorkerRuntimeAdapter.load_model(context.model_ref,
          backend: "stub",
          executable: worker,
          load_timeout_ms: 5_000,
          log_path: context.log_path,
          models_root: context.models_root,
          owner: self(),
          ready_timeout_ms: 5_000,
          shutdown_timeout_ms: @shutdown_timeout_ms,
          socket_path: context.socket_path
        )
      after
        System.put_env("PATH", previous_path)
      end

    assert {:error, {:worker_exited, 42}} = result
    refute File.exists?(context.socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    CustodyTestHelpers.assert_reaper_empty!(1_000)
  end

  test "SPEC.md §4.9 an open launch port retains its pending spontaneous exit", context do
    {port, _os_pid, fifo} = fifo_worker!(context)

    # A different port's status must not be mistaken for this worker's exit.
    other_port = Port.open({:spawn_executable, System.find_executable("true")}, [:exit_status])
    assert CustodyTestHelpers.wait_until(fn -> is_nil(Port.info(other_port)) end, 1_000)

    probe = fn ->
      assert Port.info(port)
      File.write!(fifo, "exit\n")
      :not_alive
    end

    assert {:worker_exited, 42} =
             WorkerRuntimeAdapter.launch_identity_failure_reason(port, probe, 5_000)

    refute_received {^port, _}
    assert_receive {^other_port, {:exit_status, 0}}, 1_000
  end

  test "SPEC.md §4.9 live or unproven launch identity failures do not wait for an exit",
       context do
    {port, os_pid, _fifo} = fifo_worker!(context)

    for status <- [:alive, :unknown] do
      started = System.monotonic_time(:millisecond)

      assert :identity_unavailable =
               WorkerRuntimeAdapter.launch_identity_failure_reason(port, fn -> status end, 5_000)

      assert System.monotonic_time(:millisecond) - started < 500
      assert WorkerProcessLifecycle.os_process_alive?(os_pid)
    end
  end

  test "SPEC.md §4.9 pending exit diagnostic timeout is bounded despite port output", context do
    {port, os_pid, fifo} = fifo_worker!(context, "while printf 'output\\n'; do :; done")

    probe = fn ->
      File.write!(fifo, "exit\n")
      :not_alive
    end

    started = System.monotonic_time(:millisecond)

    assert :identity_unavailable =
             WorkerRuntimeAdapter.launch_identity_failure_reason(port, probe, 50)

    assert System.monotonic_time(:millisecond) - started < 500
    assert WorkerProcessLifecycle.os_process_alive?(os_pid)
  end

  test "SPEC.md §4.9 rejected watch resolves custody, removes socket, and leaves control alive without signalling",
       context do
    fake_bin = Path.join(context.root, "watch-probe-bin")
    fifo = Path.join(context.root, "watch-exit.fifo")
    rejected = Path.join(context.root, "watch-rejected")
    signalled = Path.join(context.root, "cleanup-signalled")
    worker = Path.join(context.root, "watch-exit-worker")
    real_ps = System.find_executable("ps")
    real_kill = System.find_executable("kill")
    File.mkdir_p!(fake_bin)
    assert {"", 0} = System.cmd("mkfifo", [fifo])

    File.write!(worker, """
    #!/bin/sh
    : > '#{context.socket_path}'
    read -r release < '#{fifo}'
    exit 42
    """)

    File.chmod!(worker, 0o755)

    # Identity capture sees a live FIFO-blocked child. The watch's liveness
    # probe then releases it and reports nonexistence, without a timing delay.
    File.write!(Path.join(fake_bin, "kill"), """
    #!/bin/sh
    if [ "$1" = '-0' ]; then
      if [ ! -e '#{rejected}' ]; then
        printf 'exit\n' > '#{fifo}'
        : > '#{rejected}'
      fi
      exit 1
    fi
    : > '#{signalled}'
    exec '#{real_kill}' "$@"
    """)

    File.write!(Path.join(fake_bin, "ps"), """
    #!/bin/sh
    if [ "$1" = '-p' ]; then exit 1; fi
    exec '#{real_ps}' "$@"
    """)

    for command <- ["kill", "ps"], do: File.chmod!(Path.join(fake_bin, command), 0o755)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()
    on_exit(fn -> CustodyTestHelpers.stop_child(control_port, control_pid) end)
    previous_path = System.fetch_env!("PATH")

    result =
      try do
        System.put_env("PATH", fake_bin <> ":" <> previous_path)
        load_runtime(context, executable: worker)
      after
        System.put_env("PATH", previous_path)
      end

    assert File.exists?(rejected)
    assert result == {:error, {:worker_exited, 42}}
    assert RuntimeProcessReaper.owner_custody(self()) == :resolved
    refute File.exists?(signalled)
    refute File.exists?(context.socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    CustodyTestHelpers.assert_reaper_empty!(1_000)
  end

  test "SPEC.md §4.9 launch nonexistence probe distinguishes live and reaped FIFO workers",
       context do
    {port, os_pid, fifo} = fifo_worker!(context)

    refute WorkerRuntimeAdapter.launch_process_status(os_pid) == :not_alive
    File.write!(fifo, "exit\n")
    assert_receive {^port, {:exit_status, 42}}, 1_000
    assert WorkerRuntimeAdapter.launch_process_status(os_pid) == :not_alive
  end

  for phase <- [:launch, :term] do
    @tag cleanup_phase: phase
    test "SPEC.md §4.9 #{phase} timeout never signals a reaped PID with an open port", context do
      %{cleanup_phase: phase} = context
      fake_bin = Path.join(context.root, "cleanup-bin")
      exit_fifo = Path.join(context.root, "parent-exit.fifo")
      hold_fifo = Path.join(context.root, "hold-output.fifo")
      holder_file = Path.join(context.root, "holder.pid")
      recorded_file = Path.join(context.root, "recorded.pid")
      signals = Path.join(context.root, "signals")
      worker = Path.join(context.root, "reaped-worker")
      real_kill = System.find_executable("kill")
      real_ps = System.find_executable("ps")
      File.mkdir_p!(fake_bin)
      for fifo <- [exit_fifo, hold_fifo], do: assert({"", 0} = System.cmd("mkfifo", [fifo]))
      {control_port, control_pid} = CustodyTestHelpers.start_control_child!()
      ports_before = Port.list()

      # The child keeps stdout open after its parent is reaped, withholding the
      # port's exit_status without relying on scheduler timing or PID recycling.
      File.write!(worker, """
      #!/bin/sh
      sh -c 'echo $$ > "#{holder_file}"; read -r release < "#{hold_fifo}"' &
      read -r release < '#{exit_fifo}'
      exit 42
      """)

      File.write!(Path.join(fake_bin, "kill"), """
      #!/bin/sh
      if [ "$1" = '-0' ]; then
        if [ -f '#{recorded_file}' ]; then exec '#{real_kill}' "$@"; fi
        if [ '#{phase}' = 'term' ]; then exec '#{real_kill}' "$@"; fi
        echo "$2" > '#{recorded_file}'
        while [ ! -f '#{holder_file}' ]; do sleep 0.01; done
        printf 'exit\n' > '#{exit_fifo}'
        while '#{real_kill}' -0 "$2" 2>/dev/null; do sleep 0.01; done
        exit 1
      fi
      if [ '#{phase}' = 'term' ] && [ "$1" = '-TERM' ]; then
        exec '#{real_kill}' "$@"
      fi
      printf '%s %s\n' "$1" "$2" >> '#{signals}'
      # Stand in for PID reuse: any unsafe signal hits the unrelated control.
      exec '#{real_kill}' "$1" '#{control_pid}'
      """)

      File.write!(Path.join(fake_bin, "ps"), """
      #!/bin/sh
      if [ "$1" = '-p' ]; then exit 1; fi
      exec '#{real_ps}' "$@"
      """)

      for path <- [worker, Path.join(fake_bin, "kill"), Path.join(fake_bin, "ps")],
          do: File.chmod!(path, 0o755)

      on_exit(fn ->
        CustodyTestHelpers.stop_child(control_port, control_pid)

        case File.read(holder_file) do
          {:ok, pid} -> System.cmd(real_kill, ["-KILL", String.trim(pid)], stderr_to_stdout: true)
          _missing -> :ok
        end
      end)

      previous_path = System.fetch_env!("PATH")

      result =
        try do
          System.put_env("PATH", fake_bin <> ":" <> previous_path)

          case phase do
            :launch ->
              load_runtime(context, executable: worker)

            :term ->
              port = Port.open({:spawn_executable, worker}, [:exit_status])
              os_pid = port |> Port.info() |> Keyword.fetch!(:os_pid)
              File.write!(recorded_file, Integer.to_string(os_pid))
              assert CustodyTestHelpers.wait_until(fn -> File.exists?(holder_file) end, 1_000)
              assert {:ok, identity} = WorkerProcessLifecycle.process_identity(os_pid)

              state = %{
                backend: "stub",
                channel: nil,
                executable: worker,
                generations: %{},
                model_ref: context.model_ref,
                os_identity: identity,
                os_pid: os_pid,
                port: port,
                reaper_ref: nil,
                shutdown_timeout_ms: @shutdown_timeout_ms,
                socket_path: context.socket_path
              }

              WorkerRuntimeAdapter.unload_model(state, skip_rpc: true)
          end
        after
          System.put_env("PATH", previous_path)
        end

      os_pid = recorded_file |> File.read!() |> String.trim() |> String.to_integer()
      assert WorkerRuntimeAdapter.launch_process_status(os_pid) == :not_alive

      assert Enum.any?(
               Port.list() -- ports_before,
               &(Port.info(&1, :os_pid) == {:os_pid, os_pid})
             )

      assert {File.read(signals), WorkerProcessLifecycle.os_process_alive?(control_pid)} ==
               {{:error, :enoent}, true}

      expected_reason =
        if phase == :launch, do: :identity_unavailable, else: :worker_custody_unconfirmed

      assert result == {:error, expected_reason}
      if phase == :launch, do: assert(RuntimeProcessReaper.owner_custody(self()) == :resolved)
      CustodyTestHelpers.assert_reaper_empty!(1_000)
    end
  end

  for phase <- [:term, :kill] do
    @tag exit_proof: phase
    test "SPEC.md §4.9 port exit confirms shutdown when identity disappears before #{phase}",
         context do
      %{exit_proof: phase} = context
      exit_fifo = Path.join(context.root, "exit.fifo")
      hold_fifo = Path.join(context.root, "hold.fifo")
      holder_file = Path.join(context.root, "holder.pid")
      for fifo <- [exit_fifo, hold_fifo], do: assert({"", 0} = System.cmd("mkfifo", [fifo]))

      port =
        Port.open({:spawn_executable, System.find_executable("sh")}, [
          :binary,
          :exit_status,
          args: [
            "-c",
            """
            sh -c 'echo $$ > "#{holder_file}"; read -r release < "#{hold_fifo}"' &
            printf ready
            read -r release < '#{exit_fifo}'
            exit 42
            """
          ]
        ])

      os_pid = port |> Port.info() |> Keyword.fetch!(:os_pid)

      on_exit(fn ->
        CustodyTestHelpers.stop_child(port, os_pid)

        with {:ok, pid} <- File.read(holder_file) do
          WorkerProcessLifecycle.kill_process_tree(pid |> String.trim() |> String.to_integer())
        end
      end)

      assert_receive {^port, {:data, "ready"}}, 1_000
      assert CustodyTestHelpers.wait_until(fn -> File.exists?(holder_file) end, 1_000)
      assert {:ok, identity} = WorkerProcessLifecycle.process_identity(os_pid)

      if phase == :term do
        File.write!(exit_fifo, "exit\n")

        assert CustodyTestHelpers.wait_until(
                 fn -> WorkerRuntimeAdapter.launch_process_status(os_pid) == :not_alive end,
                 2_000
               )

        assert Port.info(port)
      end

      release =
        Task.async(fn ->
          assert CustodyTestHelpers.wait_until(
                   fn -> WorkerRuntimeAdapter.launch_process_status(os_pid) == :not_alive end,
                   2_000
                 )

          Process.sleep(if phase == :term, do: 350, else: 750)
          File.write!(hold_fifo, "exit\n")
        end)

      state = %{
        backend: "stub",
        channel: nil,
        executable: "sh",
        generations: %{},
        model_ref: context.model_ref,
        os_identity: identity,
        os_pid: os_pid,
        port: port,
        reaper_ref: nil,
        shutdown_timeout_ms: if(phase == :term, do: 1_000, else: 500),
        socket_path: nil
      }

      result = WorkerRuntimeAdapter.unload_model(state, skip_rpc: true)
      Task.await(release, 5_000)
      assert result == :ok
      assert is_nil(Port.info(port))
    end
  end

  defp fifo_worker!(context, after_release \\ "exit 42") do
    fifo = Path.join(context.root, "exit.fifo")
    assert {"", 0} = System.cmd("mkfifo", [fifo])

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", "printf ready; read -r release < '#{fifo}'; #{after_release}"]
      ])

    os_pid = port |> Port.info() |> Keyword.fetch!(:os_pid)
    on_exit(fn -> CustodyTestHelpers.stop_child(port, os_pid) end)
    assert_receive {^port, {:data, "ready"}}, 1_000
    assert Port.info(port)
    {port, os_pid, fifo}
  end

  test "SPEC.md §4.9 closed BEAM port unload spends its shutdown budget once", context do
    marker_path = Path.join(context.root, "events.log")
    {port, os_pid} = CustodyTestHelpers.start_signal_child!(:resistant, marker_path)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(port, os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
    end)

    escalation_overhead_ms = measure_escalation_overhead!(context)

    assert {:ok, os_identity} = WorkerProcessLifecycle.process_identity(os_pid)
    File.write!(context.socket_path, "owned runtime artifact")

    Port.close(port)
    assert is_nil(Port.info(port))
    assert WorkerProcessLifecycle.os_process_alive?(os_pid)

    state = %{
      backend: "stub",
      channel: nil,
      executable: Path.expand("../../support/custody-signal-child", __DIR__),
      generations: %{},
      model_ref: context.model_ref,
      os_identity: os_identity,
      os_pid: os_pid,
      port: port,
      reaper_ref: nil,
      shutdown_timeout_ms: @closed_port_budget_ms,
      socket_path: context.socket_path
    }

    started = System.monotonic_time(:millisecond)
    assert :ok = WorkerRuntimeAdapter.unload_model(state, skip_rpc: true)
    elapsed = System.monotonic_time(:millisecond) - started

    ceiling_ms =
      @closed_port_budget_ms - @kill_confirm_reserve_ms + escalation_overhead_ms +
        @escalation_slack_ms

    assert elapsed <= ceiling_ms,
           "closed-Port unload spent #{elapsed}ms; one #{@closed_port_budget_ms}ms budget " <>
             "less its KILL-confirmation reserve allows #{ceiling_ms}ms " <>
             "(measured escalation overhead #{escalation_overhead_ms}ms)"

    assert {:ok, marker} = File.read(marker_path)
    assert marker =~ "term_ignored mode=resistant"
    CustodyTestHelpers.assert_os_pid_dead!(os_pid, 2_000)
    refute File.exists?(context.socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
  end

  test "SPEC.md §4.9 noisy TERM-resistant shutdown reaches bounded KILL", context do
    escalation_overhead_ms = measure_escalation_overhead!(context)
    marker_path = Path.join(context.root, "events.log")

    {port, os_pid} =
      CustodyTestHelpers.start_signal_child!(:chatty_resistant, marker_path)

    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(port, os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
    end)

    assert {:ok, os_identity} = WorkerProcessLifecycle.process_identity(os_pid)

    assert {:ok, reaper_ref} =
             RuntimeProcessReaper.watch(self(), os_pid, %{
               shutdown_timeout_ms: @shutdown_timeout_ms,
               model_ref: context.model_ref,
               os_identity: os_identity,
               phase: :loaded
             })

    File.write!(context.socket_path, "owned runtime artifact")

    state = %{
      backend: "stub",
      channel: nil,
      executable: Path.expand("../../support/custody-signal-child", __DIR__),
      generations: %{},
      model_ref: context.model_ref,
      os_identity: os_identity,
      os_pid: os_pid,
      port: port,
      reaper_ref: reaper_ref,
      shutdown_timeout_ms: @shutdown_timeout_ms,
      socket_path: context.socket_path
    }

    task =
      Task.async(fn ->
        receive do
          :unload -> WorkerRuntimeAdapter.unload_model(state, skip_rpc: true)
        end
      end)

    assert true = Port.connect(port, task.pid)
    send(task.pid, :unload)

    result =
      Task.yield(task, 2_000 + 2 * escalation_overhead_ms) || Task.shutdown(task, :brutal_kill)

    assert {:ok, :ok} = result

    assert CustodyTestHelpers.wait_until(
             fn ->
               case File.read(marker_path) do
                 {:ok, contents} -> String.contains?(contents, "term_ignored mode=resistant")
                 {:error, _reason} -> false
               end
             end,
             1_000
           )

    CustodyTestHelpers.assert_os_pid_dead!(os_pid, 2_000)
    refute File.exists?(context.socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    CustodyTestHelpers.assert_reaper_empty!(1_000)
  end

  test "SPEC.md §4.9 Application.stop reaps the exact runtime PID and socket", context do
    previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)
    stop_node_agent_app()

    runtime =
      Keyword.merge(previous_runtime,
        fake_runtime?: false,
        models_root: context.models_root,
        runtime_adapter_impl: WorkerRuntimeAdapter,
        worker_backend: "stub",
        worker_executable: worker_executable(),
        worker_log_dir: context.root,
        worker_shutdown_timeout_ms: @shutdown_timeout_ms,
        worker_socket_dir: context.root
      )

    Application.put_env(:orchard_node_agent, :runtime, runtime)

    on_exit(fn ->
      stop_node_agent_app()
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
      assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
    end)

    assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
    manager = start_supervised!({WorkerManagerStub, self()})
    assert {:ok, worker_pid} = WorkerSupervisor.start_worker(context.model_ref, manager: manager)

    assert :loaded =
             WorkerProcess.ensure_loaded(worker_pid, %EnsureModelLoadedRequest{},
               load_timeout_ms: 5_000
             )

    %{adapter_state: state} = :sys.get_state(worker_pid)
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn ->
      CustodyTestHelpers.stop_child(state.port, state.os_pid)
      CustodyTestHelpers.stop_child(control_port, control_pid)
    end)

    assert WorkerProcessLifecycle.os_process_alive?(state.os_pid)
    assert File.exists?(state.socket_path)
    log = capture_log(fn -> assert :ok = Application.stop(:orchard_node_agent) end)

    CustodyTestHelpers.assert_os_pid_dead!(state.os_pid, 2_000)
    refute File.exists?(state.socket_path)
    assert WorkerProcessLifecycle.os_process_alive?(control_pid)
    refute log =~ "orphan"
  end

  # Cost of one custody-gated escalation with no waiting left, so the closed-Port
  # budget assertion tracks this machine's process-spawn cost instead of assuming it.
  defp measure_escalation_overhead!(context) do
    marker_path = Path.join(context.root, "baseline-events.log")
    {port, os_pid} = CustodyTestHelpers.start_signal_child!(:resistant, marker_path)

    on_exit(fn -> CustodyTestHelpers.stop_child(port, os_pid) end)

    assert {:ok, identity} = WorkerProcessLifecycle.process_identity(os_pid)

    started = System.monotonic_time(:millisecond)

    assert :ok =
             WorkerProcessLifecycle.escalate_owned_exit(
               os_pid,
               identity,
               started,
               started + 2_000
             )

    System.monotonic_time(:millisecond) - started
  end

  defp load_stub_runtime!(context) do
    assert {:ok, state} = load_runtime(context, [])
    state
  end

  defp load_runtime(context, opts) do
    defaults = [
      backend: "stub",
      executable: worker_executable(),
      load_timeout_ms: 5_000,
      log_path: context.log_path,
      models_root: context.models_root,
      owner: self(),
      ready_timeout_ms: 5_000,
      shutdown_timeout_ms: @shutdown_timeout_ms,
      socket_path: context.socket_path
    ]

    WorkerRuntimeAdapter.load_model(context.model_ref, Keyword.merge(defaults, opts))
  end

  defp exited_port! do
    true_executable = System.find_executable("true") || "/usr/bin/true"
    port = Port.open({:spawn_executable, true_executable}, [:exit_status])

    assert_receive {^port, {:exit_status, _status}}, 2_000

    assert CustodyTestHelpers.wait_until(fn -> is_nil(Port.info(port)) end, 1_000),
           "expected the fixture port to close after its program exited"

    port
  end

  defp worker_executable do
    Path.expand("../../../../../native/orchard_worker_mlx/bin/orchard-worker-mlx", __DIR__)
  end

  defp stop_node_agent_app do
    case Application.stop(:orchard_node_agent) do
      :ok -> :ok
      {:error, {:not_started, :orchard_node_agent}} -> :ok
    end
  end
end
