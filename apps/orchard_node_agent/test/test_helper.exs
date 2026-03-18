ExUnit.start()

# WORKAROUND: Pre-start GRPC.Client.Supervisor if not already running.
# This is test-only bootstrap so tests using GRPC.Stub.connect/1 don't
# fail when the supervisor isn't yet available. It does NOT prove that
# the application supervision tree is correct — orchard_node_agent_test.exs
# explicitly asserts GRPC.Client.Supervisor ownership under NodeSupervisor.
case Process.whereis(GRPC.Client.Supervisor) do
  nil ->
    {:ok, _pid} =
      DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)

  _pid ->
    :ok
end
