defmodule Orchard.API.SentryContextBoundaryTest do
  use ExUnit.Case, async: false

  alias Orchard.API.SentryContextBoundary
  alias Orchard.Licensing
  alias Orchard.SentryContext

  setup do
    previous_config = Application.get_env(:orchard_shared, :sentry_enrichment)
    Application.put_env(:orchard_shared, :sentry_enrichment, enabled?: true)
    SentryContext.clear_all()
    SentryContext.clear_cached_license_status()

    on_exit(fn ->
      restore_enrichment(previous_config)
      SentryContext.clear_all()
      SentryContext.clear_cached_license_status()
    end)

    :ok
  end

  test "clears context after completed non-stream responses" do
    conn =
      Plug.Test.conn(:get, "/health/live")
      |> SentryContextBoundary.call([])

    Sentry.Context.set_extra_context(%{orchard_request_id: "req_non_stream"})

    _conn = Plug.Conn.send_resp(conn, 200, "ok")

    assert Sentry.Context.get_all().extra == %{}
  end

  test "keeps context when chunked event-stream starts so controller stream cleanup owns it" do
    conn =
      Plug.Test.conn(:get, "/v1/chat/completions")
      |> SentryContextBoundary.call([])
      |> Plug.Conn.put_resp_content_type("text/event-stream")

    Sentry.Context.set_extra_context(%{orchard_request_id: "req_stream"})

    _conn = Plug.Conn.send_chunked(conn, 200)

    assert Sentry.Context.get_all().extra == %{orchard_request_id: "req_stream"}
  end

  test "reapplies cached license context after clearing stale request context" do
    SentryContext.put_extra(%{orchard_request_id: "stale_req"})
    SentryContext.cache_license_status(license_status())

    _conn =
      Plug.Test.conn(:get, "/v1/models")
      |> SentryContextBoundary.call([])

    context = Sentry.Context.get_all()
    assert context.extra.orchard_license_state == "valid"
    assert context.tags.orchard_tracking_program == "eval"
    refute Map.has_key?(context.extra, :orchard_request_id)
  end

  test "does not reapply cached license context when controller enrichment is disabled" do
    Application.put_env(:orchard_shared, :sentry_enrichment,
      enabled?: true,
      controller_enabled?: false
    )

    SentryContext.cache_license_status(license_status())

    _conn =
      Plug.Test.conn(:get, "/v1/models")
      |> SentryContextBoundary.call([])

    assert Sentry.Context.get_all().extra == %{}
    assert Sentry.Context.get_all().tags == %{}
  end

  defp license_status do
    %Licensing{
      state: :valid,
      message: "License bundle is valid.",
      bundle_path: "/tmp/current.json",
      license_id: "lic_boundary_test",
      machine_id: "mach_boundary_test",
      metadata: %{program: "eval", reference: "phase-6"}
    }
  end

  defp restore_enrichment(nil), do: Application.delete_env(:orchard_shared, :sentry_enrichment)

  defp restore_enrichment(config),
    do: Application.put_env(:orchard_shared, :sentry_enrichment, config)
end
