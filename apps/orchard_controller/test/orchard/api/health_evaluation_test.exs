defmodule Orchard.API.HealthEvaluationTest do
  use ExUnit.Case, async: false

  alias Orchard.API.HealthEvaluation

  defmodule RaiseReadiness do
    def status, do: raise("readiness secret")
  end

  defmodule ExitReadiness do
    def status, do: exit(:readiness_failed)
  end

  defmodule ThrowReadiness do
    def status, do: throw(:readiness_failed)
  end

  defmodule MalformedReadiness do
    def status, do: :not_a_tuple
  end

  defmodule BlockReadiness do
    def status do
      Process.sleep(60_000)
      {:ok, %{}}
    end
  end

  defmodule OkReadiness do
    def status do
      {:ok,
       %{
         postgres_reachable: true,
         migrations_current: true,
         public_api_https_enabled: true,
         controller_boot_completed: true
       }}
    end
  end

  setup do
    previous = Application.get_env(:orchard_controller, :health, [])

    on_exit(fn ->
      Application.put_env(:orchard_controller, :health, previous)
    end)

    :ok
  end

  test "evaluate normalizes readiness raise to unavailable" do
    put_impl(RaiseReadiness)
    evaluation = HealthEvaluation.evaluate()

    assert evaluation.ready? == false
    assert evaluation.reason == :readiness_unavailable
    refute evaluation |> inspect() |> String.contains?("secret")
  end

  test "evaluate normalizes readiness exit to unavailable" do
    put_impl(ExitReadiness)
    evaluation = HealthEvaluation.evaluate()

    assert evaluation.ready? == false
    assert evaluation.reason == :readiness_unavailable
  end

  test "evaluate normalizes readiness throw to unavailable" do
    put_impl(ThrowReadiness)
    evaluation = HealthEvaluation.evaluate()

    assert evaluation.ready? == false
    assert evaluation.reason == :readiness_unavailable
  end

  test "evaluate normalizes malformed readiness return to unavailable" do
    put_impl(MalformedReadiness)
    evaluation = HealthEvaluation.evaluate()

    assert evaluation.ready? == false
    assert evaluation.reason == :readiness_unavailable
  end

  test "evaluate times out blocked readiness and returns unavailable" do
    put_impl(BlockReadiness)

    Application.put_env(:orchard_controller, :health,
      readiness_impl: BlockReadiness,
      evaluation_timeout_ms: 25
    )

    evaluation = HealthEvaluation.evaluate()

    assert evaluation.ready? == false
    assert evaluation.reason == :readiness_unavailable
  end

  test "public_response maps unavailable to exact error body" do
    assert HealthEvaluation.public_response(%{
             ready?: false,
             checks: %{},
             reason: :readiness_unavailable
           }) == {:service_unavailable, %{status: "error"}}
  end

  test "evaluate still accepts ordinary success" do
    put_impl(OkReadiness)
    evaluation = HealthEvaluation.evaluate()

    assert evaluation.ready? == true
    assert evaluation.reason == nil
  end

  defp put_impl(mod) do
    Application.put_env(:orchard_controller, :health, readiness_impl: mod)
  end
end
