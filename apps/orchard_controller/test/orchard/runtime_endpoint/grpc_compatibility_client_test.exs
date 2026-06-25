defmodule Orchard.RuntimeEndpoint.GrpcCompatibilityClientTest do
  use ExUnit.Case, async: true

  alias Orchard.RuntimeEndpoint.{GrpcCompatibilityClient, Target}

  test "connect rejects unsupported runtime endpoint target transports" do
    target = Target.beam("550e8400-e29b-41d4-a716-446655440000", address: :node_one)

    assert {:error, {:unsupported_transport, :beam}} = GrpcCompatibilityClient.connect(target)
  end
end
