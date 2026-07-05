defmodule Orchard.ControlPlane do
  @moduledoc """
  Small control-plane write gate for leader-only mutation paths, plus read-only
  Active/Standby control-plane status.
  """

  alias Orchard.ClusterManagement.ControlPlaneStatus
  alias Orchard.ClusterManagement.Value

  @provider_status_keys [
    :leader_identity,
    :advisory_lock_status,
    :lock_age_ms,
    :last_renewed_at,
    :last_observed_leadership_error
  ]

  @stable_leadership_errors [
    "advisory_lock_read_failed: db_connection_error",
    "advisory_lock_read_failed: invalid_provider_status",
    "advisory_lock_read_failed: unexpected_provider_result",
    "advisory_lock_read_failed: provider_error",
    "advisory_lock_read_failed: provider_reported_error"
  ]

  @type write_path :: atom()
  @type write_error :: :controller_standby | :controller_leadership_unproven

  @spec authorize_write_path(write_path()) :: :ok | {:error, write_error()}
  def authorize_write_path(_path) do
    case normalized_role(configured_role()) do
      :standby -> {:error, :controller_standby}
      :leader -> authorize_active_standby_leader()
      _role -> :ok
    end
  end

  @spec read_only_status() :: ControlPlaneStatus.t()
  def read_only_status do
    config = control_plane_config()
    role = normalized_role(Keyword.get(config, :role, :single_controller))

    base_attrs = %{
      deployment_mode: deployment_mode(role),
      this_controller_identity: Keyword.get(config, :this_controller_identity),
      controller_role: role,
      advisory_lock_status: :unknown,
      standby_write_path_behavior: standby_write_path_behavior(role)
    }

    base_attrs
    |> Map.merge(provider_status(config, base_attrs))
    |> normalize_unproven_leadership()
    |> ControlPlaneStatus.new!()
  end

  defp configured_role do
    control_plane_config()
    |> Keyword.get(:role, :single_controller)
  end

  defp authorize_active_standby_leader do
    case read_only_status() do
      %ControlPlaneStatus{deployment_mode: "active_standby", controller_role: "leader"} -> :ok
      _status -> {:error, :controller_leadership_unproven}
    end
  end

  defp control_plane_config do
    Application.get_env(:orchard_controller, :control_plane, [])
  end

  defp provider_status(config, base_attrs) do
    case Keyword.get(config, :control_plane_status_provider) do
      nil -> %{}
      provider -> provider |> read_provider_status() |> normalize_provider_status(base_attrs)
    end
  rescue
    exception -> unavailable_status(exception)
  catch
    _kind, _reason -> unavailable_status(:provider_error)
  end

  defp read_provider_status(provider) when is_function(provider, 0), do: provider.()

  defp read_provider_status({module, function, args}) when is_list(args),
    do: apply(module, function, args)

  defp read_provider_status(provider),
    do: {:error, {:invalid_control_plane_status_provider, inspect(provider)}}

  defp normalize_provider_status({:ok, %{} = attrs}, base_attrs),
    do: attrs |> provider_advisory_lock_attrs() |> validate_provider_status(base_attrs)

  defp normalize_provider_status(%{} = attrs, base_attrs),
    do: attrs |> provider_advisory_lock_attrs() |> validate_provider_status(base_attrs)

  defp normalize_provider_status({:error, _reason}, _base_attrs),
    do: unavailable_status(:provider_error)

  defp normalize_provider_status(_other, _base_attrs),
    do: unavailable_status(:unexpected_provider_result)

  defp provider_advisory_lock_attrs(attrs) do
    Map.new(@provider_status_keys, fn key -> {key, provider_attr(attrs, key)} end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> sanitize_leadership_error()
  end

  defp sanitize_leadership_error(%{last_observed_leadership_error: error} = attrs) do
    case stable_leadership_error(error) do
      nil -> Map.delete(attrs, :last_observed_leadership_error)
      reason -> Map.put(attrs, :last_observed_leadership_error, reason)
    end
  end

  defp sanitize_leadership_error(attrs), do: attrs

  defp stable_leadership_error(error) do
    case Value.normalize_string(error) do
      nil -> nil
      normalized when normalized in @stable_leadership_errors -> normalized
      _raw -> "advisory_lock_read_failed: provider_reported_error"
    end
  end

  defp validate_provider_status(attrs, base_attrs) do
    base_attrs
    |> Map.merge(attrs)
    |> normalize_unproven_leadership()
    |> ControlPlaneStatus.new()
    |> case do
      {:ok, _status} -> attrs
      {:error, _reason} -> unavailable_status(:invalid_provider_status)
    end
  end

  defp provider_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp unavailable_status(reason) do
    %{
      advisory_lock_status: :unavailable,
      leader_identity: nil,
      lock_age_ms: nil,
      last_renewed_at: nil,
      last_observed_leadership_error: leadership_error_reason(reason)
    }
  end

  defp leadership_error_reason(%DBConnection.ConnectionError{}),
    do: "advisory_lock_read_failed: db_connection_error"

  defp leadership_error_reason(:invalid_provider_status),
    do: "advisory_lock_read_failed: invalid_provider_status"

  defp leadership_error_reason(:unexpected_provider_result),
    do: "advisory_lock_read_failed: unexpected_provider_result"

  defp leadership_error_reason(_reason), do: "advisory_lock_read_failed: provider_error"

  defp normalize_unproven_leadership(%{deployment_mode: :active_standby} = attrs) do
    role = normalized_role(Map.get(attrs, :controller_role, :unknown))
    lock_status = normalize_lock_status(Map.get(attrs, :advisory_lock_status, :unknown))

    if role == :leader and not local_leadership_proven?(attrs, lock_status) do
      attrs
      |> Map.put(:controller_role, :unknown)
      |> Map.put(:standby_write_path_behavior, "unknown")
    else
      attrs
    end
  end

  defp normalize_unproven_leadership(attrs), do: attrs

  defp local_leadership_proven?(attrs, :held) do
    leader_identity = status_identity(Map.get(attrs, :leader_identity))
    this_controller_identity = status_identity(Map.get(attrs, :this_controller_identity))

    is_nil(leader_identity) or leader_identity == this_controller_identity
  end

  defp local_leadership_proven?(_attrs, _lock_status), do: false

  defp status_identity(nil), do: nil

  defp status_identity(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      identity -> identity
    end
  end

  defp normalize_lock_status(:held), do: :held
  defp normalize_lock_status("held"), do: :held
  defp normalize_lock_status(:not_held), do: :not_held
  defp normalize_lock_status("not_held"), do: :not_held
  defp normalize_lock_status(:unavailable), do: :unavailable
  defp normalize_lock_status("unavailable"), do: :unavailable
  defp normalize_lock_status(_status), do: :unknown

  defp normalized_role(:leader), do: :leader
  defp normalized_role("leader"), do: :leader
  defp normalized_role(:standby), do: :standby
  defp normalized_role("standby"), do: :standby
  defp normalized_role(:single_controller), do: :single_controller
  defp normalized_role("single_controller"), do: :single_controller
  defp normalized_role(_role), do: :unknown

  defp deployment_mode(:leader), do: :active_standby
  defp deployment_mode(:standby), do: :active_standby
  defp deployment_mode(:single_controller), do: :single_controller
  defp deployment_mode(_role), do: :unknown

  defp standby_write_path_behavior(:standby), do: "writes_return_503_controller_standby"
  defp standby_write_path_behavior(_role), do: "writes_allowed_when_authorized"
end
