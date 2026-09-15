defmodule Orchard.Node.WorkerRecoveryCustody do
  @moduledoc "Affirmative host-boot and current runtime cleanup proofs for SPEC §12.2."
  alias Orchard.Node.RuntimeProcessReaper

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

  @spec resolve_prior_worker_ownership(term(), String.t() | nil) :: :resolved | :unresolved
  def resolve_prior_worker_ownership(_key, previous_boot) do
    current_boot = boot_identity()
    previous_boot = if is_binary(previous_boot), do: normalize(previous_boot)

    if is_binary(previous_boot) and is_binary(current_boot) and previous_boot != current_boot,
      do: :resolved,
      else: :unresolved
  end

  @spec resolve_current(pid()) :: :resolved | :unresolved
  def resolve_current(owner) do
    if RuntimeProcessReaper.ownership_resolved?(owner), do: :resolved, else: :unresolved
  end

  defp normalize(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, value),
      do: String.downcase(value),
      else: nil
  end
end
