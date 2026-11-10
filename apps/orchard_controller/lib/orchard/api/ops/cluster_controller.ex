defmodule Orchard.API.Ops.ClusterController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Orchard.ClusterManagement.Reads

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params), do: json(conn, Reads.cluster_status())
end
