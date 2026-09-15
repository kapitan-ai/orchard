defmodule Orchard.TestSupport.GeneratedToolArgumentFixture do
  @moduledoc false

  alias Orchard.Cluster.V1
  alias Orchard.Cluster.V1.InferenceEventMapper

  @fixture_path Path.expand(
                  "../../../../proto/cluster/v1/fixtures/generated_tool_argument_events.json",
                  __DIR__
                )
  @external_resource @fixture_path
  @fixtures @fixture_path |> File.read!() |> Jason.decode!()

  @spec events!(String.t()) :: [Orchard.InferenceEvent.t()]
  def events!(scenario) do
    scenario
    |> fixture!()
    |> Map.fetch!("events_base64")
    |> Enum.map(fn encoded ->
      proto = encoded |> Base.decode64!() |> Protobuf.decode(V1.InferenceEvent)
      {:ok, event} = InferenceEventMapper.from_proto(proto)
      event
    end)
  end

  @spec arguments!(String.t()) :: [String.t()]
  def arguments!(scenario) do
    scenario
    |> fixture!()
    |> Map.fetch!("arguments")
  end

  defp fixture!(scenario), do: Map.fetch!(@fixtures, scenario)
end
