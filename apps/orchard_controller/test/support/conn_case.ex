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
    if tags[:db] do
      Orchard.DataCase.setup_sandbox(tags)
    end

    if tags[:live] do
      start_supervised!(Orchard.API.Endpoint)
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
