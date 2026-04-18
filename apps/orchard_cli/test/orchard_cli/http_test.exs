defmodule OrchardCLI.HTTPTest do
  use ExUnit.Case, async: false

  alias OrchardCLI.HTTP

  setup do
    req_started? = app_started?(:req)
    finch_started? = app_started?(:finch)

    stop_app_if_started(:req)
    stop_app_if_started(:finch)

    on_exit(fn ->
      restore_app_state(req_started?, finch_started?)
    end)

    :ok
  end

  test "request/2 starts req and finch when called from cold state" do
    assert Process.whereis(Req.FinchSupervisor) == nil

    assert {:ok, %Req.Response{status: 200, body: "ok"}} =
             HTTP.request(
               url: "http://orchard.test/health",
               method: :get,
               adapter: &stub_adapter/1
             )

    assert is_pid(Process.whereis(Req.FinchSupervisor))
  end

  test "request/2 is idempotent when req is already started" do
    req_opts = [url: "http://orchard.test/ping", method: :get, adapter: &stub_adapter/1]

    assert {:ok, %Req.Response{status: 200, body: "ok"}} = HTTP.request(req_opts)

    finch_supervisor = Process.whereis(Req.FinchSupervisor)
    assert is_pid(finch_supervisor)

    assert {:ok, %Req.Response{status: 200, body: "ok"}} = HTTP.request(req_opts)
    assert Process.whereis(Req.FinchSupervisor) == finch_supervisor
  end

  defp stub_adapter(request) do
    {request, %Req.Response{status: 200, headers: %{}, body: "ok", trailers: %{}, private: %{}}}
  end

  defp app_started?(app) do
    Enum.any?(Application.started_applications(), fn {started_app, _, _} -> started_app == app end)
  end

  defp stop_app_if_started(app) do
    case Application.stop(app) do
      :ok -> :ok
      {:error, {:not_started, _app}} -> :ok
    end
  end

  defp restore_app_state(req_started?, finch_started?) do
    cond do
      req_started? ->
        Application.ensure_all_started(:req)
        :ok

      finch_started? ->
        Application.ensure_all_started(:finch)
        :ok

      true ->
        stop_app_if_started(:req)
        stop_app_if_started(:finch)
    end
  end
end
