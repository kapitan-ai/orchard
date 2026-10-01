defmodule Orchard.Node.LinuxHostInventory.Amd do
  @moduledoc """
  AMD/ROCm accelerator observation for the Linux host inventory provider.

  Device identity is the `rocm-smi` unique ID, canonicalized so padded
  equivalents compare equal. ROCm installation evidence is reported at provider
  level and never implies that a device can execute it.
  """

  alias Orchard.Cluster.V1.{
    AcceleratorObservation,
    AcceleratorProviderObservation,
    AcceleratorRuntimeObservation
  }

  alias Orchard.Node.LinuxHostInventory.{Accelerators, Values}

  @vendor :ACCELERATOR_VENDOR_AMD
  @source "rocm-smi"
  @runtime_source "/opt/rocm/.info/version"
  @args [
    "--showuniqueid",
    "--showbus",
    "--showproductname",
    "--showmeminfo",
    "vram",
    "--showdriverversion",
    "--json"
  ]

  @doc "Observes AMD accelerators through `rocm-smi` and ROCm through its version file."
  @spec observe(Orchard.Node.LinuxHostInventory.context()) :: AcceleratorProviderObservation.t()
  def observe(context) do
    {visibility, visibility_invalid?} = Accelerators.visibility(context, "ROCR_VISIBLE_DEVICES")
    base = %{vendor: @vendor, source: @source, visibility: visibility, runtime: runtime(context)}

    with {:ok, output} <- context.run.(:rocm_smi, @args),
         {:ok, entries} when is_map(entries) <- Jason.decode(output) do
      driver = entries |> Map.get("system") |> value(["Driver version", "Driver Version"])

      entries
      |> Map.delete("system")
      |> Enum.sort_by(fn {key, _entry} -> key end)
      |> Accelerators.parse_devices(&parse_device(&1, driver, context))
      |> Accelerators.provider(base, visibility_invalid?, context)
    else
      {:error, reason} when is_atom(reason) -> Accelerators.failed(base, reason, context)
      _malformed -> Accelerators.failed(base, :malformed_output, context)
    end
  end

  defp parse_device({key, entry}, driver, context) when is_map(entry) do
    with stable_id when is_binary(stable_id) <-
           stable_id(value(entry, ["Unique ID", "Unique ID (Hex)"])),
         ordinal when is_integer(ordinal) <- ordinal(key),
         memory when is_integer(memory) and memory > 0 <-
           Values.uint64(value(entry, ["VRAM Total Memory (B)"])),
         {:ok, model} <- Values.text(value(entry, ["Card Series", "Card Model"])),
         {:ok, driver} <- Values.text(driver) do
      {:ok,
       %AcceleratorObservation{
         evidence: Values.evidence(:observed, @source, context.now_ms),
         vendor: @vendor,
         stable_id: stable_id,
         identity_kind: "amd_unique_id",
         device_ordinal: ordinal,
         pci_address: pci_address(value(entry, ["PCI Bus", "PCI Bus ID"])),
         model_name: model,
         memory_total_bytes: memory,
         driver_version: driver
       }}
    else
      _malformed -> :error
    end
  end

  defp parse_device(_entry, _driver, _context), do: :error

  defp value(entry, keys) when is_map(entry) do
    Enum.find_value(keys, fn key ->
      case Map.get(entry, key) do
        value when is_binary(value) -> value
        value when is_integer(value) -> Integer.to_string(value)
        _absent -> nil
      end
    end)
  end

  defp value(_entry, _keys), do: nil

  defp stable_id(value) when is_binary(value) do
    with [_, hex] <- Regex.run(~r/^0x([0-9a-f]{1,16})$/i, String.trim(value)),
         {integer, ""} when integer > 0 <- Integer.parse(hex, 16) do
      "0x" <> Integer.to_string(integer, 16)
    else
      _invalid -> nil
    end
  end

  defp stable_id(_value), do: nil

  defp ordinal(key) do
    case Regex.run(~r/^card([0-9]+)$/i, key) do
      [_, ordinal] -> Values.uint32(ordinal)
      _other -> nil
    end
  end

  defp pci_address(nil), do: ""

  defp pci_address(value) do
    value = value |> String.trim() |> String.downcase()

    if Regex.match?(~r/^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/, value),
      do: value,
      else: ""
  end

  defp runtime(context) do
    {state, code, version} =
      case context.read.(@runtime_source) do
        {:ok, contents} ->
          case Values.text(String.trim(contents)) do
            {:ok, version} when version != "" -> {:observed, "", version}
            _invalid -> {:error, "malformed_output", ""}
          end

        {:error, reason} ->
          {Values.failure_state(reason), reason, ""}
      end

    %AcceleratorRuntimeObservation{
      evidence: Values.evidence(state, @runtime_source, context.now_ms, code),
      name: "rocm",
      version: version
    }
  end
end
