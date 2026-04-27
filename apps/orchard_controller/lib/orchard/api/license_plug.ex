defmodule Orchard.API.LicensePlug do
  @moduledoc """
  Gates public Orchard API product paths on the shared license state.

  The plug preserves the OpenAI-style public error envelope from SPEC.md §7.2.6
  and the 403 forbidden status from SPEC.md §7.2.7. Route exemptions are handled
  by mounting this plug only on product API pipelines.
  """

  @behaviour Plug

  alias Orchard.API.ErrorHelpers
  alias Orchard.Licensing.Gate

  @error_type "permission_error"

  @impl Plug
  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(conn, opts) do
    case Gate.check(opts) do
      :ok -> conn
      {:error, status} -> deny(conn, status)
    end
  end

  defp deny(conn, status) do
    denial = Gate.denial(status)
    message = denial.message <> " " <> denial.activation_guidance

    conn
    |> ErrorHelpers.send_error(:forbidden, message, @error_type, code: denial.code)
    |> Plug.Conn.halt()
  end
end
