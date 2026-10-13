defmodule Orchard.Node.LinuxHostInventory.Amd do
  @moduledoc false

  alias Orchard.Cluster.V1.{
    AcceleratorObservation,
    AcceleratorProviderObservation,
    AcceleratorRuntimeObservation
  }

  alias Orchard.Node.LinuxHostInventory

  @vendor :ACCELERATOR_VENDOR_AMD
  @source "rocm-smi"
  @runtime_version_source "/opt/rocm/.info/version"
  @args [
    "--showuniqueid",
    "--showbus",
    "--showproductname",
    "--showmeminfo",
    "vram",
    "--showdriverversion",
    "--json"
  ]
  @max_devices 64

  @spec observe(LinuxHostInventory.context()) :: AcceleratorProviderObservation.t()
  def observe(context) do
    visibility_filter = bounded_visibility(context.env.("ROCR_VISIBLE_DEVICES"))
    runtime = runtime_observation(context)

    case context.run.("rocm-smi", @args) do
      {:ok, output} ->
        parse_output(output, visibility_filter, runtime, context)

      {:error, reason} when reason in [:missing_tool, :enoent] ->
        provider(
          :absent,
          [],
          visibility_filter,
          runtime,
          context.now_ms,
          "missing_tool"
        )

      {:error, reason} ->
        provider(
          :error,
          [],
          visibility_filter,
          runtime,
          context.now_ms,
          Atom.to_string(reason)
        )
    end
  end

  defp parse_output(output, visibility_filter, runtime, context) do
    case Jason.decode(output) do
      {:ok, entries} when is_map(entries) ->
        driver_version = system_driver_version(entries)
        {devices, malformed} = parse_devices(entries, driver_version, context)

        cond do
          duplicate_identities?(devices) ->
            provider(
              :error,
              [],
              visibility_filter,
              runtime,
              context.now_ms,
              "duplicate_stable_identity"
            )

          malformed > 0 and devices != [] ->
            provider(
              :partial,
              devices,
              visibility_filter,
              runtime,
              context.now_ms,
              "malformed_entries"
            )

          malformed > 0 ->
            provider(
              :error,
              [],
              visibility_filter,
              runtime,
              context.now_ms,
              "malformed_output"
            )

          true ->
            provider(:observed, devices, visibility_filter, runtime, context.now_ms, "")
        end

      _other ->
        provider(
          :error,
          [],
          visibility_filter,
          runtime,
          context.now_ms,
          "malformed_output"
        )
    end
  end

  defp parse_devices(entries, driver_version, context) do
    device_entries =
      entries
      |> Enum.reject(fn {key, _entry} -> key == "system" end)
      |> Enum.sort_by(fn {key, _entry} -> key end)

    retained = Enum.take(device_entries, @max_devices)
    truncated = max(length(device_entries) - length(retained), 0)

    retained
    |> Enum.reduce({[], truncated}, fn {key, entry}, {devices, malformed} ->
      case parse_device(key, entry, driver_version, context) do
        {:ok, device} -> {[device | devices], malformed}
        :error -> {devices, malformed + 1}
      end
    end)
    |> then(fn {devices, malformed} -> {Enum.reverse(devices), malformed} end)
  end

  defp parse_device(key, entry, driver_version, context) when is_map(entry) do
    observed_id = value(entry, ["Unique ID", "Unique ID (Hex)"])
    memory = value(entry, ["VRAM Total Memory (B)"])

    with stable_id when is_binary(stable_id) <- canonical_stable_id(observed_id),
         ordinal when is_integer(ordinal) <- ordinal(key),
         memory_bytes when is_integer(memory_bytes) and memory_bytes > 0 <-
           LinuxHostInventory.uint64(memory) do
      {:ok,
       %AcceleratorObservation{
         evidence: LinuxHostInventory.evidence(:observed, @source, context.now_ms),
         vendor: @vendor,
         stable_id: stable_id,
         identity_kind: "amd_unique_id",
         device_ordinal: ordinal,
         pci_address: value(entry, ["PCI Bus", "PCI Bus ID"]) |> normalize_pci(),
         numa_node: "",
         model_name:
           value(entry, ["Card Series", "Card Model"]) |> LinuxHostInventory.bounded_string(),
         memory_total_bytes: memory_bytes,
         driver_version: LinuxHostInventory.bounded_string(driver_version)
       }}
    else
      _other -> :error
    end
  end

  defp parse_device(_key, _entry, _driver_version, _context), do: :error

  defp value(entry, keys) do
    Enum.find_value(keys, "", fn key ->
      case Map.get(entry, key) do
        nil -> nil
        value when is_binary(value) -> value
        value when is_integer(value) -> Integer.to_string(value)
        _value -> nil
      end
    end)
  end

  defp canonical_stable_id(value) when is_binary(value) do
    case Regex.run(~r/^0x([0-9a-f]{1,16})$/i, String.trim(value)) do
      [_, hexadecimal] ->
        case Integer.parse(hexadecimal, 16) do
          {integer, ""} when integer > 0 -> "0x" <> Integer.to_string(integer, 16)
          _value -> nil
        end

      _value ->
        nil
    end
  end

  defp canonical_stable_id(_value), do: nil

  defp ordinal(key) do
    case Regex.run(~r/(?:card)?([0-9]+)$/i, to_string(key)) do
      [_, value] -> LinuxHostInventory.uint32(value)
      _other -> nil
    end
  end

  defp normalize_pci(value) do
    value = value |> String.trim() |> String.downcase()

    if Regex.match?(~r/^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/, value),
      do: value,
      else: ""
  end

  defp runtime_observation(context) do
    case context.read.(@runtime_version_source) do
      {:ok, contents} ->
        version = contents |> String.trim() |> LinuxHostInventory.bounded_string()

        if version == "" do
          runtime(:error, context.now_ms, "malformed_output")
        else
          %AcceleratorRuntimeObservation{
            evidence:
              LinuxHostInventory.evidence(:observed, @runtime_version_source, context.now_ms),
            name: "rocm",
            version: version
          }
        end

      {:error, reason} when reason in [:missing_tool, :enoent] ->
        runtime(:absent, context.now_ms, "missing_file")

      {:error, reason} ->
        runtime(:error, context.now_ms, Atom.to_string(reason))
    end
  end

  defp system_driver_version(entries) do
    case Map.get(entries, "system") do
      metadata when is_map(metadata) ->
        value(metadata, ["Driver version", "Driver Version"])

      _metadata ->
        ""
    end
  end

  defp runtime(state, now_ms, error_code) do
    %AcceleratorRuntimeObservation{
      evidence: LinuxHostInventory.evidence(state, @runtime_version_source, now_ms, error_code),
      name: "rocm"
    }
  end

  defp duplicate_identities?(devices) do
    identities = Enum.map(devices, & &1.stable_id)
    length(identities) != length(Enum.uniq(identities))
  end

  defp provider(state, devices, visibility_filter, runtime, now_ms, error_code) do
    %AcceleratorProviderObservation{
      evidence: LinuxHostInventory.evidence(state, @source, now_ms, error_code),
      vendor: @vendor,
      devices: devices,
      visibility_filter: visibility_filter,
      runtime: runtime
    }
  end

  defp bounded_visibility(nil), do: ""
  defp bounded_visibility(value), do: LinuxHostInventory.bounded_string(value)
end
