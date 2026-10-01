# Real host-inventory probe tests need a GNU coreutils `timeout` guardian at a
# fixed absolute path (Linux `/usr/bin/timeout`, or Homebrew coreutils on
# macOS). They always run; without a guardian they fail with install guidance.
gnu_timeout =
  Enum.find(
    ["/usr/bin/timeout", "/opt/homebrew/bin/timeout", "/usr/local/bin/timeout"],
    fn path ->
      File.regular?(path) and
        match?(
          {"timeout (GNU coreutils) " <> _rest, 0},
          System.cmd(path, ["--version"], env: [{"LC_ALL", "C"}])
        )
    end
  )

Application.put_env(:orchard_node_agent, :test_gnu_timeout, gnu_timeout)

ExUnit.start()

# grpc >= 1.0 starts GRPC.Client.Supervisor from the :grpc application, so no
# test-only bootstrap is needed for tests using GRPC.Stub.connect/1.
{:ok, _} = Application.ensure_all_started(:grpc)
