defmodule Orchard.Repo.Migrations.RequestBodyCaptureModeTest do
  use Orchard.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Orchard.Repo
  alias Orchard.Repo.Migrations.RequestBodyCaptureMode
  alias Orchard.Requests.CapturePolicy

  import Orchard.TestSupport.ModelRequestFixtures

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260731010000_request_body_capture_mode.exs",
                    __DIR__
                  )

  Code.require_file(@migration_path)

  test "legacy purge retains only typed cache-affinity feedback" do
    affinity_key = "hmac-sha256:#{String.duplicate("a", 64)}"

    request =
      create_request!(%{
        payload_capture_mode: :metadata,
        scheduler_decision: %{
          "cache_affinity_enabled" => true,
          "cache_affinity_key" => affinity_key,
          "cache_affinity_hint_available" => true,
          "cache_affinity_selected_match" => false,
          "cache_affinity_source" => "recent_completed_request",
          "cache_affinity_candidate_count" => 2,
          "prompt" => "must be purged",
          "scored_candidates" => [%{"diagnostics" => "must be purged"}]
        }
      })

    run_legacy_scheduler_purge!(request.id)

    assert Repo.reload!(request).scheduler_decision == %{
             "cache_affinity_enabled" => true,
             "cache_affinity_key" => affinity_key,
             "cache_affinity_hint_available" => true,
             "cache_affinity_selected_match" => false,
             "cache_affinity_source" => "recent_completed_request",
             "cache_affinity_candidate_count" => 2
           }
  end

  test "legacy purge drops malformed cache-affinity values" do
    request =
      create_request!(%{
        payload_capture_mode: :none,
        scheduler_decision: %{
          "cache_affinity_enabled" => "true",
          "cache_affinity_key" => "hmac-sha256:#{String.duplicate("g", 64)}",
          "cache_affinity_hint_available" => %{"content" => "secret"},
          "cache_affinity_selected_match" => ["secret"],
          "cache_affinity_source" => "caller-controlled",
          "cache_affinity_candidate_count" => -1
        }
      })

    run_legacy_scheduler_purge!(request.id)

    assert Repo.reload!(request).scheduler_decision == %{}
  end

  test "legacy purge normalizes runtime-controlled error codes with application parity" do
    assert MapSet.new(RequestBodyCaptureMode.stable_error_codes()) ==
             MapSet.new(CapturePolicy.stable_error_codes())

    request =
      create_request!(%{
        payload_capture_mode: :full,
        error_code: "runtime echoed private content"
      })

    SQL.query!(
      Repo,
      """
      UPDATE requests
      SET payload_capture_mode = 'metadata',
          error_code = #{RequestBodyCaptureMode.legacy_stable_error_code_sql()}
      WHERE id::text = $1
      """,
      [request.id]
    )

    assert Repo.reload!(request).error_code == "internal_error"
  end

  defp run_legacy_scheduler_purge!(request_id) do
    SQL.query!(
      Repo,
      """
      UPDATE requests
      SET scheduler_decision = #{RequestBodyCaptureMode.legacy_cache_affinity_metadata_sql()}
      WHERE id::text = $1
      """,
      [request_id]
    )
  end
end
