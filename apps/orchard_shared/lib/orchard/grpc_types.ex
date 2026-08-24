defmodule Orchard.GRPCTypes do
  @moduledoc """
  Struct types for `grpc`/`grpc_server` values used in Orchard specs.

  `grpc` 1.0 dropped the `t/0` typespecs from `GRPC.Channel`, `GRPC.Credential`,
  and `GRPC.Server.Stream`, so Orchard owns the aliases its specs reference.
  """

  @type channel :: %GRPC.Channel{}
  @type credential :: %GRPC.Credential{}
  @type server_stream :: %GRPC.Server.Stream{}
end
