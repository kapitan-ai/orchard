defmodule Orchard.Repo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :orchard_controller,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_context, config) do
    # `:utc_datetime_usec` columns are `timestamp without time zone`, so PostgreSQL
    # converts database clock values through the session zone. Pin it to UTC
    # so a server configured for local time cannot shift those comparisons.
    parameters = config |> Keyword.get(:parameters, []) |> Keyword.put(:timezone, "UTC")
    {:ok, Keyword.put(config, :parameters, parameters)}
  end
end
