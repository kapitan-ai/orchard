ExUnit.start()

# grpc >= 1.0 starts GRPC.Client.Supervisor from the :grpc application, so no
# test-only bootstrap is needed for tests using GRPC.Stub.connect/1.
{:ok, _} = Application.ensure_all_started(:grpc)
