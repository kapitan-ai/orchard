defmodule Orchard.RuntimeEndpoint.GrpcMappingTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedResponse,
    GenerationParams,
    ModelRef,
    RuntimeModelPlacement
  }

  alias Orchard.RuntimeEndpoint.{GrpcMapping, PlacementCapacity}

  describe "ensure_model_loaded_result_from_response/1" do
    test "normalizes valid additive placement capacity" do
      response = %EnsureModelLoadedResponse{
        placement_state: :PLACEMENT_STATE_LOADED,
        placement_capacity: %RuntimeModelPlacement{
          model_ref: %ModelRef{model_id: "test/model", version: "v1"},
          active_request_count: 0,
          max_concurrency: 2
        }
      }

      result = GrpcMapping.ensure_model_loaded_result_from_response(response)

      assert result.placement_capacity_evidence_state == :valid

      assert %PlacementCapacity{
               status: :known,
               model_ref: %{model_id: "test/model", version: "v1"},
               active_request_count: 0,
               max_concurrency: 2,
               source: :ensure_model_loaded_result
             } = result.placement_capacity
    end

    test "does not map placement authority from a failed or non-loaded result" do
      placement = %RuntimeModelPlacement{
        model_ref: %ModelRef{model_id: "test/model", version: "v1"},
        active_request_count: 0,
        max_concurrency: 2
      }

      for placement_state <- [
            :PLACEMENT_STATE_FAILED,
            :PLACEMENT_STATE_LOADING,
            :PLACEMENT_STATE_UNSPECIFIED
          ] do
        result =
          GrpcMapping.ensure_model_loaded_result_from_response(%EnsureModelLoadedResponse{
            placement_state: placement_state,
            placement_capacity: placement
          })

        assert result.placement_capacity == nil
        assert result.placement_capacity_evidence_state == :invalid
      end
    end

    test "distinguishes absent placement evidence from present invalid evidence" do
      absent_result =
        GrpcMapping.ensure_model_loaded_result_from_response(%EnsureModelLoadedResponse{
          placement_state: :PLACEMENT_STATE_LOADED
        })

      assert absent_result.placement_capacity == nil
      assert absent_result.placement_capacity_evidence_state == :absent

      for placement <- [
            %RuntimeModelPlacement{
              model_ref: %ModelRef{model_id: "test/model", version: "v1"},
              active_request_count: 0,
              max_concurrency: 0
            },
            %{
              model_ref: %{model_id: "", version: "v1"},
              active_request_count: 0,
              max_concurrency: 2
            },
            %{
              model_ref: %{model_id: "test/model", version: "v1"},
              active_request_count: -1,
              max_concurrency: 2
            },
            :malformed
          ] do
        response =
          %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED}
          |> Map.put(:placement_capacity, placement)

        result = GrpcMapping.ensure_model_loaded_result_from_response(response)

        assert result.placement_capacity == nil
        assert result.placement_capacity_evidence_state == :invalid
      end
    end
  end

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
