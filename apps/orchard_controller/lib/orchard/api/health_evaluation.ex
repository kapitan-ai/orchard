defmodule Orchard.API.HealthEvaluation do
  @moduledoc false

  alias Orchard.API.Readiness

  @type t :: %{
          required(:ready?) => boolean(),
          required(:checks) => Readiness.checks(),
          required(:reason) => atom() | nil
        }

  @spec evaluate() :: t()
  def evaluate do
    case Readiness.status() do
      {:ok, checks} -> %{ready?: true, checks: checks, reason: nil}
      {:error, reason, checks} -> %{ready?: false, checks: checks, reason: reason}
    end
  end

  @spec public_response(t()) :: {Plug.Conn.status(), %{required(:status) => String.t()}}
  def public_response(%{ready?: true}), do: {:ok, %{status: "ok"}}
  def public_response(%{ready?: false}), do: {:service_unavailable, %{status: "error"}}
end
