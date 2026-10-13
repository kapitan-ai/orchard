defmodule Orchard.RuntimeEndpoint.ReconnectBackoff do
  @moduledoc """
  Equal-jitter reconnect timing for private-network BEAM peers.

  Reset requires both exact current-generation authentication and a fresh
  accepted observation; transport connection alone is insufficient.
  """

  @initial_ceiling_ms 250
  @maximum_ceiling_ms 30_000

  @type t :: %__MODULE__{
          blocked?: boolean(),
          ceiling_ms: pos_integer(),
          next_attempt_at_ms: integer()
        }

  defstruct blocked?: false,
            ceiling_ms: @initial_ceiling_ms,
            next_attempt_at_ms: 0

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new(integer()) :: t()
  def new(now_ms) when is_integer(now_ms), do: %__MODULE__{next_attempt_at_ms: now_ms}

  @spec next(t(), (pos_integer() -> non_neg_integer())) ::
          {non_neg_integer(), t()}
  def next(%__MODULE__{ceiling_ms: ceiling} = backoff, random_integer \\ &:rand.uniform/1)
      when is_function(random_integer, 1) do
    floor = div(ceiling, 2)
    width = ceiling - floor
    delay = floor + random_integer.(width) - 1
    next_ceiling = min(ceiling * 2, @maximum_ceiling_ms)
    {delay, %{backoff | ceiling_ms: next_ceiling}}
  end

  @spec due?(t(), integer()) :: boolean()
  def due?(%__MODULE__{blocked?: false, next_attempt_at_ms: deadline}, now_ms)
      when is_integer(now_ms),
      do: now_ms >= deadline

  def due?(%__MODULE__{}, _now_ms), do: false

  @spec failed(t(), integer(), (pos_integer() -> non_neg_integer())) ::
          {non_neg_integer(), t()}
  def failed(%__MODULE__{} = state, now_ms, random_offset \\ &random_offset/1)
      when is_integer(now_ms) and is_function(random_offset, 1) do
    width = state.ceiling_ms - div(state.ceiling_ms, 2)
    offset = random_offset.(width)
    true = is_integer(offset) and offset in 0..(width - 1)
    {delay, state} = next(state, fn ^width -> offset + 1 end)
    {delay, %{state | blocked?: false, next_attempt_at_ms: now_ms + delay}}
  end

  @spec authority_lost(t()) :: t()
  def authority_lost(%__MODULE__{} = state), do: %{state | blocked?: true}

  @spec authority_recovered(t(), integer()) :: t()
  def authority_recovered(%__MODULE__{}, now_ms) when is_integer(now_ms), do: new(now_ms)

  @spec reset(t(), map()) :: t()
  def reset(backoff, evidence) when is_map(evidence) do
    if value(evidence, :current_generation_authenticated) == true and
         value(evidence, :fresh_observation_accepted) == true do
      new()
    else
      backoff
    end
  end

  defp random_offset(width), do: :rand.uniform(width) - 1
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
