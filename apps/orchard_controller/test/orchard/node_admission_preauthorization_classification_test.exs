defmodule Orchard.NodeAdmissionPreauthorizationClassificationTest do
  use ExUnit.Case, async: true

  alias Orchard.ControllerInstances.ControllerInstance
  alias Orchard.DispatchCapacity.Authority
  alias Orchard.NodeAdmissionPreauthorizations
  alias Orchard.Nodes.{AdmissionMode, AdmissionPreauthorization, Node}

  test "exact locked authority is eligible for the bound admission" do
    assert {:admit, attrs} = classify(fixture())
    assert attrs["pool_id"] == "general"
    assert attrs["routing_policy_id"] == "default"
    assert attrs["controller_dispatch_ceiling"] == 1
  end

  test "identity correlation mismatches reject rather than fall back" do
    fixture = fixture()
    request = Map.put(fixture.request, :preauthorization_digest, digest(9))

    assert {:error, :node_enrollment_rejected} = classify(%{fixture | request: request})
  end

  test "mode, capacity, membership, expiry, revocation, and predicates drift pending review" do
    fixture = fixture()

    assert {:pending_review, :admission_mode_disabled} =
             classify(%{
               fixture
               | context: %{fixture.context | mode: %{fixture.context.mode | mode: :manual}}
             })

    assert {:pending_review, :dispatch_capacity_changed} =
             classify(%{
               fixture
               | context: %{
                   fixture.context
                   | authority: %{fixture.context.authority | required_contract_version: 2}
                 }
             })

    assert {:pending_review, :controller_membership_changed} =
             classify(%{fixture | context: %{fixture.context | controllers: []}})

    assert {:pending_review, :preauthorization_expired} =
             classify(%{fixture | now: fixture.preauthorization.expires_at})

    assert {:pending_review, :preauthorization_revoked} =
             classify(%{
               fixture
               | preauthorization: %{fixture.preauthorization | state: :revoked}
             })

    assert {:pending_review, :bound_admission_predicate_changed} =
             classify(%{
               fixture
               | request: %{
                   fixture.request
                   | runtime_endpoint: %{fixture.request.runtime_endpoint | port: 50_072}
                 }
             })
  end

  defp classify(fixture) do
    NodeAdmissionPreauthorizations.classify(
      fixture.preauthorization,
      fixture.context,
      fixture.request,
      fixture.node,
      fixture.now
    )
  end

  defp fixture do
    now = ~U[2026-09-21 12:00:00Z]
    controller_id = "11111111-1111-4111-8111-111111111111"
    enrollment_id = "22222222-2222-4222-8222-222222222222"
    node_id = "33333333-3333-4333-8333-333333333333"
    preauthorization_id = "44444444-4444-4444-8444-444444444444"

    %{
      now: now,
      preauthorization: %AdmissionPreauthorization{
        id: preauthorization_id,
        enrollment_id: enrollment_id,
        node_id: node_id,
        issuing_controller_id: controller_id,
        state: :authorized,
        expires_at: DateTime.add(now, 600, :second),
        pool_id: "general",
        pool_revision: "1",
        routing_policy_id: "default",
        routing_policy_revision: "1",
        controller_dispatch_ceiling: 1,
        capacity_policy_reason: "exact approved policy",
        dispatch_capacity_phase: :pre_cutover,
        dispatch_capacity_revision: 1,
        admission_mode_revision: 2,
        bound_predicates: %{
          "hostname" => "node.orchard.test",
          "runtime_host" => "10.0.0.21",
          "runtime_port" => 50_071
        },
        preview_digest: digest(1)
      },
      context: %{
        mode: %AdmissionMode{mode: :enrollment_preauthorized, version: 2},
        authority: %Authority{
          singleton: true,
          enforcement_phase: :pre_cutover,
          required_contract_version: 1
        },
        controllers: [%ControllerInstance{id: controller_id, status: :operational}]
      },
      node: %Node{
        id: node_id,
        state: :registered,
        hostname: "node.orchard.test",
        advertise_addr: "10.0.0.21",
        rpc_port: 50_071
      },
      request: %{
        preauthorization_id: preauthorization_id,
        preauthorization_digest: digest(1),
        runtime_endpoint: %{
          hostname: "node.orchard.test",
          host: "10.0.0.21",
          port: 50_071
        }
      }
    }
  end

  defp digest(byte), do: "sha256-#{Base.url_encode64(:binary.copy(<<byte>>, 32), padding: false)}"
end
