defmodule Orchard.API.OperatorHealth do
  @moduledoc false

  alias Orchard.API.{HealthEvaluation, Readiness, ReadinessRemediation, Transport}

  @runtime_probe_timeout_ms 1_000

  @spec evaluate() :: {Plug.Conn.status(), map()}
  def evaluate do
    evaluation = HealthEvaluation.evaluate()
    status = if evaluation.ready?, do: :ok, else: :service_unavailable

    body =
      build_metadata()
      |> Map.merge(%{
        status: if(evaluation.ready?, do: "ok", else: "error"),
        checks: evaluation.checks,
        readiness_contract: %{
          version: Readiness.contract_version(),
          check_order: Readiness.check_order()
        },
        runtime: probe_runtime(),
        license: probe_license()
      })
      |> add_failure_detail(evaluation.reason)

    {status, body}
  end

  defp add_failure_detail(body, nil), do: body

  defp add_failure_detail(body, reason) do
    Map.merge(body, %{
      reason: Atom.to_string(reason),
      remediation: ReadinessRemediation.for_reason(reason)
    })
  end

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
      {:ok, snapshot} -> build_runtime_summary(:ok, snapshot)
      {:error, error} -> build_runtime_summary(error.status, error)
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

  defp classify_health(%{ready: true, health_code: code, health_message: message})
       when (code != nil and code != "") or (message != nil and message != ""),
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
