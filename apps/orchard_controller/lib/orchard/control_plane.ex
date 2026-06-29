defmodule Orchard.ControlPlane do
  @moduledoc """
  Small control-plane write gate for leader-only mutation paths.
  """

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

  defp configured_role do
    :orchard_controller
    |> Application.get_env(:control_plane, [])
    |> Keyword.get(:role, :single_controller)
  end
end
