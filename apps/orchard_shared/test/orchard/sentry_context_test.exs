defmodule Orchard.SentryContextTest do
  use ExUnit.Case, async: false

  alias Orchard.SentryContext

  @config_key {Orchard.SentryContext, :sdk_warning_logged?}

  setup do
    previous_config = Application.get_env(:orchard_shared, :sentry_enrichment)
    erase_warning_marker()
    clear_sentry_context()

    on_exit(fn ->
      restore_config(previous_config)
      erase_warning_marker()
      clear_sentry_context()
    end)

    :ok
  end

  test "feature flag checks honor the master kill switch and defaults" do
    Application.put_env(:orchard_shared, :sentry_enrichment, [])

    refute SentryContext.controller_enabled?()
    refute SentryContext.node_agent_enabled?()
    refute SentryContext.telemetry_breadcrumbs_enabled?()

    Application.put_env(:orchard_shared, :sentry_enrichment, enabled?: true)

    assert SentryContext.controller_enabled?()
    assert SentryContext.node_agent_enabled?()
    refute SentryContext.telemetry_breadcrumbs_enabled?()

    Application.put_env(:orchard_shared, :sentry_enrichment,
      enabled?: true,
      controller_enabled?: false,
      node_agent_enabled?: true,
      telemetry_breadcrumbs_enabled?: true
    )

    refute SentryContext.controller_enabled?()
    assert SentryContext.node_agent_enabled?()
    assert SentryContext.telemetry_breadcrumbs_enabled?()

    Application.put_env(:orchard_shared, :sentry_enrichment,
      enabled?: false,
      controller_enabled?: true,
      node_agent_enabled?: true,
      telemetry_breadcrumbs_enabled?: true
    )

    refute SentryContext.controller_enabled?()
    refute SentryContext.node_agent_enabled?()
    refute SentryContext.telemetry_breadcrumbs_enabled?()
  end

  test "hash_id returns stable 16 character HMAC hex only when secret is configured" do
    Application.put_env(:orchard_shared, :sentry_enrichment, hash_secret: nil)
    assert SentryContext.hash_id("tenant-1") == nil
    assert SentryContext.hash_id(nil) == nil

    Application.put_env(:orchard_shared, :sentry_enrichment, hash_secret: "hash-secret")

    expected =
      :hmac
      |> :crypto.mac(:sha256, "hash-secret", "tenant-1")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    assert SentryContext.hash_id("tenant-1") == expected
    assert SentryContext.hash_id("tenant-1") == SentryContext.hash_id("tenant-1")
    assert String.length(expected) == 16
  end

  test "build_caller_extra omits hashes without a secret and includes only HMAC hashes with one" do
    caller = %{
      tenant_id: "tenant-1",
      principal_type: :service_account,
      principal_id: "principal-1",
      api_key_id: "key-1"
    }

    Application.put_env(:orchard_shared, :sentry_enrichment, hash_secret: nil)

    assert SentryContext.build_caller_extra(caller) == %{
             orchard_principal_type: "service_account"
           }

    Application.put_env(:orchard_shared, :sentry_enrichment, hash_secret: "hash-secret")
    extra = SentryContext.build_caller_extra(caller)

    assert MapSet.new(Map.keys(extra)) ==
             MapSet.new([
               :orchard_api_key_hash,
               :orchard_principal_type,
               :orchard_principal_hash,
               :orchard_tenant_hash
             ])

    assert extra.orchard_tenant_hash == SentryContext.hash_id("tenant-1")
    assert extra.orchard_principal_type == "service_account"
    refute extra.orchard_principal_hash == "principal-1"
    refute extra.orchard_api_key_hash == "key-1"
  end

  test "build_request_extra returns safe request shape and handles nil inputs" do
    canonical = %{
      public_id: "req-public",
      endpoint: :responses,
      stream?: true,
      tooling: %{tools: [%{type: "function"}]},
      model_ref: %{model_id: "mlx-community/qwen", version: "4bit"}
    }

    db_request = %{public_id: "db-public", endpoint: :chat_completions, stream: false}

    assert SentryContext.build_request_extra(db_request, canonical) == %{
             orchard_request_id: "req-public",
             orchard_db_request_id: "db-public",
             orchard_endpoint: :responses,
             orchard_stream: true,
             orchard_tooling: true,
             orchard_model_id: "mlx-community/qwen",
             orchard_model_version: "4bit"
           }

    assert SentryContext.build_request_extra(nil, nil) == %{orchard_tooling: false}
  end

  test "build_dispatch_extra redacts targets and keeps sparse metrics" do
    Application.put_env(:orchard_shared, :sentry_enrichment, hash_secret: "hash-secret")

    metrics = %{
      model_already_loaded: false,
      ensure_model_loaded_ms: 25,
      accepted_to_first_delta_ms: :na,
      accepted_to_terminal_ms: 80,
      event_count: 3,
      anomaly: :none,
      conformance_defect: :post_terminal
    }

    assert SentryContext.build_dispatch_extra(metrics,
             node_id: "node-1",
             scheduler_strategy: :single_node,
             target_host: "192.0.2.10"
           ) == %{
             orchard_node_hash: SentryContext.hash_id("node-1"),
             orchard_scheduler_strategy: :single_node,
             orchard_target_host_sanitized: "[redacted]",
             orchard_model_already_loaded: false,
             orchard_ensure_model_loaded_ms: 25,
             orchard_accepted_to_terminal_ms: 80,
             orchard_event_count: 3,
             orchard_conformance_defect: :post_terminal
           }
  end

  test "build_dispatch_tags normalizes atoms and booleans to strings" do
    metrics = %{terminal_source: :stream, outcome: :ok}

    assert SentryContext.build_dispatch_tags(metrics,
             endpoint: :responses,
             stream: true,
             tooling: false,
             scheduler_strategy: :single_node
           ) == %{
             orchard_app: "controller",
             orchard_surface: "api",
             orchard_endpoint: "responses",
             stream: "true",
             tooling: "false",
             scheduler_strategy: "single_node",
             failure_category: "ok",
             terminal_source: "stream"
           }
  end

  test "build_node_request_extra returns request and model identifiers without prompt payloads" do
    request = %{
      request_id: "req-node",
      model_id: "mlx-community/qwen",
      version: "4bit",
      model_backend: :mlx,
      rendered_prompt_utf8: "not copied"
    }

    assert SentryContext.build_node_request_extra(request) == %{
             orchard_request_id: "req-node",
             orchard_model_id: "mlx-community/qwen",
             orchard_model_version: "4bit",
             orchard_model_backend: :mlx
           }
  end

  test "side-effect wrappers no-op when enrichment is disabled" do
    Application.put_env(:orchard_shared, :sentry_enrichment, enabled?: false)

    assert :ok = SentryContext.put_extra(%{safe: "value"})
    assert :ok = SentryContext.put_tags(%{safe_tag: :value})
    assert :ok = SentryContext.add_breadcrumb(category: "orchard.test", message: "disabled")

    assert sentry_context().extra == %{}
    assert sentry_context().tags == %{}
    assert sentry_context().breadcrumbs == []
  end

  test "breadcrumb_context_present? only returns true for request-scoped enrichment" do
    Application.put_env(:orchard_shared, :sentry_enrichment, enabled?: true)

    refute SentryContext.breadcrumb_context_present?()

    assert :ok = SentryContext.put_extra(%{orchard_request_id: "req_123"})
    assert SentryContext.breadcrumb_context_present?()

    clear_sentry_context()
    refute SentryContext.breadcrumb_context_present?()
  end

  test "clear_all clears process-local Sentry context" do
    Application.put_env(:orchard_shared, :sentry_enrichment, enabled?: true)

    assert :ok = SentryContext.put_extra(%{orchard_request_id: "req_123"})
    assert SentryContext.breadcrumb_context_present?()

    assert :ok = SentryContext.clear_all()
    refute SentryContext.breadcrumb_context_present?()
    assert sentry_context().extra == %{}
  end

  test "side-effect wrappers rescue SDK exceptions" do
    Application.put_env(:orchard_shared, :sentry_enrichment, enabled?: true)

    assert :ok = SentryContext.add_breadcrumb([:not_keyword])
  end

  defp sentry_context, do: Sentry.Context.get_all()

  defp clear_sentry_context do
    if Code.ensure_loaded?(Sentry.Context) do
      Sentry.Context.clear_all()
    end
  end

  defp restore_config(nil), do: Application.delete_env(:orchard_shared, :sentry_enrichment)

  defp restore_config(config),
    do: Application.put_env(:orchard_shared, :sentry_enrichment, config)

  defp erase_warning_marker do
    :persistent_term.erase(@config_key)
  rescue
    ArgumentError -> false
  end
end
