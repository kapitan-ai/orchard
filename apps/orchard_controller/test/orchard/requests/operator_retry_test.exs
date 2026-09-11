defmodule Orchard.Requests.OperatorRetryTest do
  use Orchard.DataCase, async: false

  import Ecto.Query

  alias Ecto.Changeset
  alias Orchard.Governance
  alias Orchard.Repo
  alias Orchard.Requests
  alias Orchard.Requests.OperatorRetry

  import Orchard.TestSupport.ModelRequestFixtures
  import Orchard.TestSupport.OperatorRetryFixtures

  describe "reserve/1" do
    test "SPEC.md §7.3.4 creates an eligible terminal legacy descendant from retained full evidence" do
      tenant = tenant!(:full)
      model = create_model!()

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
      model = create_model!()

      for state <- [:completed, :received, :running] do
        source = create_full_legacy_source!(tenant, model, state: state)

        assert {:error, :retry_source_not_eligible} = OperatorRetry.reserve(source.public_id)
        assert descendant_count(source.id) == 0
      end
    end

    test "returns retry_source_unavailable for terminal sources without retained full canonical evidence" do
      tenant = tenant!(:full)
      model = create_model!()

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
      model = create_model!()
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
      model = create_model!()
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
      model = create_model!()
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
      model = create_model!()

      for {mode, expected} <- [metadata: :metadata, none: :none] do
        tenant = tenant!(mode)
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
      model = create_model!()
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
      model = create_model!()
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

    test "serializes concurrent reservations under the original Request lock" do
      tenant = tenant!(:full)
      model = create_model!()
      source = create_full_legacy_source!(tenant, model, state: :failed)

      results =
        1..4
        |> Task.async_stream(
          fn _ -> OperatorRetry.reserve(source.public_id) end,
          max_concurrency: 4,
          ordered: false,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _reservation}, &1)) == 3
      assert Enum.count(results, &(&1 == {:error, :operator_retry_limit_reached})) == 1
      assert descendant_count(source.id) == 3
    end
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
    Requests.Request
    |> where([request], request.retry_of_request_id == ^original_id)
    |> Repo.aggregate(:count)
  end
end
