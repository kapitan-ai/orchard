defmodule Orchard.API.HTTPMetrics do
  @moduledoc false

  @behaviour Plug

  alias Orchard.Metrics.SeriesAdmission

  @impl Plug
  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(conn, _opts) do
    started_at = System.monotonic_time()
    endpoint = endpoint(conn.path_info)
    method = conn.method

    Plug.Conn.register_before_send(conn, fn conn ->
      status = conn.status

      emit_safely(:http_requests, 1, %{
        endpoint: endpoint,
        method: method,
        status: status
      })

      duration_seconds =
        System.convert_time_unit(
          System.monotonic_time() - started_at,
          :native,
          :microsecond
        ) / 1_000_000

      emit_safely(:http_request_duration, duration_seconds, %{
        endpoint: endpoint,
        status: status
      })

      conn
    end)
  end

  defp endpoint(["v1" | _rest]), do: "public_api"
  defp endpoint(["ops", "v1" | _rest]), do: "operator_api"
  defp endpoint(["admin", "v1" | _rest]), do: "admin_api"
  defp endpoint(["console" | _rest]), do: "console"
  defp endpoint(["live" | _rest]), do: "console"
  defp endpoint(["health" | _rest]), do: "health"
  defp endpoint(["metrics"]), do: "metrics"
  defp endpoint(["assets" | _rest]), do: "static"
  defp endpoint(["fonts" | _rest]), do: "static"
  defp endpoint(["images" | _rest]), do: "static"
  defp endpoint(["favicon.ico"]), do: "static"
  defp endpoint(["robots.txt"]), do: "static"
  defp endpoint(_path_info), do: "unmatched"

  defp emit_safely(family, value, labels) do
    SeriesAdmission.emit(family, value, labels)
  rescue
    _exception -> {:error, :metrics_degraded}
  catch
    _kind, _reason -> {:error, :metrics_degraded}
  end
end
