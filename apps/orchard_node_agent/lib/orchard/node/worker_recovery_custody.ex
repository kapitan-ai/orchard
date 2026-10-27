defmodule Orchard.Node.WorkerRecoveryCustody do
  @moduledoc """
  Affirmative host-boot and runtime cleanup proofs for SPEC §12.2.

  `record_runtime_custody/2` records the evidence a later epoch needs to resolve
  prior ownership: the host boot identity, plus either affirmative exit proof or
  the runtime process whose exit is not proven yet. It never replaces a recorded
  runtime process or exit proof with bare boot evidence, so every ownership write
  keeps the strongest proof this Node Agent lifetime has observed.

  `resolve_prior_worker_ownership/2` replays that record, so a runtime process
  that outlives a Node Agent restart resolves once it exits — including when an
  operator kills it through host controls — instead of waiting for the host to
  reboot.

  A recorded runtime process carries an opaque digest of its launch identity
  snapshot (owner uid and start time). A live PID whose snapshot no longer
  matches belongs to another process, so the recorded incarnation is gone. A
  live PID without a recorded digest, or whose snapshot cannot be read, stays
  unresolved.
  """
  alias Orchard.Node.RuntimeProcessReaper
  alias Orchard.Node.WorkerProcessLifecycle

  @absent_boot "none"
  @exited "exited"

  @doc """
  Returns this host's boot identity.

  The value cannot change during this OS process, and the 1 Hz cleanup re-probe
  consults it for every unresolved placement, so a successful read is cached for
  the lifetime of the process. A failed read is not cached, leaving a transient
  failure retryable.
  """
  @spec boot_identity() :: String.t() | nil
  def boot_identity do
    case :persistent_term.get({__MODULE__, :boot_identity}, :absent) do
      :absent -> cache_boot_identity(read_boot_identity())
      cached -> cached
    end
  end

  defp cache_boot_identity(identity) when is_binary(identity) do
    :persistent_term.put({__MODULE__, :boot_identity}, identity)
    identity
  end

  defp cache_boot_identity(identity), do: identity

  defp read_boot_identity do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("/usr/sbin/sysctl", ["-n", "kern.bootsessionuuid"],
               stderr_to_stdout: true
             ) do
          {value, 0} -> normalize(value)
          _error -> nil
        end

      {:unix, :linux} ->
        case File.read("/proc/sys/kernel/random/boot_id") do
          {:ok, value} -> normalize(value)
          _error -> nil
        end

      _platform ->
        nil
    end
  end

  @doc """
  Records durable custody evidence for the runtime incarnation owned by `owner_pid`.

  `previous_custody` is retained when this reaper can no longer name a runtime
  process or prove its exit, because bare boot evidence cannot resolve prior
  ownership on an unchanged host boot.
  """
  @spec record_runtime_custody(String.t() | nil, pid() | nil) :: String.t() | nil
  def record_runtime_custody(previous_custody, owner_pid) do
    recorded = runtime_custody(owner_pid)

    cond do
      same_runtime_with_digest?(previous_custody, recorded) -> previous_custody
      provable?(recorded) or not provable?(previous_custody) -> recorded
      true -> previous_custody
    end
  end

  # Once the runtime's PID is reused its identity can no longer be confirmed, so a
  # later write must not drop the digest recorded while it could.
  defp same_runtime_with_digest?(previous, recorded) do
    previous = decode(previous)
    recorded = decode(recorded)

    is_binary(previous.digest) and is_nil(recorded.digest) and not recorded.exited? and
      not is_nil(recorded.os_pid) and
      {previous.boot, previous.os_pid} == {recorded.boot, recorded.os_pid}
  end

  defp runtime_custody(owner_pid) when is_pid(owner_pid),
    do: encode(boot_identity(), RuntimeProcessReaper.owner_custody(owner_pid))

  defp runtime_custody(_owner_pid), do: boot_identity()

  defp provable?(custody) do
    custody = decode(custody)
    custody.exited? or not is_nil(custody.os_pid)
  end

  @spec resolve_prior_worker_ownership(term(), String.t() | nil) :: :resolved | :unresolved
  def resolve_prior_worker_ownership(_key, previous_custody) do
    custody = decode(previous_custody)

    if custody.exited? or host_boot_ended?(custody.boot) or
         prior_runtime_exited?(custody.os_pid, custody.digest),
       do: :resolved,
       else: :unresolved
  end

  @spec resolve_current(pid()) :: :resolved | :unresolved
  def resolve_current(owner) do
    if RuntimeProcessReaper.ownership_resolved?(owner), do: :resolved, else: :unresolved
  end

  defp encode(boot, :unknown), do: boot
  defp encode(boot, :resolved), do: Enum.join([boot_segment(boot), @exited], "/")

  defp encode(boot, {:runtime_process, os_pid, os_identity}) do
    process =
      case recordable_launch_identity(os_pid, os_identity) do
        {:ok, launch_identity} -> "#{os_pid}.#{identity_digest(launch_identity)}"
        :error -> Integer.to_string(os_pid)
      end

    Enum.join([boot_segment(boot), process], "/")
  end

  # The reaper's snapshot proves the PID is still the launched runtime; only
  # then may the lifetime-stable identity read now stand for that runtime.
  defp recordable_launch_identity(os_pid, os_identity) do
    with {:ok, ^os_identity} <- WorkerProcessLifecycle.process_identity(os_pid),
         {:ok, launch_identity} <- WorkerProcessLifecycle.launch_identity(os_pid) do
      {:ok, launch_identity}
    else
      _unproven -> :error
    end
  end

  # The checkpoint holds custody as an opaque bounded token, so the identity
  # snapshot is recorded as a digest rather than as host process details. The
  # digest rides in the PID segment, so a reader that predates it still finds
  # the boot segment and resolves once the host reboots.
  defp identity_digest(os_identity) do
    :sha256
    |> :crypto.hash(os_identity)
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  defp boot_segment(nil), do: @absent_boot
  defp boot_segment(boot), do: boot

  defp decode(value) when is_binary(value) do
    case String.split(value, "/") do
      [boot] -> custody(normalize(boot), false, nil)
      [boot, @exited] -> custody(normalize(boot), true, nil)
      [boot, process] -> process_custody(normalize(boot), String.split(process, "."))
      _unrecognized -> custody(nil, false, nil)
    end
  end

  defp decode(_value), do: custody(nil, false, nil)

  defp process_custody(boot, [os_pid]), do: custody(boot, false, parse_os_pid(os_pid))

  defp process_custody(boot, [os_pid, digest]) when digest != "",
    do: custody(boot, false, parse_os_pid(os_pid), digest)

  defp process_custody(boot, _unrecognized), do: custody(boot, false, nil)

  defp custody(boot, exited?, os_pid, digest \\ nil),
    do: %{boot: boot, exited?: exited?, os_pid: os_pid, digest: digest}

  defp parse_os_pid(value) do
    case Integer.parse(value) do
      {os_pid, ""} when os_pid > 0 -> os_pid
      _unrecognized -> nil
    end
  end

  defp host_boot_ended?(nil), do: false

  defp host_boot_ended?(previous_boot) do
    current_boot = boot_identity()
    is_binary(current_boot) and current_boot != previous_boot
  end

  defp prior_runtime_exited?(nil, _digest), do: false

  defp prior_runtime_exited?(os_pid, digest) do
    WorkerProcessLifecycle.os_process_status(os_pid) == :not_alive or
      pid_reused?(os_pid, digest)
  end

  # A live PID whose identity snapshot differs from the recorded one belongs to
  # another process: a process never changes PID, so the recorded one is gone.
  defp pid_reused?(_os_pid, nil), do: false

  defp pid_reused?(os_pid, digest) do
    case WorkerProcessLifecycle.launch_identity(os_pid) do
      {:ok, identity} -> identity_digest(identity) != digest
      {:error, :identity_unavailable} -> false
    end
  end

  defp normalize(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, value),
      do: String.downcase(value),
      else: nil
  end
end
