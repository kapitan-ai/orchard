defmodule Orchard.Repo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :orchard_controller,
    adapter: Ecto.Adapters.Postgres
end
