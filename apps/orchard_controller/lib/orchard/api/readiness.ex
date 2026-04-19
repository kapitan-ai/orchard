defmodule Orchard.API.Readiness do
  @moduledoc false

  alias Orchard.Release

  # Causal priority for failure-reason selection.
  # When multiple checks fail, the first false key in this list becomes the
  # reported reason. DB connectivity gates migration checks: if Postgres is
  # unreachable, migrations_current is reported as false (blocked) without
  # executing the migration query.
  #
  # Note: this ordering differs from OverviewLive's @readiness_check_order,
  # which controls display order. This list controls failure-reason priority.
  @check_priority [
    :postgres_reachable,
    :migrations_current,
    :public_api_https_enabled,
    :controller_boot_completed
  ]

  @type checks :: %{required(atom()) => boolean()}
  @type status_result :: {:ok, checks()} | {:error, atom(), checks()}

  @spec status() :: status_result()
  def status do
    postgres_reachable = Release.postgres_reachable?()

    migrations_current =
      if postgres_reachable do
        migrations_current?()
      else
        false
      end

    checks = %{
      controller_boot_completed: true,
      postgres_reachable: postgres_reachable,
      migrations_current: migrations_current,
      public_api_https_enabled: public_api_https_enabled?()
    }

    if Enum.all?(checks, fn {_check, status} -> status end) do
      {:ok, checks}
    else
      {:error, first_failure(checks), checks}
    end
  end

  defp migrations_current? do
    Release.migrations_current?()
  end

  defp public_api_https_enabled? do
    not Application.get_env(:orchard_controller, :transport_degraded, false)
  end

  defp first_failure(checks) do
    Enum.find_value(@check_priority, :unknown, fn key ->
      if Map.get(checks, key) == false, do: key
    end)
  end
end
