defmodule Orchard.Repo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :orchard_controller,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_context, config) do
    # Controller columns are `timestamptz` (SPEC.md §8.2), but Ecto still casts
    # some timestamp values to `timestamp without time zone`, which PostgreSQL
    # converts through the session zone. Pin it to UTC so a server configured
    # for local time cannot shift those values.
    parameters = config |> Keyword.get(:parameters, []) |> Keyword.put(:timezone, "UTC")
    {:ok, Keyword.put(config, :parameters, parameters)}
  end
end
