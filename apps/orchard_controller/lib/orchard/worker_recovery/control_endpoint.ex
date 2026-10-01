defmodule Orchard.WorkerRecovery.ControlEndpoint do
  @moduledoc false

  use GRPC.Endpoint

  run(Orchard.WorkerRecovery.ControlServer)
end
