defmodule Orchard.ControlPlane do
  @moduledoc """
  Small control-plane write gate for leader-only mutation paths, plus read-only
  HA-lite control-plane status.
  """

  alias Orchard.ClusterManagement.HALiteStatus

  @type write_path :: atom()
  @type write_error :: :controller_standby

  @spec authorize_write_path(write_path()) :: :ok | {:error, write_error()}
  def authorize_write_path(_path) do
    case configured_role() do
      :standby -> {:error, :controller_standby}
      "standby" -> {:error, :controller_standby}
      _role -> :ok
    end
  end

  @spec read_only_status() :: HALiteStatus.t()
  def read_only_status do
    config = control_plane_config()
    role = normalized_role(Keyword.get(config, :role, :single_controller))

    %{
      deployment_mode: deployment_mode(role),
      this_controller_identity: Keyword.get(config, :this_controller_identity),
      controller_role: role,
      advisory_lock_status: :unknown,
      standby_write_path_behavior: standby_write_path_behavior(role)
    }
    |> Map.merge(provider_status(config))
    |> normalize_unproven_leadership()
    |> HALiteStatus.new!()
  end

  defp configured_role do
    control_plane_config()
    |> Keyword.get(:role, :single_controller)
  end

  defp control_plane_config do
    Application.get_env(:orchard_controller, :control_plane, [])
  end

  defp provider_status(config) do
    case Keyword.get(config, :ha_lite_status_provider) do
      nil -> %{}
      provider -> provider |> read_provider_status() |> normalize_provider_status()
    end
  rescue
    exception -> unavailable_status(Exception.message(exception))
  catch
    kind, reason -> unavailable_status("#{kind}: #{inspect(reason)}")
  end

  defp read_provider_status(provider) when is_function(provider, 0), do: provider.()

  defp read_provider_status({module, function, args}) when is_list(args),
    do: apply(module, function, args)

  defp read_provider_status(provider),
    do: {:error, {:invalid_ha_lite_status_provider, inspect(provider)}}

  defp normalize_provider_status({:ok, %{} = attrs}), do: attrs
  defp normalize_provider_status(%{} = attrs), do: attrs
  defp normalize_provider_status({:error, reason}), do: unavailable_status(inspect(reason))

  defp normalize_provider_status(other),
    do: unavailable_status("unexpected provider result: #{inspect(other)}")

  defp unavailable_status(message) do
    %{
      advisory_lock_status: :unavailable,
      leader_identity: nil,
      lock_age_ms: nil,
      last_renewed_at: nil,
      last_observed_leadership_error: message
    }
  end

  defp normalize_unproven_leadership(%{deployment_mode: :ha_lite} = attrs) do
    role = normalized_role(Map.get(attrs, :controller_role, :unknown))
    lock_status = normalize_lock_status(Map.get(attrs, :advisory_lock_status, :unknown))

    if role == :leader and lock_status != :held do
      attrs
      |> Map.put(:controller_role, :unknown)
      |> Map.put(:standby_write_path_behavior, "unknown")
    else
      attrs
    end
  end

  defp normalize_unproven_leadership(attrs), do: attrs

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

  defp deployment_mode(:leader), do: :ha_lite
  defp deployment_mode(:standby), do: :ha_lite
  defp deployment_mode(:single_controller), do: :single_controller
  defp deployment_mode(_role), do: :unknown

  defp standby_write_path_behavior(:standby), do: "writes_return_503_controller_standby"
  defp standby_write_path_behavior(_role), do: "writes_allowed_when_authorized"
end
