defmodule Orchard.API.HealthEvaluation do
  @moduledoc false

  require Logger

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
    normalize_result(result, timeout_ms)
  rescue
    error -> unavailable("readiness evaluation raised: " <> bounded(error))
  catch
    kind, reason -> unavailable("readiness evaluation caught #{kind}: " <> bounded(reason))
  end

  defp normalize_result({:ok, {:ok, checks}}, _timeout_ms) when is_map(checks) do
    if valid_success?(checks),
      do: %{ready?: true, checks: checks, reason: nil},
      else: unavailable("readiness check returned an invalid success: " <> bounded(checks))
  end

  defp normalize_result({:ok, {:error, reason, checks}}, _timeout_ms)
       when is_atom(reason) and is_map(checks) do
    if valid_failure?(reason, checks),
      do: %{ready?: false, checks: checks, reason: reason},
      else:
        unavailable("readiness check returned an invalid failure: " <> bounded({reason, checks}))
  end

  defp normalize_result(nil, timeout_ms) do
    unavailable("readiness check exceeded #{timeout_ms}ms and was terminated")
  end

  defp normalize_result({:exit, reason}, _timeout_ms) do
    unavailable("readiness check exited: " <> bounded(reason))
  end

  defp normalize_result(other, _timeout_ms) do
    unavailable("readiness check returned an unexpected result: " <> bounded(other))
  end

  @spec public_response(t()) :: {Plug.Conn.status(), %{required(:status) => String.t()}}
  def public_response(%{ready?: true}), do: {:ok, %{status: "ok"}}
  def public_response(%{ready?: false}), do: {:service_unavailable, %{status: "error"}}

  defp unavailable(cause) when is_binary(cause) do
    Logger.warning("readiness unavailable, serving fail-closed health: " <> cause)
    %{ready?: false, checks: %{}, reason: :readiness_unavailable}
  end

  defp bounded(term), do: inspect(term, limit: 5, printable_limit: 256)

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
