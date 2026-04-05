defmodule Orchard.API.HealthController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Orchard.API.Readiness

  @runtime_probe_timeout_ms 1_000

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    runtime = probe_runtime()

    case Readiness.status() do
      {:ok, checks} ->
        json(conn, Map.merge(build_metadata(), %{status: "ok", checks: checks, runtime: runtime}))

      {:error, reason, checks} ->
        conn
        |> put_status(:service_unavailable)
        |> json(
          Map.merge(build_metadata(), %{
            status: "error",
            reason: Atom.to_string(reason),
            checks: checks,
            runtime: runtime
          })
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Runtime probe (observational, never affects readiness outcome)
  # ---------------------------------------------------------------------------

  defp build_metadata do
    %{
      version: Orchard.version(),
      build_ref: Orchard.BuildInfo.git_sha(),
      build_date: Orchard.BuildInfo.build_date()
    }
  end

  defp probe_runtime do
    case runtime_impl().snapshot(timeout: @runtime_probe_timeout_ms) do
      {:ok, snapshot} ->
        build_runtime_summary(:ok, snapshot)

      {:error, error} ->
        build_runtime_summary(error.status, error)
    end
  rescue
    _ ->
      build_runtime_summary(:error, %{
        worker_state: :unknown,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: nil,
        runtime_health: nil,
        message: "runtime snapshot unavailable"
      })
  end

  defp build_runtime_summary(status, snapshot) do
    meta = Map.get(snapshot, :node_metadata)
    health = Map.get(snapshot, :runtime_health)

    %{
      status: to_string(status),
      node_id: meta_field(meta, :node_id),
      display_name: meta_field(meta, :display_name),
      worker_state: to_string(Map.get(snapshot, :worker_state, :unknown)),
      health: classify_health(health),
      counts: %{
        active_requests: if(status == :ok, do: Map.get(snapshot, :active_request_count, 0)),
        loaded_models: if(status == :ok, do: length(Map.get(snapshot, :loaded_models, [])))
      },
      message: Map.get(snapshot, :message)
    }
  end

  defp meta_field(nil, _key), do: nil
  defp meta_field(meta, key), do: Map.get(meta, key)

  defp classify_health(nil), do: "unsupported"
  defp classify_health(%{ready: false}), do: "unhealthy"

  defp classify_health(%{ready: true, health_code: code, health_message: msg})
       when (code != nil and code != "") or (msg != nil and msg != ""),
       do: "degraded"

  defp classify_health(%{ready: true}), do: "healthy"
  defp classify_health(_), do: "unknown"

  defp runtime_impl do
    Application.get_env(:orchard_controller, :console, [])
    |> Keyword.get(:runtime_impl, OrchardConsole.Runtime)
  end
end
