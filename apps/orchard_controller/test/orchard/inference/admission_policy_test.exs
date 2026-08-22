defmodule Orchard.Inference.AdmissionPolicyTest do
  use ExUnit.Case, async: true

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.{Admission, ModelRef, ResolvedPolicy}
  alias Orchard.Inference.{AdmissionPolicy, CanonicalRequestSerializer, RequestDeadline}

  test "SPEC.md routing_policies defaults resolve queue and cold budgets" do
    request = base_request()

    assert request.admission.timeout_ms == nil

    resolved = AdmissionPolicy.resolve(request)

    assert resolved.admission.queue_wait_ms == 3_000
    assert resolved.admission.max_cold_start_ms == 15_000
    assert resolved.resolved_policy.residency_preference == :allow_cold_load
  end

  test "explicit opts win over struct defaults" do
    request = base_request()

    resolved =
      AdmissionPolicy.resolve(request,
        queue_wait_ms: 100,
        max_cold_start_ms: 0,
        residency_preference: :required_loaded
      )

    assert resolved.admission.queue_wait_ms == 100
    assert resolved.admission.max_cold_start_ms == 0
    assert resolved.resolved_policy.residency_preference == :required_loaded
  end

  test "allow_cold_load policy adds queue and cold-start headroom to configured timeout" do
    request = base_request()

    resolved =
      AdmissionPolicy.resolve(request,
        timeout_ms: 120_000,
        queue_wait_ms: 3_000,
        max_cold_start_ms: 180_000,
        residency_preference: :allow_cold_load
      )

    assert resolved.admission.timeout_ms == 303_000
  end

  test "explicit timeout is used as the cold-path generation budget" do
    request = base_request()

    resolved =
      AdmissionPolicy.resolve(request,
        timeout_ms: 400_000,
        queue_wait_ms: 3_000,
        max_cold_start_ms: 180_000,
        residency_preference: :allow_cold_load
      )

    assert resolved.admission.timeout_ms == 583_000
  end

  test "resolving an already-resolved cold path does not add headroom twice" do
    request = base_request()

    resolved =
      AdmissionPolicy.resolve(request,
        timeout_ms: 120_000,
        queue_wait_ms: 3_000,
        max_cold_start_ms: 180_000,
        residency_preference: :allow_cold_load
      )

    re_resolved = AdmissionPolicy.resolve(resolved)

    assert re_resolved.admission.timeout_ms == 303_000
    assert CanonicalRequestSerializer.serialize(re_resolved)["admission"]["timeout_ms"] == 303_000
  end

  test "explicit zero cold budget is preserved for required_loaded style requests" do
    request =
      base_request(
        admission: %Admission{timeout_ms: 30_000, queue_wait_ms: 3_000, max_cold_start_ms: 0},
        resolved_policy: %ResolvedPolicy{residency_preference: :required_loaded}
      )

    resolved = AdmissionPolicy.resolve(request, residency_preference: :required_loaded)

    assert resolved.admission.max_cold_start_ms == 0
    assert resolved.resolved_policy.residency_preference == :required_loaded
  end

  test "empty-opts re-resolve preserves an already-resolved required_loaded zero budget" do
    request =
      base_request(
        admission: %Admission{timeout_ms: 30_000, queue_wait_ms: 3_000, max_cold_start_ms: 0},
        resolved_policy: %ResolvedPolicy{residency_preference: :required_loaded}
      )

    resolved = AdmissionPolicy.resolve(request)
    serialized = CanonicalRequestSerializer.serialize(resolved)
    now = ~U[2026-08-12 10:00:00.000000Z]

    assert resolved.admission.timeout_ms == 30_000
    assert resolved.admission.max_cold_start_ms == 0
    assert serialized["admission"]["timeout_ms"] == 30_000
    assert serialized["admission"]["max_cold_start_ms"] == 0

    assert RequestDeadline.timeout_at(serialized["admission"]["timeout_ms"], now) ==
             ~U[2026-08-12 10:00:30.000000Z]
  end

  test "historical allow_cold_load with zero cold budget is upgraded" do
    request =
      CanonicalRequest.new(%{
        internal_id: Ecto.UUID.generate(),
        public_id: "pub_" <> Ecto.UUID.generate(),
        endpoint: :chat_completions,
        tenant_id: Ecto.UUID.generate(),
        model_ref: %ModelRef{model_id: "m", version: "v1"},
        admission: %Admission{timeout_ms: 30_000, queue_wait_ms: 0, max_cold_start_ms: 0},
        resolved_policy: %ResolvedPolicy{residency_preference: :allow_cold_load}
      })

    # Force the contradictory pair through resolve after constructing with zeros
    # by calling resolve helpers via default_attrs path on a request built without
    # going through the upgraded defstruct defaults alone.
    upgraded =
      request
      |> Map.put(:admission, %Admission{
        timeout_ms: 30_000,
        queue_wait_ms: 0,
        max_cold_start_ms: 0
      })
      |> AdmissionPolicy.resolve()

    assert upgraded.admission.queue_wait_ms == 3_000
    assert upgraded.admission.max_cold_start_ms == 15_000
  end

  test "default_attrs mirrors resolve defaults" do
    attrs = AdmissionPolicy.default_attrs()

    assert attrs.admission.max_cold_start_ms == AdmissionPolicy.default_max_cold_start_ms()
    assert attrs.admission.queue_wait_ms == AdmissionPolicy.default_queue_wait_ms()
    assert attrs.resolved_policy.residency_preference == :allow_cold_load
  end

  test "CanonicalRequest Admission defaults stay aligned with AdmissionPolicy" do
    request = base_request()

    assert request.admission.queue_wait_ms == AdmissionPolicy.default_queue_wait_ms()
    assert request.admission.max_cold_start_ms == AdmissionPolicy.default_max_cold_start_ms()
  end

  defp base_request(overrides \\ []) do
    attrs =
      %{
        internal_id: Ecto.UUID.generate(),
        public_id: "pub_" <> Ecto.UUID.generate(),
        endpoint: :chat_completions,
        tenant_id: Ecto.UUID.generate(),
        model_ref: %ModelRef{model_id: "m", version: "v1"}
      }
      |> Map.merge(Map.new(overrides))

    CanonicalRequest.new(attrs)
  end
end
