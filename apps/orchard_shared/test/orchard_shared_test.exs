defmodule OrchardSharedTest do
  use ExUnit.Case, async: true

  test "exposes a version string" do
    assert is_binary(OrchardShared.version())
  end
end
