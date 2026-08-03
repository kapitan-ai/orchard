defmodule Orchard.API.HealthEvaluation do
  @moduledoc false

  alias Orchard.API.Readiness

  @default_timeout_ms 5_000
  @task_supervisor Orchard.API.HealthTaskSupervisor

  @type t :: %{
          required(:ready?) => boolean(),
          required(:checks) => map(),
          required(:reason) => atom() | nil
        }

  @spec evaluate() :: t()
  def evaluate do
    evaluate_with(readiness_impl(), @default_timeout_ms)
  end

  @doc false
  @spec evaluate_with(module(), pos_integer()) :: t()
  def evaluate_with(impl, timeout_ms)
      when is_atom(impl) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        impl.status()
      end)

    result = Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill)
    normalize_result(result)
  rescue
    _ -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  defp normalize_result({:ok, {:ok, checks}}) when is_map(checks) do
    if valid_success?(checks),
      do: %{ready?: true, checks: checks, reason: nil},
      else: unavailable()
  end

  defp normalize_result({:ok, {:error, reason, checks}})
       when is_atom(reason) and is_map(checks) do
    if valid_failure?(reason, checks),
      do: %{ready?: false, checks: checks, reason: reason},
      else: unavailable()
  end

  defp normalize_result(_other), do: unavailable()

  @spec public_response(t()) :: {Plug.Conn.status(), %{required(:status) => String.t()}}
  def public_response(%{ready?: true}), do: {:ok, %{status: "ok"}}
  def public_response(%{ready?: false}), do: {:service_unavailable, %{status: "error"}}

  defp unavailable do
    %{ready?: false, checks: %{}, reason: :readiness_unavailable}
  end

  defp valid_success?(checks) do
    valid_checks?(checks) and Enum.all?(checks, fn {_check, passed?} -> passed? end)
  end

  defp valid_failure?(reason, checks) do
    not is_nil(reason) and valid_checks?(checks) and
      Enum.find(Readiness.check_order(), &(Map.fetch!(checks, &1) == false)) == reason
  end

  defp valid_checks?(checks) do
    check_order = Readiness.check_order()

    map_size(checks) == length(check_order) and
      Enum.all?(check_order, &is_boolean(Map.get(checks, &1)))
  end

  defp readiness_impl do
    :orchard_controller
    |> Application.get_env(:health, [])
    |> Keyword.get(:readiness_impl, Readiness)
  end
end
