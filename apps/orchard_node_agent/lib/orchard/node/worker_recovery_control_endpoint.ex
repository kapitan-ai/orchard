defmodule Orchard.Node.WorkerRecoveryControlEndpoint do
  @moduledoc "Recovery-only listener when ordinary gRPC runtime operations are disabled."
  use GRPC.Endpoint
  run(Orchard.Node.WorkerRecoveryControlServer)
end
