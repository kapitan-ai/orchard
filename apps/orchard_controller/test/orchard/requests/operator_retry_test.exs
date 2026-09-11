defmodule Orchard.Requests.OperatorRetryTest.UnschedulableScheduler do
  @moduledoc false

  def schedule(_canonical, _opts), do: {:error, :no_active_nodes}
end

defmodule Orchard.Requests.OperatorRetryTest do
  use Orchard.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Changeset
  alias Orchard.Governance
  alias Orchard.Governance.Tenant
  alias Orchard.Models.{Access, Model, TenantModelAccess}
  alias Orchard.Repo
  alias Orchard.Requests.{OperatorRetry, Request}

  import Orchard.TestSupport.ModelRequestFixtures
  import Orchard.TestSupport.OperatorRetryFixtures

  describe "reserve/1" do
    test "SPEC.md §7.3.4 creates an eligible terminal legacy descendant from retained full evidence" do
      tenant = tenant!(:full)
      model = create_granted_model!(tenant)

      for {state, endpoint} <-
            for(
              state <- [:failed, :cancelled, :timed_out, :interrupted],
              endpoint <- [:chat_completions, :responses],
              do: {state, endpoint}
            ) do
        source =
          create_full_legacy_source!(tenant, model,
            state: state,
            endpoint: endpoint,
            idempotency_key: "retry-source-#{state}-#{endpoint}"
          )

        assert {:ok, %{request: descendant, canonical: canonical, model: ^model}} =
                 OperatorRetry.reserve(source.public_id)

        assert descendant.retry_of_request_id == source.id
        assert descendant.tenant_id == source.tenant_id
        assert descendant.payload_capture_mode == :full
        assert source.idempotency_key != nil
        assert descendant.idempotency_key == nil
        assert canonical.public_id == descendant.public_id
        assert canonical.input_items == source.canonical_request["input_items"]
        assert canonical.rendered_prompt == source.canonical_request["rendered_prompt"]
        refute Map.has_key?(descendant.canonical_request, "reasoning")

        assert descendant.body_hash ==
                 :crypto.hash(:sha256, Jason.encode!(descendant.canonical_request))
      end
    end

    test "rejects completed and active sources without creating a descendant" do
      tenant = tenant!(:full)
      model = create_granted_model!(tenant)

      for state <- [:completed, :received, :running] do
        source = create_full_legacy_source!(tenant, model, state: state)

        assert {:error, :retry_source_not_eligible} = OperatorRetry.reserve(source.public_id)
        assert descendant_count(source.id) == 0
      end
    end

    test "returns retry_source_unavailable for terminal sources without retained full canonical evidence" do
      tenant = tenant!(:full)
      model = create_granted_model!(tenant)

      missing_capture =
        create_full_legacy_source!(tenant, model,
          state: :failed,
          payload_capture_mode: :metadata,
          canonical_request: nil
        )

      missing_canonical = create_full_legacy_source!(tenant, model, state: :failed)

      Repo.update!(Changeset.change(missing_canonical, canonical_request: nil))

      for source <- [missing_capture, missing_canonical] do
        assert {:error, :retry_source_unavailable} = OperatorRetry.reserve(source.public_id)
        assert descendant_count(source.id) == 0
      end
    end

    test "rejects a retained negotiated reasoning snapshot before creating or dispatching a descendant" do
      tenant = tenant!(:full)
      model = create_granted_model!(tenant)
      source = create_full_legacy_source!(tenant, model, state: :failed)

      negotiated = %{
        "effective_contract" => %{
          "mode" => "negotiated",
          "model_artifact_digest" => String.duplicate("a", 64)
        }
      }

      source =
        Repo.update!(
          Changeset.change(source,
            canonical_request: Map.put(source.canonical_request, "reasoning", negotiated)
          )
        )

      assert {:error, :retry_source_unavailable} = OperatorRetry.reserve(source.public_id)
      assert descendant_count(source.id) == 0
    end

    test "rejects an identity-inconsistent retained source without creating a descendant" do
      tenant = tenant!(:full)
      model = create_granted_model!(tenant)
      source = create_full_legacy_source!(tenant, model, state: :failed)

      source =
        Repo.update!(
          Changeset.change(source,
            canonical_request:
              Map.put(source.canonical_request, "principal_id", Ecto.UUID.generate())
          )
        )

      assert {:error, :retry_source_unavailable} = OperatorRetry.reserve(source.public_id)
      assert descendant_count(source.id) == 0
    end

    test "rejects an unusable retained legacy tooling snapshot without creating a descendant" do
      tenant = tenant!(:full)
      model = create_granted_model!(tenant)
      source = create_full_legacy_source!(tenant, model, state: :failed)

      source =
        Repo.update!(
          Changeset.change(source,
            canonical_request:
              put_in(source.canonical_request, ["tooling", "execution_snapshot", "entries"], [%{}])
          )
        )

      assert {:error, :retry_source_unavailable} = OperatorRetry.reserve(source.public_id)
      assert descendant_count(source.id) == 0
    end

    test "uses the narrower current tenant capture policy without widening a full source snapshot" do
      for {mode, expected} <- [metadata: :metadata, none: :none] do
        tenant = tenant!(mode)
        model = create_granted_model!(tenant)
        source = create_full_legacy_source!(tenant, model, state: :failed)

        assert {:ok, %{request: descendant}} = OperatorRetry.reserve(source.public_id)
        assert descendant.payload_capture_mode == expected
        assert descendant.canonical_request == nil
        assert descendant.request_payload == nil

        case expected do
          :metadata -> assert is_map(descendant.request_shape)
          :none -> assert descendant.request_shape == nil
        end
      end
    end

    test "caps every original Request at three descendants and retains original lineage" do
      tenant = tenant!(:full)
      model = create_granted_model!(tenant)
      source = create_full_legacy_source!(tenant, model, state: :failed)

      descendants =
        for _ <- 1..3 do
          assert {:ok, %{request: descendant}} = OperatorRetry.reserve(source.public_id)
          descendant
        end

      assert Enum.all?(descendants, &(&1.retry_of_request_id == source.id))
      assert {:error, :operator_retry_limit_reached} = OperatorRetry.reserve(source.public_id)
      assert descendant_count(source.id) == 3
    end

    test "uses the original Request as the lineage target when retrying a descendant" do
      tenant = tenant!(:full)
      model = create_granted_model!(tenant)
      original = create_full_legacy_source!(tenant, model, state: :failed)

      assert {:ok, %{request: first_descendant}} = OperatorRetry.reserve(original.public_id)

      first_descendant =
        Repo.update!(
          Changeset.change(first_descendant, state: :failed, completed_at: DateTime.utc_now())
        )

      assert {:ok, %{request: second_descendant}} =
               OperatorRetry.reserve(first_descendant.public_id)

      assert first_descendant.retry_of_request_id == original.id
      assert second_descendant.retry_of_request_id == original.id
      assert descendant_count(original.id) == 2
    end

    test "SPEC.md §7.3.4 fails closed when the current Tenant Model access no longer authorizes the source" do
      for revoke <- [&Access.revoke_model_access/2, &Access.disable_model_access/2] do
        tenant = tenant!(:full)
        model = create_granted_model!(tenant)
        source = create_full_legacy_source!(tenant, model, state: :failed)

        assert {:ok, %{access: _access}} = revoke.(tenant, model)

        assert {:error, :retry_source_not_authorized} = OperatorRetry.reserve(source.public_id)
        assert descendant_count(source.id) == 0
      end
    end

    test "SPEC.md §7.3.4 fails closed when the source Model is no longer active" do
      for state <- [:registered, :deprecated, :retired] do
        tenant = tenant!(:full)
        model = create_granted_model!(tenant)
        source = create_full_legacy_source!(tenant, model, state: :failed)

        Repo.update!(Changeset.change(model, state: state))

        assert {:error, :retry_source_not_authorized} = OperatorRetry.reserve(source.public_id)
        assert descendant_count(source.id) == 0
      end
    end

    test "applies the current access grant routing policy without widening retained budgets" do
      tenant = tenant!(:full)

      {:ok, policy} =
        Access.create_routing_policy(%{
          name: "operator-retry-policy-#{System.unique_integer([:positive])}",
          allowed_pool_ids: [],
          preferred_pool_ids: [],
          residency_preference: :required_loaded,
          max_cold_start_ms: 0,
          max_queue_wait_ms: 250,
          priority: 100
        })

      model = create_granted_model!(tenant, routing_policy_id: policy.id)
      source = create_full_legacy_source!(tenant, model, state: :failed)
      retained = source.canonical_request

      assert {:ok, %{request: descendant, canonical: canonical}} =
               OperatorRetry.reserve(source.public_id)

      assert retained["resolved_policy"]["routing_policy_id"] == nil
      assert retained["resolved_policy"]["residency_preference"] == "allow_cold_load"
      assert retained["admission"]["queue_wait_ms"] == 1_000
      assert retained["admission"]["max_cold_start_ms"] == 1_000

      assert canonical.resolved_policy.routing_policy_id == policy.id
      assert canonical.resolved_policy.residency_preference == :required_loaded
      assert canonical.admission.queue_wait_ms == 250
      assert canonical.admission.max_cold_start_ms == 0
      assert canonical.admission.timeout_ms == retained["admission"]["timeout_ms"]

      assert descendant.canonical_request["resolved_policy"]["routing_policy_id"] == policy.id
      assert descendant.canonical_request["admission"]["queue_wait_ms"] == 250
    end

    test "rejects a retained admission snapshot without a positive timeout" do
      tenant = tenant!(:full)
      model = create_granted_model!(tenant)

      for admission <- [%{"timeout_ms" => nil}, %{"timeout_ms" => 0}, %{"queue_wait_ms" => nil}] do
        source = create_full_legacy_source!(tenant, model, state: :failed)

        source =
          Repo.update!(
            Changeset.change(source,
              canonical_request:
                Map.update!(
                  source.canonical_request,
                  "admission",
                  &Map.merge(&1, admission)
                )
            )
          )

        assert {:error, :retry_source_unavailable} = OperatorRetry.reserve(source.public_id)
        assert descendant_count(source.id) == 0
      end
    end

    test "rejects a retained canonical source whose nested sections are not maps" do
      tenant = tenant!(:full)
      model = create_granted_model!(tenant)

      for {key, value} <- [{"tooling", []}, {"tooling", "none"}, {"sampling", 7}] do
        source = create_full_legacy_source!(tenant, model, state: :failed)

        source =
          Repo.update!(
            Changeset.change(source,
              canonical_request: Map.put(source.canonical_request, key, value)
            )
          )

        assert {:error, :retry_source_unavailable} = OperatorRetry.reserve(source.public_id)
        assert descendant_count(source.id) == 0
      end
    end

    test "serializes concurrent reservations for one original lineage across real connections" do
      %{source: source} = committed_retry_source!()

      results =
        1..4
        |> Task.async_stream(
          fn _ ->
            Sandbox.unboxed_run(Repo, fn -> OperatorRetry.reserve(source.public_id) end)
          end,
          max_concurrency: 4,
          ordered: false,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _reservation}, &1)) == 3
      assert Enum.count(results, &(&1 == {:error, :operator_retry_limit_reached})) == 1

      assert Sandbox.unboxed_run(Repo, fn -> descendant_count(source.id) end) == 3
    end
  end

  describe "retry/2" do
    test "SPEC.md §7.3.4 retains the descendant and reports an incomplete dispatch outcome" do
      use_unschedulable_scheduler()

      tenant = tenant!(:full)
      model = create_granted_model!(tenant)
      source = create_full_legacy_source!(tenant, model, state: :failed)

      assert {:error, :retry_dispatch_incomplete} =
               OperatorRetry.retry(source.public_id,
                 terminal_persister: fn _request, _attrs, _steps ->
                   {:error, :terminal_row_unavailable}
                 end
               )

      assert descendant_count(source.id) == 1

      descendant =
        Request
        |> where([request], request.retry_of_request_id == ^source.id)
        |> Repo.one!()

      refute descendant.state in [:completed, :failed, :cancelled, :timed_out, :interrupted]
    end

    test "reports a created descendant when dispatch reaches a terminal failure" do
      use_unschedulable_scheduler()

      tenant = tenant!(:full)
      model = create_granted_model!(tenant)
      source = create_full_legacy_source!(tenant, model, state: :failed)

      assert {:ok, descendant} = OperatorRetry.retry(source.public_id)
      assert descendant.retry_of_request_id == source.id
      assert descendant.state == :failed
    end
  end

  defp use_unschedulable_scheduler do
    inference = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.put(
        inference,
        :scheduler_impl,
        Orchard.Requests.OperatorRetryTest.UnschedulableScheduler
      )
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :inference, inference) end)
  end

  defp committed_retry_source! do
    :ok = Sandbox.checkin(Repo)

    fixture = Sandbox.unboxed_run(Repo, &insert_committed_retry_source!/0)

    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> delete_committed_fixture!(fixture) end) end)

    fixture
  end

  defp insert_committed_retry_source! do
    suffix = System.unique_integer([:positive])

    tenant =
      Repo.insert!(
        Tenant.changeset(%Tenant{}, %{
          slug: "operator-retry-race-#{suffix}",
          name: "Operator Retry Race #{suffix}",
          request_body_capture_mode: :full
        })
      )

    model = create_model!(%{state: :active})

    Repo.insert!(
      TenantModelAccess.changeset(%TenantModelAccess{}, %{
        tenant_id: tenant.id,
        model_id: model.id,
        enabled: true
      })
    )

    %{
      tenant: tenant,
      model: model,
      source: create_full_legacy_source!(tenant, model, state: :failed)
    }
  end

  defp delete_committed_fixture!(%{tenant: tenant, model: model}) do
    Repo.delete_all(
      from(request in Request,
        where: request.tenant_id == ^tenant.id and not is_nil(request.retry_of_request_id)
      )
    )

    Repo.delete_all(from(request in Request, where: request.tenant_id == ^tenant.id))
    Repo.delete_all(from(access in TenantModelAccess, where: access.tenant_id == ^tenant.id))
    Repo.delete_all(from(candidate in Model, where: candidate.id == ^model.id))
    Repo.delete_all(from(candidate in Tenant, where: candidate.id == ^tenant.id))
  end

  defp tenant!(capture_mode) do
    suffix = System.unique_integer([:positive])

    {:ok, tenant} =
      Governance.create_tenant(%{
        slug: "operator-retry-#{suffix}",
        name: "Operator Retry #{suffix}",
        request_body_capture_mode: capture_mode
      })

    tenant
  end

  defp descendant_count(original_id) do
    Request
    |> where([request], request.retry_of_request_id == ^original_id)
    |> Repo.aggregate(:count)
  end
end
