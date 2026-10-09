defmodule Orchard.RepoTest do
  use Orchard.DataCase, async: true

  test "Repo connections use the UTC session time zone" do
    assert %Postgrex.Result{rows: [["UTC"]]} = Repo.query!("SHOW TimeZone")
  end

  test "SPEC.md §8.2 Controller timestamp columns are timestamptz" do
    %Postgrex.Result{rows: rows} =
      Repo.query!("""
      SELECT table_name || '.' || column_name
      FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND data_type = 'timestamp without time zone'
        AND table_name <> 'schema_migrations'
      ORDER BY 1
      """)

    assert rows == []
  end

  test "Repo init pins the UTC session time zone and keeps other parameters" do
    assert {:ok, config} =
             Repo.init(:runtime,
               parameters: [application_name: "orchard_test", timezone: "Asia/Singapore"]
             )

    parameters = Keyword.fetch!(config, :parameters)
    assert Keyword.get_values(parameters, :timezone) == ["UTC"]
    assert Keyword.fetch!(parameters, :application_name) == "orchard_test"
  end
end
