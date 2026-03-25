defmodule Orchard.Config.RuntimeTargetParserTest do
  use ExUnit.Case, async: true

  alias Orchard.Config.RuntimeTargetParser

  @env_name "ORCHARD_RUNTIME_CLIENT_TARGETS"

  describe "parse_csv!/2" do
    test "returns empty list for nil" do
      assert RuntimeTargetParser.parse_csv!(nil, @env_name) == []
    end

    test "returns empty list for blank string" do
      assert RuntimeTargetParser.parse_csv!("", @env_name) == []
    end

    test "returns empty list for whitespace-only string" do
      assert RuntimeTargetParser.parse_csv!("  , , ", @env_name) == []
    end

    test "parses single target" do
      assert RuntimeTargetParser.parse_csv!("127.0.0.1:50071", @env_name) ==
               [[host: "127.0.0.1", port: 50_071]]
    end

    test "parses multiple targets preserving order" do
      input = "10.0.0.1:50061,10.0.0.2:50062,10.0.0.3:50063"

      assert RuntimeTargetParser.parse_csv!(input, @env_name) == [
               [host: "10.0.0.1", port: 50_061],
               [host: "10.0.0.2", port: 50_062],
               [host: "10.0.0.3", port: 50_063]
             ]
    end

    test "trims whitespace around segments" do
      input = " 10.0.0.1:50061 , 10.0.0.2:50062 "

      assert RuntimeTargetParser.parse_csv!(input, @env_name) == [
               [host: "10.0.0.1", port: 50_061],
               [host: "10.0.0.2", port: 50_062]
             ]
    end

    test "raises on missing port" do
      assert_raise RuntimeError, ~r/invalid host:port segment/, fn ->
        RuntimeTargetParser.parse_csv!("host-only", @env_name)
      end
    end

    test "raises on non-integer port" do
      assert_raise RuntimeError, ~r/invalid port in segment/, fn ->
        RuntimeTargetParser.parse_csv!("host:abc", @env_name)
      end
    end

    test "raises on port out of range (too high)" do
      assert_raise RuntimeError, ~r/invalid port in segment/, fn ->
        RuntimeTargetParser.parse_csv!("host:70000", @env_name)
      end
    end

    test "raises on port zero" do
      assert_raise RuntimeError, ~r/invalid port in segment/, fn ->
        RuntimeTargetParser.parse_csv!("host:0", @env_name)
      end
    end

    test "raises on extra-colon segment (bracketless IPv6-like)" do
      assert_raise RuntimeError, ~r/invalid host:port segment/, fn ->
        RuntimeTargetParser.parse_csv!("fe80::1:50061", @env_name)
      end
    end

    test "raises on empty host with port" do
      assert_raise RuntimeError, ~r/invalid host:port segment/, fn ->
        RuntimeTargetParser.parse_csv!(":50061", @env_name)
      end
    end

    test "includes env var name in error message" do
      assert_raise RuntimeError, ~r/MY_CUSTOM_VAR/, fn ->
        RuntimeTargetParser.parse_csv!("bad", "MY_CUSTOM_VAR")
      end
    end

    test "accepts port boundary values" do
      assert RuntimeTargetParser.parse_csv!("host:1", @env_name) ==
               [[host: "host", port: 1]]

      assert RuntimeTargetParser.parse_csv!("host:65535", @env_name) ==
               [[host: "host", port: 65_535]]
    end
  end
end
