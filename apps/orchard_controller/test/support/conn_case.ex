defmodule Orchard.ConnCase do
  @moduledoc false

  # Use ConnCase for controller/router tests. Add `@tag :db` to opt into the
  # SQL sandbox for request paths that touch Orchard.Repo.

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest

      @endpoint Orchard.API.Endpoint
    end
  end

  setup tags do
    previous_artifact_provider =
      Application.get_env(:orchard_controller, :scheduler_artifact_acquirable_provider)

    # Healthy-path API tests exercise admission/dispatch, not Model Hub layout.
    # Suites that need missing-artifact paths override this provider locally.
    Application.put_env(
      :orchard_controller,
      :scheduler_artifact_acquirable_provider,
      fn _request -> true end
    )

    on_exit(fn ->
      if is_nil(previous_artifact_provider) do
        Application.delete_env(:orchard_controller, :scheduler_artifact_acquirable_provider)
      else
        Application.put_env(
          :orchard_controller,
          :scheduler_artifact_acquirable_provider,
          previous_artifact_provider
        )
      end
    end)

    if tags[:db] do
      Orchard.DataCase.setup_sandbox(tags)
    end

    if tags[:live] do
      start_supervised!(Orchard.API.Endpoint)
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
