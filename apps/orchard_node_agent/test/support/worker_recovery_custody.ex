defmodule Orchard.Node.TestWorkerRecoveryCustody do
  @moduledoc false

  @spec resolve_current(pid()) :: :resolved | :unresolved
  def resolve_current(pid), do: if(Process.alive?(pid), do: :unresolved, else: :resolved)

  @spec resolve_prior_worker_ownership(term(), term()) :: :unresolved
  def resolve_prior_worker_ownership(_key, _custody), do: :unresolved
end
