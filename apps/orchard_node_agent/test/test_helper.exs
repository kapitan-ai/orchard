# Real host-inventory probe tests need a GNU coreutils `timeout` guardian at a
# fixed absolute path; see Orchard.TestSupport.GnuTimeoutGuardian. They always
# run; without a guardian they fail with install guidance.
Application.put_env(
  :orchard_node_agent,
  :test_gnu_timeout,
  Orchard.TestSupport.GnuTimeoutGuardian.discover()
)

ExUnit.start()

# grpc >= 1.0 starts GRPC.Client.Supervisor from the :grpc application, so no
# test-only bootstrap is needed for tests using GRPC.Stub.connect/1.
{:ok, _} = Application.ensure_all_started(:grpc)
