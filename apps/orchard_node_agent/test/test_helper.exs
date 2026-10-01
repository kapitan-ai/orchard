# Real host-inventory probe tests need a GNU coreutils `timeout` guardian. They
# run wherever one exists at a fixed absolute path (Linux `/usr/bin/timeout`,
# or Homebrew coreutils on macOS) and are excluded, never faked, elsewhere.
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

unless gnu_timeout do
  IO.puts("host inventory probe tests excluded: no GNU coreutils timeout guardian found")
end

ExUnit.start(exclude: if(gnu_timeout, do: [], else: [:gnu_timeout]))

# grpc >= 1.0 starts GRPC.Client.Supervisor from the :grpc application, so no
# test-only bootstrap is needed for tests using GRPC.Stub.connect/1.
{:ok, _} = Application.ensure_all_started(:grpc)
