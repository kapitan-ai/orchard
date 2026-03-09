defmodule Orchard.Node.Endpoint do
  @moduledoc false

  use GRPC.Endpoint

  run(Orchard.Node.RuntimeServer)
end
