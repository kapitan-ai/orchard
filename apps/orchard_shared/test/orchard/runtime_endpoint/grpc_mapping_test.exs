defmodule Orchard.RuntimeEndpoint.GrpcMappingTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.GenerationParams
  alias Orchard.RuntimeEndpoint.GrpcMapping

  describe "generation_params_to_proto/1 stop_sequences" do
    test "keeps a list of stop sequences" do
      proto = GrpcMapping.generation_params_to_proto(%{stop_sequences: ["STOP", "END"]})

      assert proto.stop_sequences == ["STOP", "END"]
    end

    test "wraps a scalar stop sequence in a single-element list" do
      proto = GrpcMapping.generation_params_to_proto(%{stop_sequences: "STOP"})

      assert proto.stop_sequences == ["STOP"]
    end

    test "maps a nil stop sequence to an empty list" do
      proto = GrpcMapping.generation_params_to_proto(%{stop_sequences: nil})

      assert proto.stop_sequences == []
    end

    test "maps a missing stop sequence key to an empty list" do
      proto = GrpcMapping.generation_params_to_proto(%{})

      assert %GenerationParams{stop_sequences: []} = proto
    end
  end
end
