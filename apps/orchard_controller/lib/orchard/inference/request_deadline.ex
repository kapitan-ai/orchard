defmodule Orchard.Inference.RequestDeadline do
  @moduledoc """
  Converts the persisted logical Request deadline into bounded stage budgets.
  """

  @spec timeout_at(pos_integer(), DateTime.t()) :: DateTime.t()
  def timeout_at(timeout_ms, %DateTime{} = now) when is_integer(timeout_ms) and timeout_ms > 0 do
    DateTime.add(now, timeout_ms, :millisecond)
  end

  @spec remaining_ms(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def remaining_ms(%DateTime{} = timeout_at, %DateTime{} = now) do
    max(DateTime.diff(timeout_at, now, :millisecond), 0)
  end

  @spec cap_ms(non_neg_integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def cap_ms(configured_ms, %DateTime{} = timeout_at, %DateTime{} = now)
      when is_integer(configured_ms) and configured_ms >= 0 do
    min(configured_ms, remaining_ms(timeout_at, now))
  end

  @spec to_monotonic_ms(DateTime.t(), integer(), integer()) :: integer()
  def to_monotonic_ms(%DateTime{} = timeout_at, system_ms, monotonic_ms)
      when is_integer(system_ms) and is_integer(monotonic_ms) do
    remaining_ms = max(DateTime.to_unix(timeout_at, :millisecond) - system_ms, 0)
    monotonic_ms + remaining_ms
  end
end
