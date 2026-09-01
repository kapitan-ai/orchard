defmodule Orchard.Governance.AuditWriter do
  @moduledoc false

  alias Ecto.Changeset
  alias Orchard.Metrics.SeriesAdmission
  alias Orchard.Metrics.Status
  alias Orchard.Repo

  @pending_events_key {__MODULE__, :pending_events}
  @commit_verification_degradation {:audit_commit_verification, :unavailable}

  @spec transaction((-> result)) :: {:ok, result} | {:error, term()} when result: term()
  def transaction(fun) when is_function(fun, 0) do
    if Process.get(@pending_events_key, :unset) == :unset and Repo.in_transaction?() do
      {:error, :audit_writer_not_outermost}
    else
      run_transaction(fun)
    end
  end

  defp run_transaction(fun) do
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
    if unmanaged_transaction?() do
      {:error,
       Changeset.add_error(
         changeset,
         :base,
         "audit writer must own the outermost transaction",
         validation: :audit_writer_not_outermost
       )}
    else
      action = Changeset.get_field(changeset, :action)
      result = Repo.insert(changeset)
      emit_or_defer(action, result)
      result
    end
  end

  defp emit_or_defer(action, {:ok, _audit_log} = result) do
    case Process.get(@pending_events_key, :unset) do
      :unset -> emit_safely(action, result)
      events -> Process.put(@pending_events_key, events ++ [{action, result}])
    end
  end

  defp emit_or_defer(action, result), do: emit_safely(action, result)

  defp publish_committed_events({:ok, _value} = result, events, :unset) do
    Enum.each(events, fn {action, insert_result} -> emit_if_committed(action, insert_result) end)
    result
  end

  defp publish_committed_events({:ok, _value} = result, events, previous_events) do
    Process.put(@pending_events_key, previous_events ++ events)
    result
  end

  defp publish_committed_events(result, _events, _previous_events), do: result

  defp restore_pending_events(:unset), do: Process.delete(@pending_events_key)
  defp restore_pending_events(events), do: Process.put(@pending_events_key, events)

  defp unmanaged_transaction? do
    Process.get(@pending_events_key, :unset) == :unset and Repo.in_transaction?()
  end

  defp emit_if_committed(action, {:ok, %{__struct__: schema, id: id}} = result) do
    committed = commit_verifier().get(schema, id)
    Status.recover(@commit_verification_degradation)
    if committed, do: emit_safely(action, result)
  rescue
    _exception -> degrade_commit_verification()
  catch
    _kind, _reason -> degrade_commit_verification()
  end

  defp commit_verifier do
    Application.get_env(:orchard_controller, :audit_commit_verifier_impl, Repo)
  end

  defp degrade_commit_verification do
    Status.degrade(@commit_verification_degradation)
    {:error, :metrics_degraded}
  end

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
  defp action_domain("circuit_breaker." <> _rest), do: {:ok, "circuit_breaker"}
  defp action_domain("portal_user." <> _rest), do: {:ok, "portal_user"}
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
