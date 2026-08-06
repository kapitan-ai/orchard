defmodule Orchard.Metrics.Renderer do
  @moduledoc false

  alias Orchard.Metrics.{Catalog, GaugeSnapshotStore, Status}

  @content_type "text/plain; version=0.0.4; charset=utf-8"

  @spec content_type() :: String.t()
  def content_type, do: @content_type

  @spec render() :: {:ok, String.t()} | {:error, :unavailable}
  def render do
    if Status.healthy?() and generation_available?() do
      core = TelemetryMetricsPrometheus.Core.scrape(Orchard.Metrics.Reporter)
      gauges = render_gauges(GaugeSnapshotStore.snapshots())
      {:ok, IO.iodata_to_binary([core, gauges])}
    else
      {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp generation_available? do
    Enum.all?(
      [
        Orchard.Metrics.Reporter,
        Orchard.Metrics.CardinalityLedger,
        Orchard.Metrics.SeriesAdmission,
        Orchard.Metrics.GaugeSnapshotStore
      ],
      &is_pid(Process.whereis(&1))
    )
  end

  defp render_gauges(snapshots) do
    Catalog.descriptors()
    |> Enum.filter(&(&1.type == :gauge))
    |> Enum.flat_map(fn descriptor ->
      case Map.get(snapshots, descriptor.family) do
        nil ->
          []

        entries ->
          [["# TYPE ", descriptor.name, " gauge\n"], Enum.map(entries, &sample(descriptor, &1))]
      end
    end)
  end

  defp sample(descriptor, %{labels: labels, value: value}) do
    rendered_labels =
      descriptor.labels
      |> Enum.map(fn label ->
        [Atom.to_string(label), "=\"", escape(Map.fetch!(labels, label)), "\""]
      end)
      |> Enum.intersperse(",")

    [
      descriptor.name,
      if(rendered_labels == [], do: "", else: ["{", rendered_labels, "}"]),
      " ",
      to_string(value),
      "\n"
    ]
  end

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\"", "\\\"")
  end
end
