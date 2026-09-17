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
  """
  alias Orchard.Node.RuntimeProcessReaper
  alias Orchard.Node.WorkerProcessLifecycle

  @absent_boot "none"
  @exited "exited"

  @spec boot_identity() :: String.t() | nil
  def boot_identity do
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

    if provable?(recorded) or not provable?(previous_custody),
      do: recorded,
      else: previous_custody
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
         prior_runtime_exited?(custody.os_pid),
       do: :resolved,
       else: :unresolved
  end

  @spec resolve_current(pid()) :: :resolved | :unresolved
  def resolve_current(owner) do
    if RuntimeProcessReaper.ownership_resolved?(owner), do: :resolved, else: :unresolved
  end

  defp encode(boot, :unknown), do: boot
  defp encode(boot, :resolved), do: Enum.join([boot_segment(boot), @exited], "/")

  defp encode(boot, {:runtime_process, os_pid}),
    do: Enum.join([boot_segment(boot), os_pid], "/")

  defp boot_segment(nil), do: @absent_boot
  defp boot_segment(boot), do: boot

  defp decode(value) when is_binary(value) do
    case String.split(value, "/") do
      [boot] -> custody(normalize(boot), false, nil)
      [boot, @exited] -> custody(normalize(boot), true, nil)
      [boot, os_pid] -> custody(normalize(boot), false, parse_os_pid(os_pid))
      _unrecognized -> custody(nil, false, nil)
    end
  end

  defp decode(_value), do: custody(nil, false, nil)

  defp custody(boot, exited?, os_pid), do: %{boot: boot, exited?: exited?, os_pid: os_pid}

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

  defp prior_runtime_exited?(nil), do: false

  defp prior_runtime_exited?(os_pid),
    do: WorkerProcessLifecycle.os_process_status(os_pid) == :not_alive

  defp normalize(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, value),
      do: String.downcase(value),
      else: nil
  end
end
