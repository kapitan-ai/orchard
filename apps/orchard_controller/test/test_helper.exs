ExUnit.start()

case Process.whereis(Orchard.Repo) do
  nil ->
    {:ok, _pid} = Orchard.Repo.start_link()

  _pid ->
    :ok
end

Ecto.Adapters.SQL.Sandbox.mode(Orchard.Repo, :manual)
