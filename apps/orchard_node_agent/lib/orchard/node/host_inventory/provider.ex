defmodule Orchard.Node.HostInventory.Provider do
  @moduledoc """
  Capability-provider contract for observation-only host inventory
  (`SPEC.md` §4.9).

  A provider is a platform adapter selected only by explicit configuration, so
  the portable Node Agent holds no operating-system or vendor branch. Providers
  return bounded evidence and never bind devices, start runtimes, or create
  capacity.
  """

  alias Orchard.Cluster.V1.HostInventoryObservation

  @doc "Collects one bounded observation-only inventory envelope."
  @callback observe(keyword()) :: HostInventoryObservation.t()

  @doc "Builds an envelope whose every section reports the bounded error code."
  @callback error_observation(now_ms :: non_neg_integer(), error_code :: String.t()) ::
              HostInventoryObservation.t()
end
