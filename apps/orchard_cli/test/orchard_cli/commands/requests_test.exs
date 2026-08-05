defmodule OrchardCLI.Commands.RequestsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.API.Ops.SchedulerExplanationPresenter
  alias Orchard.Repo
  alias Orchard.Requests
  alias OrchardCLI.Commands.Requests, as: RequestsCmd

  import Orchard.TestSupport.ModelRequestFixtures

  @selected_node_id "11111111-1111-4111-8111-111111111111"
  @rejected_node_id "22222222-2222-4222-8222-222222222222"
  @skipped_node_id "33333333-3333-4333-8333-333333333333"

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "help and usage" do
    test "group usage lists inspect" do
      assert {:ok, message} = RequestsCmd.run(["--help"])
      assert message =~ "Usage: orchardctl requests <command>"
      assert message =~ "inspect"
    end

    test "inspect help documents json output" do
      assert {:ok, message} = RequestsCmd.run(["inspect", "--help"])
      assert message =~ "Usage: orchardctl requests inspect <request-id> [--json]"
      assert message =~ "shared scheduler explanation contract"
    end

    test "unknown option reports the flag" do
      assert {:error, message, 2} = RequestsCmd.run(["inspect", "resp_1", "--bogus"])
      assert message == "Unknown option: --bogus"
    end
  end

  describe "public dispatcher" do
    test "OrchardCLI.main/2 prints request scheduler explanation to stdout and exits zero" do
      parent = self()
      request = persist_valid_explanation!("resp_cli_main_scheduler_explanation")

      stdout =
        capture_io(fn ->
          OrchardCLI.main(["requests", "inspect", request.public_id], halt_stub(parent))
        end)

      assert stdout =~ "Request: #{request.public_id}"
      assert stdout =~ "Selected node: #{@selected_node_id}"
      assert stdout =~ "Rejected candidates:"
      assert stdout =~ "node_not_active,insufficient_memory"
      refute_received {:halt_called, _code}
    end

    test "OrchardCLI.main/2 prints stable not-found error to stderr and exits non-zero" do
      parent = self()

      stderr =
        capture_io(:stderr, fn ->
          OrchardCLI.main(["requests", "inspect", "resp_cli_main_missing"], halt_stub(parent))
        end)

      assert stderr =~ "Error: Scheduler explanation was not found."
      assert_received {:halt_called, 1}
    end
  end

  describe "inspect" do
    test "SPEC.md §7.3.5 and §11.9 json output derives scheduler explanation from Operator API presenter" do
      request = persist_valid_explanation!("resp_cli_scheduler_explanation")
      assert {:ok, expected} = SchedulerExplanationPresenter.show(request)

      assert {:ok, output} = RequestsCmd.run(["inspect", request.public_id, "--json"])

      assert Jason.decode!(output) == Jason.decode!(Jason.encode!(expected))
    end

    test "human output renders selected rejected and skipped scheduler explanation sections" do
      request = persist_valid_explanation!("resp_cli_scheduler_explanation_human")

      assert {:ok, output} = RequestsCmd.run(["inspect", request.public_id])

      assert output =~ "Request: #{request.public_id}"
      assert output =~ "Selected node: #{@selected_node_id}"
      assert output =~ "Selection tier: loaded"
      assert output =~ "Scored candidates:"
      assert output =~ "#{@selected_node_id} tier=loaded score=842 reason_codes=none"
      assert output =~ "Rejected candidates:"

      assert output =~
               "#{@rejected_node_id} tier=- score=- reason_codes=node_not_active,insufficient_memory"

      assert output =~ "Skipped candidates:"

      assert output =~
               "#{@skipped_node_id} tier=- score=- reason_codes=lower_tier_not_considered"
    end

    test "SPEC.md §7.3.5 json output reports unknown request id as scheduler explanation not found" do
      assert {:error, output, 1} =
               RequestsCmd.run(["inspect", "resp_missing_cli_explanation", "--json"])

      assert Jason.decode!(output) == %{
               "object" => "error",
               "code" => "scheduler_explanation_not_found",
               "message" => "Scheduler explanation was not found."
             }
    end

    test "legacy scheduler decisions without candidates are not explanations" do
      request =
        create_request!(%{
          public_id: "resp_cli_legacy_scheduler_decision",
          scheduler_decision: %{"strategy" => "single_node", "node_id" => nil}
        })

      assert {:error, output, 1} =
               RequestsCmd.run(["inspect", request.public_id, "--json"])

      assert Jason.decode!(output) == %{
               "object" => "error",
               "code" => "scheduler_explanation_not_found",
               "message" => "Scheduler explanation was not found."
             }
    end

    test "SPEC.md §7.3.5 json output reports invalid persisted scheduler explanations" do
      request =
        create_request!(%{
          public_id: "resp_cli_invalid_scheduler_explanation",
          payload_capture_mode: :full,
          scheduler_decision: %{
            "request_id" => "resp_cli_invalid_scheduler_explanation",
            "rejected_candidates" => [
              %{"node_id" => "node-rejected", "reason_codes" => ["not_a_scheduler_code"]}
            ]
          }
        })

      assert {:error, output, 1} = RequestsCmd.run(["inspect", request.public_id, "--json"])

      assert %{
               "object" => "error",
               "code" => "scheduler_explanation_invalid",
               "message" => "Persisted scheduler explanation is invalid.",
               "details" => details
             } = Jason.decode!(output)

      assert details =~ "not_a_scheduler_code"
    end

    test "reports database unavailable when the controller repo is unavailable" do
      request = persist_valid_explanation!("resp_cli_repo_unavailable_explanation")

      with_repo_unavailable(fn ->
        assert {:error, output, 1} = RequestsCmd.run(["inspect", request.public_id, "--json"])
        decoded = Jason.decode!(output)

        assert decoded["code"] == "database_unavailable"
        assert decoded["message"] =~ "database is unavailable"
      end)
    end
  end

  defp halt_stub(parent) do
    fn code -> send(parent, {:halt_called, code}) end
  end

  defp with_repo_unavailable(fun) do
    repo_pid = Process.whereis(Repo)
    Process.unregister(Repo)

    try do
      fun.()
    after
      Process.register(repo_pid, Repo)
    end
  end

  defp persist_valid_explanation!(public_id) do
    request = create_request!(%{public_id: public_id})

    assert {:ok, request} =
             Requests.record_schedule(request, %{
               request_id: request.public_id,
               selected_node_id: @selected_node_id,
               selection_tier: :loaded,
               scored_candidates: [
                 %{
                   node_id: @selected_node_id,
                   eligible: true,
                   tier: :loaded,
                   score: 842,
                   components: %{pool_bonus: 200},
                   reason_codes: []
                 }
               ],
               rejected_candidates: [
                 %{
                   node_id: @rejected_node_id,
                   reason_codes: [:node_not_active, "insufficient_memory"]
                 }
               ],
               skipped_candidates: [
                 %{
                   node_id: @skipped_node_id,
                   reason_codes: [:lower_tier_not_considered]
                 }
               ]
             })

    request
  end
end
