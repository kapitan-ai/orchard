defmodule Orchard.TestSupport.SentryContextHelpers do
  @moduledoc false

  @spec setup_sentry_context(map()) :: :ok
  def setup_sentry_context(_context) do
    previous_config = Application.get_env(:orchard_shared, :sentry_enrichment)
    clear_sentry_context()

    ExUnit.Callbacks.on_exit(fn ->
      restore_config(previous_config)
      clear_sentry_context()
    end)

    :ok
  end

  @spec enable_controller_sentry(keyword()) :: :ok
  def enable_controller_sentry(overrides \\ []) do
    config =
      [
        enabled?: true,
        controller_enabled?: true,
        node_agent_enabled?: false,
        telemetry_breadcrumbs_enabled?: false,
        hash_secret: "controller-sentry-test-secret"
      ]
      |> Keyword.merge(overrides)

    Application.put_env(:orchard_shared, :sentry_enrichment, config)
  end

  @spec sentry_context() :: map()
  def sentry_context, do: Sentry.Context.get_all()

  @spec breadcrumb_messages() :: [String.t()]
  def breadcrumb_messages do
    sentry_context().breadcrumbs
    |> Enum.map(& &1.message)
  end

  @spec clear_sentry_context() :: :ok
  def clear_sentry_context do
    if Code.ensure_loaded?(Sentry.Context) do
      Sentry.Context.clear_all()
    end

    :ok
  end

  defp restore_config(nil), do: Application.delete_env(:orchard_shared, :sentry_enrichment)

  defp restore_config(config),
    do: Application.put_env(:orchard_shared, :sentry_enrichment, config)
end
