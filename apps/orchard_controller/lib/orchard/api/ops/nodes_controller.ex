defmodule Orchard.API.Ops.NodesController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Orchard.API.AdminErrorHelpers
  alias Orchard.ClusterManagement.Reads
  alias Orchard.ControlPlane

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params), do: read(conn, fn -> {:ok, Reads.nodes()} end)

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"node_id" => node_id}) do
    read(conn, fn -> Reads.node(node_id, latest_decision: :operator) end)
  end

  defp read(conn, build) do
    with :ok <- ControlPlane.authorize_write_path(:node_inspection),
         {:ok, payload} <- build.() do
      json(conn, payload)
    else
      {:error, reason} -> send_error(conn, reason)
    end
  rescue
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      Logger.warning("Operator Node inventory read failed: #{Exception.message(error)}")
      send_error(conn, :database_unavailable)
  end

  defp send_error(conn, :node_not_found) do
    AdminErrorHelpers.send_error(conn, :not_found, "node_not_found", "Node was not found.")
  end

  defp send_error(conn, reason) do
    AdminErrorHelpers.send_error(
      conn,
      :service_unavailable,
      Atom.to_string(reason),
      message(reason)
    )
  end

  defp message(:controller_standby), do: "This controller is in standby mode."

  defp message(:controller_leadership_unproven),
    do: "This controller has not proven local leadership."

  defp message(:database_unavailable), do: "The database is unavailable."
end
