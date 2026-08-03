defmodule Orchard.API.HealthEvaluation do
  @moduledoc false

  alias Orchard.API.Readiness

  @default_timeout_ms 5_000
  @min_timeout_ms 1
  @task_supervisor Orchard.API.HealthTaskSupervisor

  @type t :: %{
          required(:ready?) => boolean(),
          required(:checks) => map(),
          required(:reason) => atom() | nil
        }

  @spec evaluate() :: t()
  def evaluate do
    evaluate_with(readiness_impl(), evaluation_timeout_ms())
  end

  @doc false
  @spec evaluate_with(module(), pos_integer()) :: t()
  def evaluate_with(impl, timeout_ms)
      when is_atom(impl) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        impl.status()
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, checks}} when is_map(checks) ->
        %{ready?: true, checks: checks, reason: nil}

      {:ok, {:error, reason, checks}} when is_atom(reason) and is_map(checks) ->
        %{ready?: false, checks: checks, reason: reason}

      _other ->
        unavailable()
    end
  rescue
    _ -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  @spec public_response(t()) :: {Plug.Conn.status(), %{required(:status) => String.t()}}
  def public_response(%{ready?: true}), do: {:ok, %{status: "ok"}}
  def public_response(%{ready?: false}), do: {:service_unavailable, %{status: "error"}}

  defp unavailable do
    %{ready?: false, checks: %{}, reason: :readiness_unavailable}
  end

  defp readiness_impl do
    :orchard_controller
    |> Application.get_env(:health, [])
    |> Keyword.get(:readiness_impl, Readiness)
  end

  defp evaluation_timeout_ms do
    configured =
      :orchard_controller
      |> Application.get_env(:health, [])
      |> Keyword.get(:evaluation_timeout_ms, @default_timeout_ms)

    if is_integer(configured) and configured >= @min_timeout_ms do
      configured
    else
      @default_timeout_ms
    end
  end
end
