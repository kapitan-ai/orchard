ExUnit.start()

case Process.whereis(GRPC.Client.Supervisor) do
  nil ->
    {:ok, _pid} =
      DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)

  _pid ->
    :ok
end
