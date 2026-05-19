defmodule Orchard.API.HealthController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Orchard.API.{Readiness, ReadinessRemediation, Transport}

  @runtime_probe_timeout_ms 1_000

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    runtime = probe_runtime()
    license = probe_license()

    case Readiness.status() do
      {:ok, checks} ->
        json(
          conn,
          Map.merge(build_metadata(), %{
            status: "ok",
            checks: checks,
            runtime: runtime,
            license: license
          })
        )

      {:error, reason, checks} ->
        conn
        |> put_status(:service_unavailable)
        |> json(
          Map.merge(build_metadata(), %{
            status: "error",
            reason: Atom.to_string(reason),
            remediation: ReadinessRemediation.for_reason(reason),
            checks: checks,
            runtime: runtime,
            license: license
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
      build_date: Orchard.BuildInfo.build_date(),
      build_channel: Orchard.BuildInfo.build_channel(),
      transport: Transport.metadata(),
      console: console_metadata()
    }
  end

  defp console_metadata do
    config = Application.get_env(:orchard_controller, :console, [])
    enabled = Keyword.get(config, :enabled, false) == true

    %{
      enabled: enabled,
      auth_mode: console_auth_mode(enabled, Keyword.get(config, :auth))
    }
  end

  defp console_auth_mode(true, :basic), do: "basic"
  defp console_auth_mode(_enabled, _auth), do: "disabled"

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

  defp probe_license do
    licensing_impl().inspect_local()
    |> Orchard.Licensing.health_summary()
  rescue
    _ ->
      %{
        status: "invalid",
        reason: "malformed_bundle",
        message: "license inspection failed",
        expires_at: nil
      }
  end

  defp runtime_impl do
    Application.get_env(:orchard_controller, :console, [])
    |> Keyword.get(:runtime_impl, OrchardConsole.Runtime)
  end

  defp licensing_impl do
    Application.get_env(:orchard_controller, :console, [])
    |> Keyword.get(:licensing_impl, Orchard.Licensing)
  end
end
