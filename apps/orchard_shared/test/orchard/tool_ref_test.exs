defmodule Orchard.ToolRefTest do
  use ExUnit.Case, async: true

  alias Orchard.ToolRef

  describe "parse/1" do
    test "parses valid tool refs" do
      assert {:ok, "lookup_docs", "2026-04-11"} = ToolRef.parse("tool://lookup_docs@2026-04-11")
    end

    test "rejects malformed tool refs" do
      assert :error = ToolRef.parse("tool://lookup_docs")
      assert :error = ToolRef.parse("tool://lookup docs@2026-04-11")
      assert :error = ToolRef.parse("tool://lookup_docs@2026 04 11")
      assert :error = ToolRef.parse("lookup_docs@2026-04-11")
    end
  end

  describe "valid_part?/1" do
    test "accepts valid ref parts" do
      assert ToolRef.valid_part?("lookup_docs")
      assert ToolRef.valid_part?("2026-04-11")
    end

    test "rejects invalid ref parts" do
      refute ToolRef.valid_part?("")
      refute ToolRef.valid_part?("bad part")
      refute ToolRef.valid_part?("bad@part")
      refute ToolRef.valid_part?("bad\npart")
      refute ToolRef.valid_part?(123)
    end
  end
end
