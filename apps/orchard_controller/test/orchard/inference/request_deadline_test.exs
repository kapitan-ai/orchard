defmodule Orchard.Inference.RequestDeadlineTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.Inference.RequestDeadline
  alias Orchard.Requests

  describe "absolute Request deadline" do
    test "SPEC.md §12.4 creates one UTC deadline from the admitted timeout" do
      now = ~U[2026-08-12 10:00:00.123456Z]

      assert RequestDeadline.timeout_at(120_000, now) ==
               ~U[2026-08-12 10:02:00.123456Z]
    end

    test "rejects an unresolved timeout before persistence" do
      now = ~U[2026-08-12 10:00:00.123456Z]

      assert_raise ArgumentError,
                   "request timeout must be a positive integer before persistence, got: nil",
                   fn ->
                     RequestDeadline.timeout_at(nil, now)
                   end
    end

    test "SPEC.md §§5.8 and 12.4 clamps remaining and stage budgets at zero" do
      timeout_at = ~U[2026-08-12 10:00:01.000000Z]

      assert RequestDeadline.remaining_ms(timeout_at, ~U[2026-08-12 10:00:00.250000Z]) == 750
      assert RequestDeadline.cap_ms(500, timeout_at, ~U[2026-08-12 10:00:00.250000Z]) == 500
      assert RequestDeadline.cap_ms(1_000, timeout_at, ~U[2026-08-12 10:00:00.250000Z]) == 750
      assert RequestDeadline.remaining_ms(timeout_at, ~U[2026-08-12 10:00:01.001000Z]) == 0
      assert RequestDeadline.cap_ms(500, timeout_at, ~U[2026-08-12 10:00:01.001000Z]) == 0
    end

    test "converts an absolute deadline to one local monotonic deadline from one clock sample" do
      timeout_at = ~U[2026-08-12 10:00:01.000000Z]
      system_ms = DateTime.to_unix(~U[2026-08-12 10:00:00.250000Z], :millisecond)

      assert RequestDeadline.to_monotonic_ms(timeout_at, system_ms, 42_000) == 42_750
      assert RequestDeadline.to_monotonic_ms(timeout_at, system_ms + 1_000, 42_000) == 42_000
    end
  end

  describe "Request creation contract" do
    test "new application rows require timeout_at" do
      attrs = request_attrs() |> Map.delete(:timeout_at)

      assert {:error, changeset} = Requests.create_request(attrs)
      assert %{timeout_at: ["can't be blank"]} = errors_on(changeset)
    end

    test "schedule, node assignment, and terminal writes cannot replace timeout_at" do
      original_timeout_at = ~U[2026-08-12 10:02:00.000000Z]
      replacement_timeout_at = ~U[2099-01-01 00:00:00.000000Z]

      assert {:ok, request} =
               Requests.create_request(request_attrs(%{timeout_at: original_timeout_at}))

      assert {:ok, scheduled} =
               Requests.record_schedule(request, %{
                 strategy: :single_node,
                 request_id: request.public_id,
                 runtime_client_target: [host: "10.0.0.1", port: 9444],
                 request_timeout_ms: 5_000,
                 model_load_timeout_ms: 120_000,
                 node_id: nil
               })

      assert scheduled.timeout_at == original_timeout_at

      assert {:ok, assigned} = Requests.assign_node(scheduled, Ecto.UUID.generate())
      assert assigned.timeout_at == original_timeout_at

      assert {:ok, terminal} =
               Requests.mark_terminal(assigned, %{
                 state: :failed,
                 error_code: "internal_error",
                 timeout_at: replacement_timeout_at
               })

      assert terminal.timeout_at == original_timeout_at
    end
  end
end
