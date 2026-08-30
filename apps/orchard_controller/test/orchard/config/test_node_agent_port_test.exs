defmodule Orchard.Config.TestNodeAgentPortTest do
  use ExUnit.Case, async: false

  @config_dir Path.expand("../../../../../config", __DIR__)
  @test_config Path.join(@config_dir, "test.exs")
  @ephemeral_range_path "/proc/sys/net/ipv4/ip_local_port_range"

  setup_all do
    Code.require_file("test_node_agent_port.exs", @config_dir)
    :ok
  end

  setup do
    snapshot = System.get_env("ORCHARD_TEST_NODE_AGENT_PORT")

    on_exit(fn ->
      case snapshot do
        nil -> System.delete_env("ORCHARD_TEST_NODE_AGENT_PORT")
        value -> System.put_env("ORCHARD_TEST_NODE_AGENT_PORT", value)
      end
    end)

    System.delete_env("ORCHARD_TEST_NODE_AGENT_PORT")
    :ok
  end

  alias Orchard.Config.TestNodeAgentPort

  describe "resolve!/2" do
    test "defaults below the Linux ephemeral range so the kernel never assigns the test port" do
      assert TestNodeAgentPort.resolve!(nil, {32_768, 60_999}) == 15_071
    end

    test "rejects a configured port inside the ephemeral range with actionable output" do
      error =
        assert_raise RuntimeError, fn ->
          TestNodeAgentPort.resolve!("50171", {32_768, 60_999})
        end

      message = Exception.message(error)

      assert message =~ "ORCHARD_TEST_NODE_AGENT_PORT"
      assert message =~ "50171"
      assert message =~ "32768"
      assert message =~ "60999"
    end

    test "treats the ephemeral range as inclusive on both boundaries" do
      assert_raise RuntimeError, ~r/32768/, fn ->
        TestNodeAgentPort.resolve!("32768", {32_768, 60_999})
      end

      assert_raise RuntimeError, ~r/60999/, fn ->
        TestNodeAgentPort.resolve!("60999", {32_768, 60_999})
      end

      assert TestNodeAgentPort.resolve!("32767", {32_768, 60_999}) == 32_767
      assert TestNodeAgentPort.resolve!("61000", {32_768, 60_999}) == 61_000
    end

    test "keeps explicit overrides working for concurrent worktrees" do
      assert TestNodeAgentPort.resolve!("15271", {32_768, 60_999}) == 15_271
    end

    test "accepts any valid port when the host exposes no ephemeral range" do
      assert TestNodeAgentPort.resolve!("50171", nil) == 50_171
    end

    test "rejects values outside 1..65535 and non-integers" do
      Enum.each(["0", "65536", "", " ", "15071x", "abc"], fn value ->
        assert_raise RuntimeError,
                     ~r/ORCHARD_TEST_NODE_AGENT_PORT must be an integer between 1 and 65535/,
                     fn -> TestNodeAgentPort.resolve!(value, nil) end
      end)
    end
  end

  describe "local_ephemeral_range/1" do
    @tag :tmp_dir
    test "parses the kernel range file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ip_local_port_range")
      File.write!(path, "32768\t60999\n")

      assert TestNodeAgentPort.local_ephemeral_range(path) == {32_768, 60_999}
    end

    @tag :tmp_dir
    test "returns nil for an absent or unreadable range file", %{tmp_dir: tmp_dir} do
      assert TestNodeAgentPort.local_ephemeral_range(Path.join(tmp_dir, "missing")) == nil
    end

    @tag :tmp_dir
    test "returns nil for malformed range content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "malformed")
      File.write!(path, "not a range\n")

      assert TestNodeAgentPort.local_ephemeral_range(path) == nil
    end

    test "reads the host range on Linux and nothing elsewhere" do
      case File.read(@ephemeral_range_path) do
        {:ok, _contents} ->
          assert {low, high} = TestNodeAgentPort.local_ephemeral_range()
          assert low <= high

        {:error, _reason} ->
          assert TestNodeAgentPort.local_ephemeral_range() == nil
      end
    end
  end

  describe "config/test.exs seam" do
    test "the configured test port sits outside the host ephemeral range" do
      port = read_listen_port!(%{})

      case TestNodeAgentPort.local_ephemeral_range() do
        nil -> assert port in 1..65_535
        {low, high} -> refute port in low..high
      end
    end

    test "rejects the historical CI port on hosts with an ephemeral range covering it" do
      case TestNodeAgentPort.local_ephemeral_range() do
        {low, high} when 50_171 >= low and 50_171 <= high ->
          assert_raise RuntimeError, ~r/50171/, fn ->
            read_listen_port!(%{"ORCHARD_TEST_NODE_AGENT_PORT" => "50171"})
          end

        _other ->
          assert read_listen_port!(%{"ORCHARD_TEST_NODE_AGENT_PORT" => "50171"}) == 50_171
      end
    end

    test "controller runtime client target follows the node-agent listen port" do
      System.put_env("ORCHARD_TEST_NODE_AGENT_PORT", "15271")

      config = Config.Reader.read!(@test_config, env: :test)

      listen_port =
        config
        |> Keyword.fetch!(:orchard_node_agent)
        |> Keyword.fetch!(:runtime)
        |> Keyword.fetch!(:listen_address)
        |> Keyword.fetch!(:port)

      client_port =
        config
        |> Keyword.fetch!(:orchard_controller)
        |> Keyword.fetch!(:inference)
        |> Keyword.fetch!(:runtime_client_target)
        |> Keyword.fetch!(:port)

      assert listen_port == 15_271
      assert client_port == 15_271
    end
  end

  defp read_listen_port!(env) do
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    @test_config
    |> Config.Reader.read!(env: :test)
    |> Keyword.fetch!(:orchard_node_agent)
    |> Keyword.fetch!(:runtime)
    |> Keyword.fetch!(:listen_address)
    |> Keyword.fetch!(:port)
  end
end
