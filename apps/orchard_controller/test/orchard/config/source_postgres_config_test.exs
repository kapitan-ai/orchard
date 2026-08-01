defmodule Orchard.Config.SourcePostgresConfigTest do
  use ExUnit.Case, async: false

  @dev_config Path.expand("../../../../../config/dev.exs", __DIR__)
  @test_config Path.expand("../../../../../config/test.exs", __DIR__)
  @benchmark_config Path.expand("../../../../../config/benchmark.exs", __DIR__)

  @source_configs [
    {@dev_config, :dev},
    {@test_config, :test},
    {@benchmark_config, :benchmark}
  ]

  setup do
    snapshot =
      System.get_env()
      |> Enum.filter(fn {key, _value} -> config_env_key?(key) end)
      |> Map.new()

    on_exit(fn -> restore_config_env!(snapshot) end)

    :ok
  end

  test "source dev Controller applies PGPORT as an integer" do
    repo = read_repo_config!(@dev_config, :dev, %{"PGPORT" => "55432"})

    assert repo[:port] == 55_432
  end

  test "source database configurations default PGPORT to 5432" do
    Enum.each(@source_configs, fn {path, env} ->
      assert read_repo_config!(path, env, %{})[:port] == 5432
    end)
  end

  test "test and benchmark apply PGPORT as an integer" do
    Enum.each([{@test_config, :test}, {@benchmark_config, :benchmark}], fn {path, env} ->
      assert read_repo_config!(path, env, %{"PGPORT" => "55432"})[:port] == 55_432
    end)
  end

  test "source database port accepts inclusive boundaries and leading zeroes" do
    assert read_repo_config!(@dev_config, :dev, %{"PGPORT" => "1"})[:port] == 1
    assert read_repo_config!(@dev_config, :dev, %{"PGPORT" => "65535"})[:port] == 65_535
    assert read_repo_config!(@dev_config, :dev, %{"PGPORT" => "05432"})[:port] == 5432
  end

  test "source dev Controller rejects invalid PGPORT values" do
    invalid_values = ["", " ", "postgres", "+5432", "-5432", "5432x", "5432 ", "0", "65536"]

    Enum.each(invalid_values, fn value ->
      assert_raise RuntimeError,
                   ~r/PGPORT must be an unsigned decimal TCP port in 1\.\.65535/,
                   fn -> read_repo_config!(@dev_config, :dev, %{"PGPORT" => value}) end
    end)
  end

  test "test and benchmark reject invalid PGPORT values through the shared contract" do
    Enum.each([{@test_config, :test}, {@benchmark_config, :benchmark}], fn {path, env} ->
      assert_raise RuntimeError,
                   ~r/PGPORT must be an unsigned decimal TCP port in 1\.\.65535/,
                   fn -> read_repo_config!(path, env, %{"PGPORT" => "+5432"}) end
    end)
  end

  test "all-in-one source dev validates PGPORT" do
    assert_raise RuntimeError,
                 ~r/PGPORT must be an unsigned decimal TCP port in 1\.\.65535/,
                 fn ->
                   read_repo_config!(@dev_config, :dev, %{
                     "ORCHARD_SOURCE_DEV_ROLE" => "all_in_one",
                     "PGPORT" => "+5432"
                   })
                 end
  end

  defp read_repo_config!(path, env, overrides) do
    put_config_env!(overrides)

    path
    |> Config.Reader.read!(env: env)
    |> Keyword.fetch!(:orchard_controller)
    |> Keyword.fetch!(Orchard.Repo)
  end

  defp put_config_env!(env) do
    clear_config_env!()

    env
    |> Map.put_new("ORCHARD_SOURCE_DEV_ROLE", "controller")
    |> Map.put_new("ORCHARD_RUNTIME_ENDPOINT_TRANSPORT", "grpc")
    |> Enum.each(fn {key, value} -> System.put_env(key, value) end)
  end

  defp restore_config_env!(snapshot) do
    clear_config_env!()
    Enum.each(snapshot, fn {key, value} -> System.put_env(key, value) end)
  end

  defp clear_config_env! do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&config_env_key?/1)
    |> Enum.each(&System.delete_env/1)
  end

  defp config_env_key?(key) do
    key in [
      "DATABASE_URL",
      "MIX_RELEASE_NAME",
      "PGDATABASE",
      "PGDATABASE_BENCHMARK",
      "PGDATABASE_TEST",
      "PGHOST",
      "PGPASSWORD",
      "PGPORT",
      "PGUSER",
      "PORT",
      "RELEASE_NAME",
      "SECRET_KEY_BASE"
    ] or String.starts_with?(key, "ORCHARD_")
  end
end
