defmodule Orchard.Config.SourceInferenceBudgetConfigTest do
  use ExUnit.Case, async: false

  @dev_config Path.expand("../../../../../config/dev.exs", __DIR__)
  @budgets [
    {"ORCHARD_REQUEST_TIMEOUT_MS", :orchard_controller, :inference, :request_timeout_ms, 120_000,
     1_800_000},
    {"ORCHARD_MAX_REQUEST_DEADLINE_MS", :orchard_controller, :inference, :max_request_deadline_ms,
     360_000, 1_800_000},
    {"ORCHARD_WORKER_READY_TIMEOUT_MS", :orchard_node_agent, :runtime, :worker_ready_timeout_ms,
     5_000, 30_000},
    {"ORCHARD_WORKER_LOAD_TIMEOUT_MS", :orchard_node_agent, :runtime, :worker_load_timeout_ms,
     120_000, 240_000}
  ]

  setup do
    snapshot = System.get_env() |> Enum.filter(&config_env?/1) |> Map.new()

    on_exit(fn ->
      clear_config_env!()
      Enum.each(snapshot, fn {key, value} -> System.put_env(key, value) end)
    end)

    :ok
  end

  test "source roles retain default budgets unless explicitly configured" do
    for role <- ~w(controller node_agent all_in_one) do
      config = read_config!(role, %{})

      for {_env, app, section, key, default, _selected} <- @budgets do
        assert config |> get_in([app, section]) |> Keyword.fetch!(key) == default
      end
    end
  end

  test "source roles apply selected request, ceiling, readiness and load budgets" do
    overrides = Map.new(@budgets, fn {env, _, _, _, _, value} -> {env, to_string(value)} end)

    for role <- ~w(controller node_agent all_in_one) do
      config = read_config!(role, overrides)

      for {_env, app, section, key, _default, selected} <- @budgets do
        assert config |> get_in([app, section]) |> Keyword.fetch!(key) == selected
      end
    end
  end

  test "invalid operator budgets fail before source startup" do
    for {env, _app, _section, _key, _default, _selected} <- @budgets,
        value <- ["", "0", "-1", "1.5", "30000ms", " "] do
      assert_raise RuntimeError, ~r/#{env}/, fn ->
        read_config!("all_in_one", %{env => value})
      end
    end
  end

  test "positive one millisecond is accepted with a coherent request and ceiling pair" do
    for {env, app, section, key, _default, _selected} <- @budgets do
      config =
        read_config!("all_in_one", %{
          "ORCHARD_REQUEST_TIMEOUT_MS" => "1",
          "ORCHARD_MAX_REQUEST_DEADLINE_MS" => "1",
          env => "1"
        })

      assert config |> get_in([app, section]) |> Keyword.fetch!(key) == 1
    end
  end

  test "crossed request and ceiling budgets fail before source startup" do
    for role <- ~w(controller node_agent all_in_one),
        overrides <- [
          %{"ORCHARD_REQUEST_TIMEOUT_MS" => "1800000"},
          %{"ORCHARD_MAX_REQUEST_DEADLINE_MS" => "1"},
          %{"ORCHARD_REQUEST_TIMEOUT_MS" => "1001", "ORCHARD_MAX_REQUEST_DEADLINE_MS" => "1000"}
        ] do
      assert_raise RuntimeError,
                   ~r/ORCHARD_REQUEST_TIMEOUT_MS.*must be <= ORCHARD_MAX_REQUEST_DEADLINE_MS/,
                   fn -> read_config!(role, overrides) end
    end
  end

  defp read_config!(role, overrides) do
    clear_config_env!()

    overrides
    |> Map.put("ORCHARD_SOURCE_DEV_ROLE", role)
    |> Map.put("ORCHARD_RUNTIME_ENDPOINT_TRANSPORT", "grpc")
    |> Enum.each(fn {key, value} -> System.put_env(key, value) end)

    Config.Reader.read!(@dev_config, env: :dev)
  end

  defp clear_config_env! do
    System.get_env()
    |> Enum.filter(&config_env?/1)
    |> Enum.each(fn {key, _} -> System.delete_env(key) end)
  end

  defp config_env?({key, _value}) do
    String.starts_with?(key, ["ORCHARD_", "PG"]) or
      key in ~w(DATABASE_URL MIX_RELEASE_NAME PORT RELEASE_NAME SECRET_KEY_BASE)
  end
end
