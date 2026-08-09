defmodule Orchard.API.AuthenticationFailure do
  @moduledoc false

  alias Orchard.Governance
  alias Orchard.Metrics.SeriesAdmission

  @spec record(String.t() | nil, Governance.auth_failure_reason()) :: :ok
  def record(token, reason) do
    Governance.audit_api_key_auth_failure(token, reason)
    emit_safely()
    :ok
  end

  defp emit_safely do
    SeriesAdmission.emit(:api_key_auth_failures, 1, %{})
  rescue
    _exception -> {:error, :metrics_degraded}
  catch
    _kind, _reason -> {:error, :metrics_degraded}
  end
end
