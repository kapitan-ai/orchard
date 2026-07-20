defmodule Orchard.DispatchCapacity.Readiness do
  @moduledoc """
  Verifies the running build's exact five-consumer capacity contract.

  Readiness is derived from an immutable consumer manifest, exact contract
  version declarations, and the deterministic shared public-interface fixture.
  """

  require Logger

  alias Orchard.Dispatch.RequestDispatcher
  alias Orchard.DispatchCapacity.{AllocationAuthority, ConformanceFixture, Evaluator}
  alias Orchard.Inference.QueueManager
  alias Orchard.Nodes
  alias Orchard.Scheduler.{MultiNode, SingleNode}

  @readiness_cache_key {__MODULE__, :default_readiness}
  @contract_version 1
  @consumer_manifest [
    {MultiNode, :multi_node_eligibility_and_lane},
    {SingleNode, :single_node_authorization},
    {Nodes, :node_queue_source_refresh},
    {QueueManager, :aggregate_allocation_authority},
    {RequestDispatcher, :final_dispatch_revalidation}
  ]

  @doc "Returns the dispatch-capacity contract version implemented by this build."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc "Returns the exact five-consumer wiring manifest."
  @spec consumer_manifest() :: [{module(), atom()}]
  def consumer_manifest, do: @consumer_manifest

  @doc """
  Verifies exact consumer wiring, version compatibility, and fixture conformance.

  The default proof depends only on compiled modules and a frozen fixture, so
  a successful outcome is constant for a build and is cached. A failed proof is
  never cached: it can fail for transient runtime reasons, and a conformant
  build must not advertise itself as unready until the BEAM restarts. Callers
  that override any input get an uncached proof.
  """
  @spec ready?(keyword()) :: boolean()
  def ready?(opts \\ [])

  def ready?([]), do: cached_default_readiness()

  def ready?(opts) do
    manifest = Keyword.get(opts, :consumer_manifest, @consumer_manifest)
    required_version = Keyword.get(opts, :required_contract_version, @contract_version)
    fixture_input = Keyword.get_lazy(opts, :fixture_input, &ConformanceFixture.input/0)

    manifest == @consumer_manifest and required_version == @contract_version and
      fixture_input == ConformanceFixture.input() and
      fixture_conforms?(manifest, fixture_input)
  rescue
    error ->
      Logger.warning("Dispatch-capacity readiness proof raised: #{inspect(error)}")
      false
  catch
    kind, reason ->
      Logger.warning("Dispatch-capacity readiness proof #{kind}: #{inspect(reason)}")
      false
  end

  defp cached_default_readiness do
    if :persistent_term.get(@readiness_cache_key, false) do
      true
    else
      compute_default_readiness()
    end
  end

  defp compute_default_readiness do
    if ready?(consumer_manifest: @consumer_manifest) do
      :persistent_term.put(@readiness_cache_key, true)
      true
    else
      false
    end
  end

  defp fixture_conforms?(manifest, %Evaluator.Input{} = input) do
    node_id = "00000000-0000-0000-0000-000000000001"
    {:ok, authority} = AllocationAuthority.start_link(name: nil)

    try do
      expected = AllocationAuthority.evaluate(authority, node_id, input)

      consumers_conform?(manifest, authority, node_id, input, expected) and
        revalidation_conforms?(authority, node_id, input, expected)
    after
      GenServer.stop(authority)
    end
  end

  defp fixture_conforms?(_manifest, _invalid_input), do: false

  defp consumers_conform?(manifest, authority, node_id, input, expected) do
    Enum.all?(manifest, fn {consumer, wiring} ->
      Code.ensure_loaded?(consumer) and
        function_exported?(consumer, :dispatch_capacity_contract_version, 0) and
        function_exported?(consumer, :dispatch_capacity_wiring, 0) and
        function_exported?(consumer, :evaluate_dispatch_capacity, 3) and
        consumer.dispatch_capacity_contract_version() == @contract_version and
        consumer.dispatch_capacity_wiring() == wiring and
        consumer.evaluate_dispatch_capacity(authority, node_id, input) == expected
    end)
  end

  defp revalidation_conforms?(authority, node_id, input, expected) do
    case QueueManager.acquire_dispatch_capacity(
           node_id,
           "dispatch-capacity-readiness-fixture",
           input,
           authority: authority
         ) do
      {:ok, claim, _result} ->
        try do
          RequestDispatcher.revalidate_dispatch_capacity(claim, input, authority: authority) ==
            {:ok, expected}
        after
          QueueManager.release_dispatch_capacity(claim, authority: authority)
        end

      _unavailable ->
        false
    end
  end
end
