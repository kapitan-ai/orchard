defmodule Orchard.ControlPlane do
  @moduledoc """
  Small control-plane write gate for leader-only mutation paths.
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
    role = normalized_role(configured_role())

    HALiteStatus.new!(%{
      deployment_mode: deployment_mode(role),
      controller_role: role,
      advisory_lock_status: :unknown,
      standby_write_path_behavior: standby_write_path_behavior(role)
    })
  end

  defp configured_role do
    :orchard_controller
    |> Application.get_env(:control_plane, [])
    |> Keyword.get(:role, :single_controller)
  end

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
