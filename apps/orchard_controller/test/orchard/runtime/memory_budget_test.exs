defmodule Orchard.Runtime.MemoryBudgetTest do
  use ExUnit.Case, async: true

  alias Orchard.Runtime.MemoryBudget

  describe "normalize_for_scheduler/1" do
    test "SPEC 7.5.3 maps only ok with headroom_available true to headroom_ok" do
      normalized =
        MemoryBudget.normalize_for_scheduler(%{
          model_ref: %{model_id: "mlx", version: "v1"},
          mode: "observe",
          budget_available: true,
          headroom_available: true,
          status_code: "ok",
          target_working_set_bytes: 10,
          resident_memory_bytes: 4,
          estimated_headroom_bytes: 6,
          kv_cache_bytes_per_token: 1,
          prefill_workspace_bytes_per_token: 2
        })

      assert normalized.admission_tier == :headroom_ok
      assert normalized.model_ref == "mlx@v1"
      assert normalized.status_code == "ok"
      assert normalized.target_working_set_bytes == 10
    end

    test "SPEC 7.5.3 treats absent telemetry as headroom_unknown" do
      assert MemoryBudget.normalize(nil) == nil
      assert MemoryBudget.normalize_for_scheduler(nil).admission_tier == :headroom_unknown
      assert MemoryBudget.selected_fields(nil) == %{}
    end

    test "SPEC 7.5.3 classifies unavailable headroom without applying a penalty" do
      normalized =
        MemoryBudget.normalize_for_scheduler(%{
          "model_ref" => %{"model_id" => "mlx", "version" => "v1"},
          "mode" => "observe",
          "budget_available" => true,
          "headroom_available" => false,
          "status_code" => "resident_memory_unavailable",
          "target_working_set_bytes" => 10,
          "resident_memory_bytes" => 0
        })

      assert normalized.admission_tier == :headroom_unavailable

      assert MemoryBudget.selected_fields(normalized) == %{
               selected_memory_status_code: "resident_memory_unavailable",
               selected_memory_budget_available: true,
               selected_memory_headroom_available: false
             }
    end

    test "SPEC 7.5.3 keeps disabled, unknown, and device-info failures rank-neutral" do
      for status_code <- ["disabled", "device_info_unavailable", "new_future_status"] do
        normalized =
          MemoryBudget.normalize_for_scheduler(%{
            mode: "observe",
            budget_available: true,
            headroom_available: true,
            status_code: status_code
          })

        assert normalized.admission_tier == :headroom_unknown
        assert normalized.status_code == status_code
      end
    end

    test "SPEC 7.5.3 marks malformed numeric payloads invalid and drops counters" do
      normalized =
        MemoryBudget.normalize_for_scheduler(%{
          status_code: "ok",
          budget_available: true,
          headroom_available: true,
          target_working_set_bytes: -1,
          resident_memory_bytes: "4"
        })

      assert normalized.admission_tier == :headroom_unknown
      assert normalized.status_code == "invalid_status"

      assert MemoryBudget.selected_fields(normalized) == %{
               selected_memory_status_code: "invalid_status",
               selected_memory_budget_available: true,
               selected_memory_headroom_available: true
             }
    end

    test "SPEC 7.5.3 bounds strings and valid uint64-like counters" do
      normalized =
        MemoryBudget.normalize(%{
          model_ref: String.duplicate("m", 200),
          mode: String.duplicate("mode", 20),
          status_code: String.duplicate("s", 100),
          status_message: String.duplicate("x", 300),
          source: String.duplicate("source", 20),
          budget_available: false,
          headroom_available: false,
          estimated_headroom_bytes: 18_446_744_073_709_551_615
        })

      assert byte_size(normalized.model_ref) == 160
      assert byte_size(normalized.mode) == 40
      assert byte_size(normalized.status_code) == 80
      assert byte_size(normalized.status_message) == 240
      assert byte_size(normalized.source) == 80
      assert normalized.estimated_headroom_bytes == 18_446_744_073_709_551_615
      assert normalized.admission_tier == :headroom_unknown
    end
  end

  describe "selected_fields/1" do
    test "SPEC 7.5.3 persists whitelisted ok counters only" do
      fields =
        MemoryBudget.selected_fields(%{
          status_code: "ok",
          budget_available: true,
          headroom_available: true,
          target_working_set_bytes: 123,
          resident_memory_bytes: 100,
          estimated_headroom_bytes: 23,
          kv_cache_bytes_per_token: 2,
          prefill_workspace_bytes_per_token: 3,
          overhead_bytes: 99,
          status_message: "not persisted"
        })

      assert fields == %{
               selected_memory_status_code: "ok",
               selected_memory_budget_available: true,
               selected_memory_headroom_available: true,
               selected_memory_target_working_set_bytes: 123,
               selected_memory_resident_memory_bytes: 100,
               selected_memory_estimated_headroom_bytes: 23,
               selected_memory_kv_cache_bytes_per_token: 2,
               selected_memory_prefill_workspace_bytes_per_token: 3
             }

      refute Map.has_key?(fields, :selected_memory_overhead_bytes)
      refute Map.has_key?(fields, :selected_memory_status_message)
    end

    test "SPEC 7.5.3 exposes selected field key ownership" do
      assert MemoryBudget.selected_field_keys() == [
               :selected_memory_status_code,
               :selected_memory_budget_available,
               :selected_memory_headroom_available,
               :selected_memory_target_working_set_bytes,
               :selected_memory_resident_memory_bytes,
               :selected_memory_estimated_headroom_bytes,
               :selected_memory_kv_cache_bytes_per_token,
               :selected_memory_prefill_workspace_bytes_per_token
             ]
    end
  end
end
