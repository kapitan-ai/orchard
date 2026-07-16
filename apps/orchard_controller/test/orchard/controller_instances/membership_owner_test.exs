defmodule Orchard.ControllerInstances.MembershipOwnerTest do
  use Orchard.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Orchard.ControllerInstances
  alias Orchard.ControllerInstances.ControllerInstance
  alias Orchard.ControllerInstances.MembershipOwner
  alias Orchard.NodeTrust

  setup do
    previous_control_plane = Application.get_env(:orchard_controller, :control_plane)
    previous_ready = Application.get_env(:orchard_controller, :dispatch_capacity_consumers_ready)
    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)

    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-membership-owner-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    on_exit(fn ->
      File.rm_rf!(root)
      restore_env(:control_plane, previous_control_plane)
      restore_env(:dispatch_capacity_consumers_ready, previous_ready)
    end)

    {:ok, root: root}
  end

  test "SPEC.md §8.3 boot publishes one complete capability tuple for only its identity", %{
    root: root
  } do
    {opts, trust} = identity_opts(root)
    other = insert_other_instance!()
    observed_at = ~U[2026-07-16 01:02:03.000000Z]

    pid = start_supervised!({MembershipOwner, Keyword.put(opts, :clock, fn -> observed_at end)})
    assert is_pid(pid)
    await_timestamp(trust.controller_id, observed_at)

    local = Repo.get!(ControllerInstance, trust.controller_id)
    unchanged = Repo.get!(ControllerInstance, other.id)

    assert local.last_seen_at == observed_at
    assert local.software_version == to_string(Application.spec(:orchard_controller, :vsn))
    assert local.dispatch_capacity_contract_version == 1
    assert local.dispatch_capacity_consumers_ready == false
    assert local.dispatch_capacity_capability_observed_at == observed_at
    assert unchanged.last_seen_at == nil
    assert unchanged.dispatch_capacity_capability_observed_at == nil
  end

  test "SPEC.md §13.2 runtime configuration cannot promote foundation readiness", %{root: root} do
    {opts, trust} = identity_opts(root)
    Application.put_env(:orchard_controller, :dispatch_capacity_consumers_ready, true)

    start_supervised!({MembershipOwner, opts})
    await_capability(trust.controller_id)

    assert Repo.get!(ControllerInstance, trust.controller_id).dispatch_capacity_consumers_ready ==
             false
  end

  test "SPEC.md §8.3 incomplete capability write leaves membership freshness unchanged", %{
    root: root
  } do
    {opts, trust} = identity_opts(root)
    first = ~U[2026-07-16 01:02:03.000000Z]
    start_supervised!({MembershipOwner, Keyword.put(opts, :clock, fn -> first end)})
    await_timestamp(trust.controller_id, first)

    assert {:error, changeset} =
             ControllerInstances.heartbeat_local(opts, %{
               last_seen_at: ~U[2026-07-16 01:03:03.000000Z],
               software_version: "0.5.0-dev",
               dispatch_capacity_contract_version: 1,
               dispatch_capacity_consumers_ready: false
             })

    assert errors_on(changeset).dispatch_capacity_capability_observed_at == ["can't be blank"]
    assert Repo.get!(ControllerInstance, trust.controller_id).last_seen_at == first
  end

  test "SPEC.md §8.3 membership owner restarts under supervision and republishes", %{root: root} do
    {opts, trust} = identity_opts(root)
    agent = start_supervised!({Agent, fn -> ~U[2026-07-16 01:02:03.000000Z] end})
    clock = fn -> Agent.get(agent, & &1) end
    pid = start_supervised!({MembershipOwner, Keyword.put(opts, :clock, clock)})
    next = ~U[2026-07-16 01:04:03.000000Z]
    Agent.update(agent, fn _previous -> next end)

    Process.exit(pid, :kill)
    replacement = await_replacement(pid)

    assert is_pid(replacement)
    await_timestamp(trust.controller_id, next)
    assert Repo.get!(ControllerInstance, trust.controller_id).last_seen_at == next
  end

  test "SPEC.md §8.3 raised heartbeat failure retries without refreshing evidence", %{
    root: root
  } do
    {opts, trust} = identity_opts(root)
    first = ~U[2026-07-16 01:02:03.000000Z]
    next = ~U[2026-07-16 01:03:03.000000Z]
    calls = start_supervised!({Agent, fn -> 0 end}, id: :heartbeat_calls)
    clock = start_supervised!({Agent, fn -> first end}, id: :heartbeat_clock)

    publisher = fn publisher_opts, attrs ->
      case Agent.get_and_update(calls, fn count -> {count, count + 1} end) do
        1 -> raise DBConnection.ConnectionError, message: "transient heartbeat failure"
        _attempt -> ControllerInstances.heartbeat_local(publisher_opts, attrs)
      end
    end

    pid =
      start_supervised!(
        {MembershipOwner,
         opts
         |> Keyword.put(:clock, fn -> Agent.get(clock, & &1) end)
         |> Keyword.put(:publisher, publisher)}
      )

    await_timestamp(trust.controller_id, first)
    send(pid, :heartbeat)
    await_call_count(calls, 2)

    assert Process.alive?(pid)
    assert Repo.get!(ControllerInstance, trust.controller_id).last_seen_at == first

    Agent.update(clock, fn _previous -> next end)
    send(pid, :heartbeat)
    await_call_count(calls, 3)
    await_timestamp(trust.controller_id, next)

    refreshed = Repo.get!(ControllerInstance, trust.controller_id)
    assert refreshed.dispatch_capacity_capability_observed_at == next
    assert refreshed.dispatch_capacity_contract_version == 1
    assert refreshed.dispatch_capacity_consumers_ready == false
  end

  test "SPEC.md §8.3 caller cannot select another Controller identity", %{root: root} do
    {opts, trust} = identity_opts(root)
    other = insert_other_instance!()
    observed_at = ~U[2026-07-16 01:02:03.000000Z]

    assert {:ok, local} =
             ControllerInstances.heartbeat_local(opts, %{
               id: other.id,
               last_seen_at: observed_at,
               software_version: "0.5.0-dev",
               dispatch_capacity_contract_version: 1,
               dispatch_capacity_consumers_ready: true,
               dispatch_capacity_capability_observed_at: observed_at
             })

    assert local.id == trust.controller_id
    assert local.dispatch_capacity_consumers_ready == false
    assert Repo.get!(ControllerInstance, other.id).last_seen_at == nil
  end

  test "SPEC.md §8.3 Standby Controller publishes only its own membership", %{root: root} do
    {opts, trust} = identity_opts(root)
    Application.put_env(:orchard_controller, :control_plane, role: :standby)
    observed_at = ~U[2026-07-16 01:02:03.000000Z]

    start_supervised!({MembershipOwner, Keyword.put(opts, :clock, fn -> observed_at end)})

    await_timestamp(trust.controller_id, observed_at)
  end

  test "SPEC.md §8.3 heartbeat interval is exactly 10000 ms" do
    assert MembershipOwner.heartbeat_interval_ms() == 10_000
  end

  test "SPEC.md §8.3 a stuck heartbeat stays observable on a bounded log interval", %{root: root} do
    {opts, _trust} = identity_opts(root)
    clock = start_supervised!({Agent, fn -> ~U[2026-07-16 01:00:00.000000Z] end}, id: :clock)

    opts =
      opts
      |> Keyword.put(:clock, fn -> Agent.get(clock, & &1) end)
      |> Keyword.put(:publisher, fail_after_boot(&raise_unavailable_database/2))

    pid = start_supervised!({MembershipOwner, opts})

    assert beat(pid, 1) =~ "reason=heartbeat_publish_failed suppressed_attempts=0"

    assert beat(pid, 2) == ""

    Agent.update(clock, &DateTime.add(&1, 300, :second))

    assert beat(pid, 1) =~ "reason=heartbeat_publish_failed suppressed_attempts=2"
  end

  test "SPEC.md §8.3 boot fails closed when the first capability publication cannot be proven", %{
    root: root
  } do
    {opts, trust} = identity_opts(root)

    opts =
      Keyword.put(opts, :publisher, fn _opts, _attrs ->
        {:error, :beam_controller_instance_configuration_invalid}
      end)

    Process.flag(:trap_exit, true)

    assert {:error, :beam_controller_instance_configuration_invalid} =
             MembershipOwner.start_link(opts)

    assert Repo.get(ControllerInstance, trust.controller_id) == nil
  end

  test "SPEC.md §8.3 a changed failure reason is logged without waiting for the interval", %{
    root: root
  } do
    {opts, _trust} = identity_opts(root)
    kind = start_supervised!({Agent, fn -> :connection end}, id: :why)

    publisher = fn _opts, _attrs ->
      case Agent.get(kind, & &1) do
        :connection -> raise DBConnection.ConnectionError, message: "connection not available"
        :checkout -> exit({:timeout, {DBConnection.Holder, :checkout, [:pool, []]}})
      end
    end

    opts =
      opts
      |> Keyword.put(:clock, fn -> ~U[2026-07-16 01:00:00.000000Z] end)
      |> Keyword.put(:publisher, fail_after_boot(publisher))

    pid = start_supervised!({MembershipOwner, opts})
    assert beat(pid, 1) =~ "reason=heartbeat_publish_failed suppressed_attempts=0"

    Agent.update(kind, fn _previous -> :checkout end)

    assert beat(pid, 1) =~ "reason=heartbeat_publish_exit suppressed_attempts=0"
  end

  test "SPEC.md §8.3 transient heartbeat failure reasons are sanitized to stable codes", %{
    root: root
  } do
    {opts, _trust} = identity_opts(root)

    opts =
      opts
      |> Keyword.put(:clock, fn -> ~U[2026-07-16 01:00:00.000000Z] end)
      |> Keyword.put(:publisher, fail_after_boot(&raise_unavailable_database/2))

    pid = start_supervised!({MembershipOwner, opts})
    log = beat(pid, 1)

    assert log =~ "reason=heartbeat_publish_failed suppressed_attempts=0"
    refute log =~ "hunter2"
  end

  test "SPEC.md §8.3 an unavailable database defers the first publication instead of failing boot",
       %{root: root} do
    {opts, trust} = identity_opts(root)
    observed_at = ~U[2026-07-16 01:02:03.000000Z]
    down = start_supervised!({Agent, fn -> true end}, id: :down)

    publisher = fn publisher_opts, attrs ->
      if Agent.get(down, & &1) do
        raise_unavailable_database(publisher_opts, attrs)
      else
        ControllerInstances.heartbeat_local(publisher_opts, attrs)
      end
    end

    opts =
      opts
      |> Keyword.put(:clock, fn -> observed_at end)
      |> Keyword.put(:publisher, publisher)

    log = capture_log(fn -> start_supervised!({MembershipOwner, opts}) end)
    pid = Process.whereis(MembershipOwner)

    assert is_pid(pid)
    assert log =~ "reason=heartbeat_publish_failed suppressed_attempts=0"
    assert Repo.get(ControllerInstance, trust.controller_id) == nil

    Agent.update(down, fn _previous -> false end)
    beat(pid, 1)

    await_timestamp(trust.controller_id, observed_at)
    published = Repo.get!(ControllerInstance, trust.controller_id)

    assert published.dispatch_capacity_capability_observed_at == observed_at
    assert published.dispatch_capacity_consumers_ready == false
  end

  test "SPEC.md §8.3 the deferred first publication schedules the fixed heartbeat retry", %{
    root: root
  } do
    {opts, _trust} = identity_opts(root)

    opts =
      opts
      |> Keyword.put(:clock, fn -> ~U[2026-07-16 01:02:03.000000Z] end)
      |> Keyword.put(:publisher, &raise_unavailable_database/2)

    capture_log(fn -> start_supervised!({MembershipOwner, opts}) end)
    state = :sys.get_state(Process.whereis(MembershipOwner))

    assert state.timer_ref != nil
    assert state.failure.reason == :heartbeat_publish_failed
    assert MembershipOwner.heartbeat_interval_ms() == 10_000
  end

  test "SPEC.md §8.3 a database fault that is not an availability fault fails closed", %{
    root: root
  } do
    for publisher <- [
          fn _opts, _attrs -> raise_sqlstate("42P01", "relation does not exist") end,
          fn _opts, _attrs -> raise_sqlstate("28P01", "password authentication failed") end,
          fn _opts, _attrs ->
            raise Ecto.QueryError,
              message: "bad query",
              query: from(i in ControllerInstance, select: i)
          end,
          fn _opts, _attrs -> raise RuntimeError, message: "unexpected publication fault" end,
          fn _opts, _attrs -> exit(:shutdown) end
        ] do
      {opts, trust} = identity_opts(root)
      opts = Keyword.put(opts, :publisher, publisher)

      Process.flag(:trap_exit, true)

      assert {:error, reason} = MembershipOwner.start_link(opts)
      assert reason in [:heartbeat_publish_failed, :heartbeat_publish_exit]
      assert Repo.get(ControllerInstance, trust.controller_id) == nil
    end
  end

  test "SPEC.md §8.3 a fatal failure after boot stops the owner rather than retrying", %{
    root: root
  } do
    {opts, trust} = identity_opts(root)
    observed_at = ~U[2026-07-16 01:02:03.000000Z]

    opts =
      opts
      |> Keyword.put(:clock, fn -> observed_at end)
      |> Keyword.put(
        :publisher,
        fail_after_boot(fn _opts, _attrs ->
          {:error, :beam_controller_instance_mismatch}
        end)
      )

    pid = start_supervised!({MembershipOwner, opts})
    await_timestamp(trust.controller_id, observed_at)

    Process.flag(:trap_exit, true)
    ref = Process.monitor(pid)
    send(pid, :heartbeat)

    assert_receive {:DOWN, ^ref, :process, ^pid, :beam_controller_instance_mismatch}, 1_000
  end

  test "SPEC.md §8.3 recovery after a failure is announced once", %{root: root} do
    {opts, trust} = identity_opts(root)
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    failing = start_supervised!({Agent, fn -> false end}, id: :failing)
    observed_at = ~U[2026-07-16 01:02:03.000000Z]

    publisher = fn publisher_opts, attrs ->
      if Agent.get(failing, & &1) do
        raise_unavailable_database(publisher_opts, attrs)
      else
        ControllerInstances.heartbeat_local(publisher_opts, attrs)
      end
    end

    opts =
      opts
      |> Keyword.put(:clock, fn -> observed_at end)
      |> Keyword.put(:publisher, publisher)

    pid = start_supervised!({MembershipOwner, opts})
    Agent.update(failing, fn _previous -> true end)
    assert beat(pid, 1) =~ "reason=heartbeat_publish_failed"
    Agent.update(failing, fn _previous -> false end)

    assert beat(pid, 1) =~
             "recovered; capability evidence is fresh " <>
               "(previous_reason=heartbeat_publish_failed)"

    assert Repo.get!(ControllerInstance, trust.controller_id).last_seen_at == observed_at
    assert beat(pid, 1) == ""
  end

  defp raise_unavailable_database(_opts, _attrs) do
    raise_sqlstate("57P01", "terminating connection due to administrator command hunter2")
  end

  defp raise_sqlstate(sqlstate, message) do
    raise Postgrex.Error,
      postgres: %{code: sqlstate, severity: "FATAL", message: message}
  end

  defp fail_after_boot(fun) do
    booted = start_supervised!({Agent, fn -> false end}, id: {:booted, make_ref()})
    fn opts, attrs -> publish_after_boot(booted, fun, opts, attrs) end
  end

  defp publish_after_boot(booted, fun, opts, attrs) do
    if Agent.get_and_update(booted, fn booted -> {booted, true} end) do
      fun.(opts, attrs)
    else
      ControllerInstances.heartbeat_local(opts, attrs)
    end
  end

  defp beat(pid, count) do
    capture_log(fn ->
      Enum.each(1..count, fn _attempt ->
        send(pid, :heartbeat)
        :sys.get_state(pid)
      end)
    end)
  end

  defp identity_opts(root) do
    trust_root = Path.join(root, "node-trust")
    authorization_root = Path.join(root, "beam-authorization-root")
    now = ~U[2026-07-16 01:00:00.000000Z]
    {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    opts = [
      private_ipv4: "10.0.0.10",
      membership_scope: :remote_beam,
      node_trust_root: trust_root,
      authorization_root_path: authorization_root,
      now: now
    ]

    {opts, trust}
  end

  defp insert_other_instance! do
    now = ~U[2026-07-16 01:00:00.000000Z]

    %ControllerInstance{}
    |> ControllerInstance.changeset(%{
      id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      certificate_uri_san: "urn:orchard:controller:eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      certificate_identifier: "serial:999",
      certificate_fingerprint_sha256: String.duplicate("e", 64),
      canonical_beam_name: "orchard_controller_eeeeeeeeeeee4eee8eeeeeeeeeeeeeee@10.0.0.11",
      beam_authorization_root_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
      authorization_root_custody_ref: "owner-only-local:ffffffff-ffff-4fff-8fff-ffffffffffff",
      status: :retired,
      first_enrolled_at: now
    })
    |> Repo.insert!()
  end

  defp await_replacement(previous, attempts \\ 100)
  defp await_replacement(_previous, 0), do: nil

  defp await_replacement(previous, attempts) do
    case Process.whereis(MembershipOwner) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _other ->
        Process.sleep(10)
        await_replacement(previous, attempts - 1)
    end
  end

  defp await_timestamp(instance_id, expected, attempts \\ 100)
  defp await_timestamp(_instance_id, _expected, 0), do: flunk("heartbeat was not persisted")

  defp await_timestamp(instance_id, expected, attempts) do
    case Repo.get(ControllerInstance, instance_id) do
      %ControllerInstance{last_seen_at: ^expected} ->
        :ok

      _other ->
        Process.sleep(10)
        await_timestamp(instance_id, expected, attempts - 1)
    end
  end

  defp await_capability(instance_id, attempts \\ 100)
  defp await_capability(_instance_id, 0), do: flunk("capability was not persisted")

  defp await_capability(instance_id, attempts) do
    case Repo.get(ControllerInstance, instance_id) do
      %ControllerInstance{dispatch_capacity_consumers_ready: false} ->
        :ok

      _other ->
        Process.sleep(10)
        await_capability(instance_id, attempts - 1)
    end
  end

  defp await_call_count(agent, expected, attempts \\ 100)
  defp await_call_count(_agent, _expected, 0), do: flunk("heartbeat was not attempted")

  defp await_call_count(agent, expected, attempts) do
    if Agent.get(agent, &(&1 >= expected)) do
      :ok
    else
      Process.sleep(10)
      await_call_count(agent, expected, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:orchard_controller, key)
  defp restore_env(key, value), do: Application.put_env(:orchard_controller, key, value)
end
