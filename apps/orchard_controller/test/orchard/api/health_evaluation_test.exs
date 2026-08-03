defmodule Orchard.API.HealthEvaluationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Orchard.API.HealthEvaluation

  @moduletag capture_log: true

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

  defmodule PartialChecksReadiness do
    def status, do: {:ok, %{controller_boot_completed: true}}
  end

  defmodule ExtraChecksReadiness do
    def status do
      {:ok,
       %{
         postgres_reachable: true,
         migrations_current: true,
         public_api_https_enabled: true,
         controller_boot_completed: true,
         unexpected: true
       }}
    end
  end

  defmodule NonBooleanChecksReadiness do
    def status do
      {:ok,
       %{
         postgres_reachable: true,
         migrations_current: true,
         public_api_https_enabled: "true",
         controller_boot_completed: true
       }}
    end
  end

  defmodule InconsistentSuccessReadiness do
    def status do
      {:ok,
       %{
         postgres_reachable: false,
         migrations_current: true,
         public_api_https_enabled: true,
         controller_boot_completed: true
       }}
    end
  end

  defmodule InconsistentFailureReadiness do
    def status do
      {:error, :migrations_current,
       %{
         postgres_reachable: false,
         migrations_current: false,
         public_api_https_enabled: true,
         controller_boot_completed: true
       }}
    end
  end

  defmodule NilReasonAllPassingReadiness do
    def status do
      {:error, nil,
       %{
         postgres_reachable: true,
         migrations_current: true,
         public_api_https_enabled: true,
         controller_boot_completed: true
       }}
    end
  end

  defmodule BlockReadiness do
    def status do
      Process.sleep(60_000)
      {:ok, %{}}
    end
  end

  defmodule DelayedReadiness do
    def status do
      Process.sleep(50)

      {:ok,
       %{
         postgres_reachable: true,
         migrations_current: true,
         public_api_https_enabled: true,
         controller_boot_completed: true
       }}
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

  test "evaluate rejects a partial readiness checks map" do
    put_impl(PartialChecksReadiness)
    evaluation = HealthEvaluation.evaluate()

    assert evaluation.ready? == false
    assert evaluation.reason == :readiness_unavailable
  end

  test "evaluate rejects a readiness checks map with extra keys" do
    put_impl(ExtraChecksReadiness)
    evaluation = HealthEvaluation.evaluate()

    assert evaluation.ready? == false
    assert evaluation.reason == :readiness_unavailable
  end

  test "evaluate rejects a readiness checks map with non-boolean values" do
    put_impl(NonBooleanChecksReadiness)
    evaluation = HealthEvaluation.evaluate()

    assert evaluation.ready? == false
    assert evaluation.reason == :readiness_unavailable
  end

  test "evaluate rejects success with a failed readiness check" do
    put_impl(InconsistentSuccessReadiness)
    evaluation = HealthEvaluation.evaluate()

    assert evaluation.ready? == false
    assert evaluation.reason == :readiness_unavailable
  end

  test "evaluate rejects a failure with nil reason and all checks passing" do
    put_impl(NilReasonAllPassingReadiness)
    evaluation = HealthEvaluation.evaluate()

    assert evaluation.ready? == false
    assert evaluation.reason == :readiness_unavailable
  end

  test "evaluate rejects a failure reason that is not the first failed check" do
    put_impl(InconsistentFailureReadiness)
    evaluation = HealthEvaluation.evaluate()

    assert evaluation.ready? == false
    assert evaluation.reason == :readiness_unavailable
  end

  test "evaluate times out blocked readiness and returns unavailable" do
    evaluation = HealthEvaluation.evaluate_with(BlockReadiness, 25)

    assert evaluation.ready? == false
    assert evaluation.reason == :readiness_unavailable
  end

  test "evaluate uses the fixed production timeout despite an application override" do
    Application.put_env(:orchard_controller, :health,
      readiness_impl: DelayedReadiness,
      evaluation_timeout_ms: 1
    )

    evaluation = HealthEvaluation.evaluate()

    assert evaluation.ready? == true
    assert evaluation.reason == nil
  end

  test "public_response maps unavailable to exact error body" do
    assert HealthEvaluation.public_response(%{
             ready?: false,
             checks: %{},
             reason: :readiness_unavailable
           }) == {:service_unavailable, %{status: "error"}}
  end

  test "evaluate logs terminated timeout evidence" do
    log =
      capture_log(fn ->
        assert HealthEvaluation.evaluate_with(BlockReadiness, 25).reason ==
                 :readiness_unavailable
      end)

    assert log =~ "readiness unavailable, serving fail-closed health"
    assert log =~ "exceeded 25ms and was terminated"
  end

  test "evaluate logs invalid readiness shape evidence" do
    put_impl(PartialChecksReadiness)

    log =
      capture_log(fn ->
        assert HealthEvaluation.evaluate().reason == :readiness_unavailable
      end)

    assert log =~ "readiness check returned an invalid success"
    assert log =~ "controller_boot_completed"
  end

  test "evaluate logs readiness exit evidence" do
    put_impl(ExitReadiness)

    log =
      capture_log(fn ->
        assert HealthEvaluation.evaluate().reason == :readiness_unavailable
      end)

    assert log =~ "readiness check exited"
    assert log =~ "readiness_failed"
  end

  test "evaluate logs unexpected readiness result evidence" do
    put_impl(MalformedReadiness)

    log =
      capture_log(fn ->
        assert HealthEvaluation.evaluate().reason == :readiness_unavailable
      end)

    assert log =~ "readiness check returned an unexpected result"
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
