defmodule Orchard.Node.LinuxHostInventory.Accelerators do
  @moduledoc """
  Vendor-neutral assembly of one accelerator provider observation.

  Each vendor keeps its own provenance. Duplicate stable identities fail closed
  with no devices, malformed rows make the evidence partial, and a missing tool
  is absent evidence rather than a healthy or free device.
  """

  alias Orchard.Cluster.V1.{AcceleratorObservation, AcceleratorProviderObservation}
  alias Orchard.Node.LinuxHostInventory.Values
  alias Orchard.RuntimeEndpoint.HostInventory, as: InventoryBound

  @type base :: %{
          vendor: atom(),
          source: String.t(),
          visibility: String.t(),
          runtime: Orchard.Cluster.V1.AcceleratorRuntimeObservation.t()
        }

  @doc "Reads the vendor visibility environment as a bounded topology observation."
  @spec visibility(Orchard.Node.LinuxHostInventory.context(), String.t()) ::
          {String.t(), boolean()}
  def visibility(context, variable) do
    case Values.text(context.env.(variable)) do
      {:ok, value} -> {value, false}
      :invalid -> {"", true}
    end
  end

  @doc "Parses at most the bounded number of rows, counting malformed and dropped rows."
  @spec parse_devices([term()], (term() -> {:ok, AcceleratorObservation.t()} | :error)) ::
          {[AcceleratorObservation.t()], non_neg_integer()}
  def parse_devices(rows, parse) do
    retained = Enum.take(rows, InventoryBound.max_list_entries())

    {devices, malformed} =
      Enum.reduce(retained, {[], length(rows) - length(retained)}, fn row, {devices, malformed} ->
        case parse.(row) do
          {:ok, device} -> {[device | devices], malformed}
          :error -> {devices, malformed + 1}
        end
      end)

    {Enum.reverse(devices), malformed}
  end

  @doc "Builds the provider observation from parsed devices."
  @spec provider(
          {[AcceleratorObservation.t()], non_neg_integer()},
          base(),
          boolean(),
          Orchard.Node.LinuxHostInventory.context()
        ) :: AcceleratorProviderObservation.t()
  def provider({devices, malformed}, base, visibility_invalid?, context) do
    identities = Enum.map(devices, & &1.stable_id)

    cond do
      identities != Enum.uniq(identities) ->
        build(base, :error, "duplicate_stable_identity", [], context)

      malformed > 0 and devices != [] ->
        build(base, :partial, "malformed_entries", devices, context)

      malformed > 0 ->
        build(base, :error, "malformed_output", [], context)

      visibility_invalid? ->
        build(base, :partial, "invalid_value", devices, context)

      true ->
        build(base, :observed, "", devices, context)
    end
  end

  @doc "Builds the provider observation for a failed vendor probe."
  @spec failed(base(), atom(), Orchard.Node.LinuxHostInventory.context()) ::
          AcceleratorProviderObservation.t()
  def failed(base, reason, context),
    do: build(base, Values.failure_state(reason), reason, [], context)

  @doc "Reads the sysfs NUMA node for a validated PCI address, or an empty observation."
  @spec numa_node(Orchard.Node.LinuxHostInventory.context(), String.t()) :: String.t()
  def numa_node(_context, ""), do: ""

  def numa_node(context, pci_address) do
    case context.read.("/sys/bus/pci/devices/#{pci_address}/numa_node") do
      {:ok, contents} -> contents |> String.trim() |> numa_number()
      {:error, _reason} -> ""
    end
  end

  # sysfs reports -1 when the platform exposes no NUMA affinity.
  defp numa_number("-1"), do: "-1"
  defp numa_number(value) when is_binary(value), do: value |> Values.uint32() |> numa_number()

  defp numa_number(node) when is_integer(node), do: Integer.to_string(node)
  defp numa_number(nil), do: ""

  defp build(base, state, code, devices, context) do
    %AcceleratorProviderObservation{
      evidence: Values.evidence(state, base.source, context.now_ms, code),
      vendor: base.vendor,
      devices: devices,
      visibility_filter: base.visibility,
      runtime: base.runtime
    }
  end
end
