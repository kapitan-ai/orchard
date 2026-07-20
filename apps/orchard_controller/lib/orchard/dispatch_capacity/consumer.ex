defmodule Orchard.DispatchCapacity.Consumer do
  @moduledoc """
  Declares one module as a shared dispatch-capacity authorization consumer.

  Every consumer in `Orchard.DispatchCapacity.Readiness`'s manifest declares the
  same evaluation seam, the same contract version, and its own wiring identity
  through this module, so the manifest and the per-consumer declarations cannot
  drift apart.
  """

  alias Orchard.DispatchCapacity.Evaluator

  @contract_version 1

  @doc "Returns the dispatch-capacity conformance contract version this build implements."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc "Returns whether one shared evaluation authorizes a dispatch unit right now."
  @spec authorized?(term()) :: boolean()
  def authorized?(%Evaluator.Result{eligible?: true, available_slots: slots}) when slots > 0,
    do: true

  def authorized?(_result), do: false

  @doc "Normalizes one consumer-supplied capacity input seam result."
  @spec normalize_input(term()) ::
          {:ok, Evaluator.Input.t()} | {:error, :dispatch_capacity_facts_unavailable}
  def normalize_input({:ok, %Evaluator.Input{}} = result), do: result
  def normalize_input(%Evaluator.Input{} = input), do: {:ok, input}
  def normalize_input(_invalid), do: {:error, :dispatch_capacity_facts_unavailable}

  @doc "Copies an explicitly configured authority seam onto one schedule map."
  @spec put_authority(map(), keyword()) :: map()
  def put_authority(schedule, opts) when is_map(schedule) and is_list(opts) do
    case Keyword.fetch(opts, :dispatch_capacity_authority) do
      {:ok, authority} -> Map.put(schedule, :dispatch_capacity_authority, authority)
      :error -> schedule
    end
  end

  @doc """
  Declares the calling module one of the five shared capacity consumers.

  `:wiring` must be that module's atom in `Orchard.DispatchCapacity.Readiness`'s
  manifest. The injected `evaluate_dispatch_capacity/3`,
  `dispatch_capacity_contract_version/0`, and `dispatch_capacity_wiring/0` are
  what the readiness proof reads, so a consumer cannot claim readiness without
  the shared evaluation seam.
  """
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
