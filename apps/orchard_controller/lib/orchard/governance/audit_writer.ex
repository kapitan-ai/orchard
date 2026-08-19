defmodule Orchard.Governance.AuditWriter do
  @moduledoc false

  alias Ecto.Changeset
  alias Orchard.Metrics.SeriesAdmission
  alias Orchard.Repo

  @pending_events_key {__MODULE__, :pending_events}

  @spec transaction((-> result)) :: {:ok, result} | {:error, term()} when result: term()
  def transaction(fun) when is_function(fun, 0) do
    previous_events = Process.get(@pending_events_key, :unset)
    Process.put(@pending_events_key, [])

    {result, events} =
      try do
        result = Repo.transaction(fun)
        {result, Process.get(@pending_events_key, [])}
      after
        restore_pending_events(previous_events)
      end

    publish_committed_events(result, events, previous_events)
  end

  @spec insert(Changeset.t()) :: {:ok, struct()} | {:error, Changeset.t()}
  def insert(%Changeset{} = changeset) do
    action = Changeset.get_field(changeset, :action)
    result = Repo.insert(changeset)
    emit_or_defer(action, result)
    result
  end

  defp emit_or_defer(action, {:ok, _audit_log} = result) do
    case Process.get(@pending_events_key, :unset) do
      :unset -> emit_safely(action, result)
      events -> Process.put(@pending_events_key, events ++ [{action, result}])
    end
  end

  defp emit_or_defer(action, result), do: emit_safely(action, result)

  defp publish_committed_events({:ok, _value} = result, events, :unset) do
    Enum.each(events, fn {action, insert_result} -> emit_safely(action, insert_result) end)
    result
  end

  defp publish_committed_events({:ok, _value} = result, events, previous_events) do
    Process.put(@pending_events_key, previous_events ++ events)
    result
  end

  defp publish_committed_events(result, _events, _previous_events), do: result

  defp restore_pending_events(:unset), do: Process.delete(@pending_events_key)
  defp restore_pending_events(events), do: Process.put(@pending_events_key, events)

  defp emit_safely(action, result) do
    with {:ok, action_domain} <- action_domain(action) do
      SeriesAdmission.emit(:audit_events, 1, %{
        action: action_domain,
        outcome: outcome(action, result)
      })
    end
  rescue
    _exception -> {:error, :metrics_degraded}
  catch
    _kind, _reason -> {:error, :metrics_degraded}
  end

  defp action_domain("tenant." <> _rest), do: {:ok, "tenant"}
  defp action_domain("api_key." <> _rest), do: {:ok, "api_key"}
  defp action_domain("service_account." <> _rest), do: {:ok, "service_account"}
  defp action_domain("role_binding." <> _rest), do: {:ok, "role_binding"}
  defp action_domain("routing_policy." <> _rest), do: {:ok, "routing_policy"}
  defp action_domain("tenant_model_access." <> _rest), do: {:ok, "tenant_model_access"}
  defp action_domain("support_bundle." <> _rest), do: {:ok, "support_bundle"}
  defp action_domain("node_admission." <> _rest), do: {:ok, "node_admission"}
  defp action_domain("node_enrollment." <> _rest), do: {:ok, "node_admission"}
  defp action_domain("node_trust." <> _rest), do: {:ok, "node_admission"}
  defp action_domain("node_lifecycle." <> _rest), do: {:ok, "node_lifecycle"}
  defp action_domain("provisioning_batch." <> _rest), do: {:ok, "service_account"}
  defp action_domain("cluster" <> _rest), do: {:ok, "cluster"}
  defp action_domain(_action), do: :error

  defp outcome(_action, {:error, _changeset}), do: "failed"
  defp outcome("api_key.auth_failed", {:ok, _audit_log}), do: "denied"
  defp outcome("node_admission.rejected", {:ok, _audit_log}), do: "denied"

  defp outcome(action, {:ok, _audit_log}) do
    if String.ends_with?(action, [".failed", ".output_failed"]),
      do: "failed",
      else: "succeeded"
  end
end
