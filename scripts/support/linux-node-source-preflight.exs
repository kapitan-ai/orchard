# Candidate configuration validation before socket/cookie creation or VM
# Distribution. This process does not start an Orchard application role.
try do
  Orchard.Node.SourceStartup.preflight!()
rescue
  _error in Orchard.Node.SourceStartup.Error ->
    IO.puts(:stderr, "error: experimental Node source preflight refused")
    System.halt(78)
end
