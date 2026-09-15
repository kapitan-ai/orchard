defmodule Orchard.BeamPeerGrants.ControlEndpoint do
  @moduledoc false

  use GRPC.Endpoint

  run(Orchard.BeamPeerGrants.ControlServer)
  run(Orchard.WorkerRecovery.ControlServer)
end
