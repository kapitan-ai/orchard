defmodule Orchard.RuntimeEndpoint.ObservationBounds do
  @moduledoc "Shared structural bounds for Runtime Endpoint observations."

  @placement_limit 40

  @doc "Returns the maximum number of placement observations in one bounded projection."
  @spec placement_limit() :: pos_integer()
  def placement_limit, do: @placement_limit
end
