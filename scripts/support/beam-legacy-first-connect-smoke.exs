alias Orchard.RuntimeEndpoint.{BeamClient, Target}

inference = Application.fetch_env!(:orchard_controller, :inference)

target =
  inference
  |> Keyword.fetch!(:runtime_endpoint_targets)
  |> List.first()
  |> Target.normalize()

unless is_atom(target.address) do
  raise "legacy BEAM target was not materialized during bounded configuration parsing"
end

case BeamClient.connect(target) do
  {:ok, %BeamClient{node: peer}} ->
    IO.puts("legacy first-connect reached #{peer}")

  {:error, reason} ->
    raise "legacy first-connect failed: #{inspect(reason)}"
end
