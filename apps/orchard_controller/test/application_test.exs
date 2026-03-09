defmodule OrchardApplicationTest do
  use ExUnit.Case, async: false

  setup do
    previous_env = %{
      start_repo: Application.get_env(:orchard_controller, :start_repo, true),
      start_endpoint: Application.get_env(:orchard_controller, :start_endpoint, true),
      enable_db_checks: Application.get_env(:orchard_controller, :enable_db_checks, true)
    }

    was_started = is_pid(Process.whereis(Orchard.Supervisor))

    stop_controller_app()

    Application.put_env(:orchard_controller, :start_repo, false)
    Application.put_env(:orchard_controller, :start_endpoint, false)
    Application.put_env(:orchard_controller, :enable_db_checks, false)

    on_exit(fn ->
      stop_controller_app()

      Application.put_env(:orchard_controller, :start_repo, previous_env.start_repo)
      Application.put_env(:orchard_controller, :start_endpoint, previous_env.start_endpoint)
      Application.put_env(:orchard_controller, :enable_db_checks, previous_env.enable_db_checks)

      if was_started do
        {:ok, _apps} = Application.ensure_all_started(:orchard_controller)
      end
    end)

    :ok
  end

  test "controller application boots without repo or endpoint children" do
    assert {:ok, _apps} = Application.ensure_all_started(:orchard_controller)

    supervisor = Process.whereis(Orchard.Supervisor)
    assert is_pid(supervisor)

    child_ids =
      Supervisor.which_children(supervisor)
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

    refute Orchard.Repo in child_ids
    refute Orchard.PubSub in child_ids
    refute Orchard.API.Endpoint in child_ids
  end

  defp stop_controller_app do
    case Application.stop(:orchard_controller) do
      :ok -> :ok
      {:error, {:not_started, :orchard_controller}} -> :ok
    end
  end
end
