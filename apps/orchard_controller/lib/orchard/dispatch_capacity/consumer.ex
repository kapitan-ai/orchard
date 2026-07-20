defmodule Orchard.DispatchCapacity.Consumer do
  @moduledoc """
  Declares one module as a shared dispatch-capacity authorization consumer.

  Every consumer in `Orchard.DispatchCapacity.Readiness`'s manifest declares the
  same evaluation seam, the same contract version, and its own wiring identity
  through this module, so the manifest and the per-consumer declarations cannot
  drift apart.
  """

  @contract_version 1

  @doc "Returns the dispatch-capacity conformance contract version this build implements."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  defmacro __using__(opts) do
    wiring = Keyword.fetch!(opts, :wiring)

    unless is_atom(wiring) do
      raise ArgumentError,
            "dispatch-capacity consumer wiring must be an atom, got: #{inspect(wiring)}"
    end

    quote do
      alias Orchard.DispatchCapacity.{AllocationAuthority, Consumer, Evaluator}

      @doc "Returns this consumer's shared dispatch-capacity evaluation."
      @spec evaluate_dispatch_capacity(
              GenServer.server(),
              Ecto.UUID.t() | nil,
              Evaluator.Input.t()
            ) ::
              Evaluator.Result.t()
      def evaluate_dispatch_capacity(authority, node_id, input),
        do: AllocationAuthority.evaluate(authority, node_id, input)

      @doc "Returns the dispatch-capacity conformance contract version used by this consumer."
      @spec dispatch_capacity_contract_version() :: pos_integer()
      def dispatch_capacity_contract_version, do: Consumer.contract_version()

      @doc "Identifies this consumer's dispatch-capacity wiring."
      @spec dispatch_capacity_wiring() :: atom()
      def dispatch_capacity_wiring, do: unquote(wiring)
    end
  end
end
