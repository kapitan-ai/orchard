defmodule Orchard.Node.LinuxHostInventory.Nvidia do
  @moduledoc false

  alias Orchard.Cluster.V1.{
    AcceleratorObservation,
    AcceleratorProviderObservation,
    AcceleratorRuntimeObservation
  }

  alias Orchard.Node.LinuxHostInventory

  @vendor :ACCELERATOR_VENDOR_NVIDIA
  @source "nvidia-smi"
  @query_args [
    "--query-gpu=index,uuid,pci.bus_id,name,memory.total,driver_version",
    "--format=csv,noheader,nounits"
  ]
  @max_devices 64
  @max_memory_mib div(18_446_744_073_709_551_615, 1_048_576)
  @uuid_pattern ~r/^GPU-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @spec observe(LinuxHostInventory.context()) :: AcceleratorProviderObservation.t()
  def observe(context) do
    visibility_filter = bounded_visibility(context.env.("CUDA_VISIBLE_DEVICES"))
    runtime = runtime_observation(context)

    case context.run.("nvidia-smi", @query_args) do
      {:ok, output} ->
        {devices, malformed} = parse_devices(output, context)

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

      {:error, reason} when reason in [:missing_tool, :enoent] ->
        provider(:absent, [], visibility_filter, runtime, context.now_ms, "missing_tool")

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

  defp parse_devices(output, context) do
    lines = String.split(output, "\n", trim: true)
    retained = Enum.take(lines, @max_devices)
    truncated = max(length(lines) - length(retained), 0)

    retained
    |> Enum.reduce({[], truncated}, fn line, {devices, malformed} ->
      case parse_device(line, context) do
        {:ok, device} -> {[device | devices], malformed}
        :error -> {devices, malformed + 1}
      end
    end)
    |> then(fn {devices, malformed} -> {Enum.reverse(devices), malformed} end)
  end

  defp parse_device(line, context) do
    with [ordinal, stable_id, pci_address, model_name, memory_mib, driver_version] <-
           String.split(line, ~r/,\s*/, parts: 6),
         true <- Regex.match?(@uuid_pattern, stable_id),
         parsed_ordinal when is_integer(parsed_ordinal) <-
           LinuxHostInventory.uint32(ordinal),
         parsed_memory when is_integer(parsed_memory) and parsed_memory > 0 <-
           LinuxHostInventory.uint64(memory_mib),
         true <- parsed_memory <= @max_memory_mib do
      {:ok,
       %AcceleratorObservation{
         evidence: LinuxHostInventory.evidence(:observed, @source, context.now_ms),
         vendor: @vendor,
         stable_id: canonical_uuid(stable_id),
         identity_kind: "nvidia_gpu_uuid",
         device_ordinal: parsed_ordinal,
         pci_address: valid_pci_address(pci_address),
         numa_node: numa_node(context, pci_address),
         model_name: LinuxHostInventory.bounded_string(model_name),
         memory_total_bytes: parsed_memory * 1_048_576,
         driver_version: LinuxHostInventory.bounded_string(driver_version)
       }}
    else
      _other -> :error
    end
  end

  defp runtime_observation(context) do
    case context.run.("nvcc", ["--version"]) do
      {:ok, output} ->
        case Regex.run(~r/release\s+([0-9]+(?:\.[0-9]+)*)/, output) do
          [_, version] ->
            version = LinuxHostInventory.bounded_string(version)

            %AcceleratorRuntimeObservation{
              evidence: LinuxHostInventory.evidence(:observed, "nvcc", context.now_ms),
              name: "cuda",
              version: version
            }

          _other ->
            runtime_error(:error, context.now_ms, "malformed_output")
        end

      {:error, reason} when reason in [:missing_tool, :enoent] ->
        runtime_error(:absent, context.now_ms, "missing_tool")

      {:error, reason} ->
        runtime_error(:error, context.now_ms, Atom.to_string(reason))
    end
  end

  defp runtime_error(state, now_ms, error_code) do
    %AcceleratorRuntimeObservation{
      evidence: LinuxHostInventory.evidence(state, "nvcc", now_ms, error_code),
      name: "cuda"
    }
  end

  defp numa_node(context, pci_address) do
    case valid_pci_address(pci_address) do
      "" ->
        ""

      address ->
        case context.read.("/sys/bus/pci/devices/#{address}/numa_node") do
          {:ok, value} -> value |> String.trim() |> LinuxHostInventory.bounded_string()
          _other -> ""
        end
    end
  end

  defp valid_pci_address(value) do
    value = value |> String.trim() |> String.downcase()

    case Regex.run(~r/^[0-9a-f]{4}([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])$/, value) do
      [_, address] ->
        address

      _other ->
        if Regex.match?(~r/^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/, value),
          do: value,
          else: ""
    end
  end

  defp canonical_uuid("GPU-" <> uuid), do: "GPU-" <> String.downcase(uuid)

  defp canonical_uuid(stable_id) do
    "GPU-" <> (stable_id |> String.slice(4..-1//1) |> String.downcase())
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
