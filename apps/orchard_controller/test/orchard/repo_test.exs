defmodule Orchard.RepoTest do
  use Orchard.DataCase, async: true

  test "Repo connections use the UTC session time zone" do
    assert %Postgrex.Result{rows: [["UTC"]]} = Repo.query!("SHOW TimeZone")
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
