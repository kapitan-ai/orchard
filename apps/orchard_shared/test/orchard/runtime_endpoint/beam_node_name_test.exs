defmodule Orchard.RuntimeEndpoint.BeamNodeNameTest do
  use ExUnit.Case, async: true

  alias Orchard.RuntimeEndpoint.BeamNodeName

  test "SPEC.md §7.5.0 rejects abbreviated IPv4 in a canonical peer name" do
    node_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    compact_id = String.replace(node_id, "-", "")

    assert {:error, :invalid_beam_node_name} =
             BeamNodeName.validate(
               "orchard_node_agent_#{compact_id}@10.1",
               "orchard_node_agent_",
               node_id
             )
  end
end
