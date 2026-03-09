defmodule Orchard.DataCaseTest do
  use Orchard.DataCase, async: true

  test "data case checks out the sandboxed repo" do
    assert %Postgrex.Result{rows: [[1]]} = Repo.query!("SELECT 1")
  end
end
