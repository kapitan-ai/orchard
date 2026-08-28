defmodule Orchard.Nodes.ExclusionSetTest do
  use ExUnit.Case, async: true

  alias Orchard.Nodes.ExclusionSet

  test "ADR 0019 canonicalizes valid Node UUID exclusions into a set" do
    node_id = Ecto.UUID.generate()

    assert {:ok, exclusions} =
             ExclusionSet.canonicalize([node_id, String.upcase(node_id)])

    assert exclusions == MapSet.new([node_id])
  end

  test "ADR 0019 preserves attempt-1 compatibility with an empty exclusion set" do
    assert ExclusionSet.canonicalize([]) == {:ok, MapSet.new()}
  end

  test "ADR 0019 fails closed for malformed Node UUID exclusions" do
    assert ExclusionSet.canonicalize(["not-a-uuid"]) == :error
    assert ExclusionSet.canonicalize(:not_a_list) == :error
  end
end
