defmodule Orchard.Inference.AttemptContextTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.AttemptContext

  @node_id "00000000-0000-4000-a000-000000000001"

  test "SPEC.md §3.7.1 supports only turn 1 attempts 1 and 2" do
    assert {:ok, attempt_1} = AttemptContext.new(attrs(1, []))
    assert attempt_1.step_id == "inference_turn:t1:a1"

    assert {:ok, attempt_2} = AttemptContext.new(attrs(2, [@node_id]))
    assert attempt_2.step_id == "inference_turn:t1:a2"

    assert {:error, _reason} = AttemptContext.new(Map.put(attrs(1, []), :turn_index, 2))
    assert {:error, _reason} = AttemptContext.new(attrs(3, []))
  end

  test "attempt exclusion invariants fail closed" do
    assert {:error, _reason} = AttemptContext.new(attrs(1, [@node_id]))
    assert {:error, _reason} = AttemptContext.new(attrs(2, []))
    assert {:error, _reason} = AttemptContext.new(attrs(2, ["not-a-uuid"]))
    assert {:error, _reason} = AttemptContext.new(attrs(2, [@node_id, Ecto.UUID.generate()]))
  end

  test "started_at can be assigned exactly once" do
    assert {:ok, context} = AttemptContext.new(attrs(1, []))
    started_at = ~U[2026-08-12 10:00:00.000000Z]

    assert {:ok, started} = AttemptContext.put_started_at(context, started_at)
    assert started.started_at == started_at

    assert {:error, "started_at is immutable once assigned"} =
             AttemptContext.put_started_at(started, DateTime.add(started_at, 1, :second))
  end

  defp attrs(attempt, exclusions) do
    %{
      turn_index: 1,
      attempt: attempt,
      excluded_node_ids: exclusions,
      model_id: "model-a",
      model_version: "v1"
    }
  end
end
