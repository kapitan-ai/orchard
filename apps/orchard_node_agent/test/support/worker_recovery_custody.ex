defmodule Orchard.Node.TestWorkerRecoveryCustody do
  @moduledoc false

  @spec resolve_current(pid()) :: :resolved | :unresolved
  def resolve_current(pid), do: if(Process.alive?(pid), do: :unresolved, else: :resolved)

  @spec resolve_prior_worker_ownership(term(), term()) :: :unresolved
  def resolve_prior_worker_ownership(_key, _custody), do: :unresolved

  @spec record_runtime_custody(String.t() | nil, pid() | nil) :: String.t() | nil
  def record_runtime_custody(previous_custody, nil), do: previous_custody
  def record_runtime_custody(_previous_custody, owner_pid), do: inspect(owner_pid)
end
