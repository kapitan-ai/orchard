defmodule Orchard.Node.LinuxHostInventory.Nvidia do
  @moduledoc """
  NVIDIA/CUDA accelerator observation for the Linux host inventory provider.

  Device identity is the vendor-documented GPU UUID. Ordinal, PCI address, NUMA
  node, and the visibility environment are topology observations only. CUDA
  toolkit evidence is reported at provider level and never implies that a
  device can execute it.
  """

  alias Orchard.Cluster.V1.{
    AcceleratorObservation,
    AcceleratorProviderObservation,
    AcceleratorRuntimeObservation
  }

  alias Orchard.Node.LinuxHostInventory.{Accelerators, Values}

  @vendor :ACCELERATOR_VENDOR_NVIDIA
  @source "nvidia-smi"
  @query_args [
    "--query-gpu=index,uuid,pci.bus_id,name,memory.total,driver_version",
    "--format=csv,noheader,nounits"
  ]
  @max_memory_mib div(18_446_744_073_709_551_615, 1_048_576)
  @uuid ~r/^GPU-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @doc "Observes NVIDIA accelerators through `nvidia-smi` and the CUDA toolkit through `nvcc`."
  @spec observe(Orchard.Node.LinuxHostInventory.context()) :: AcceleratorProviderObservation.t()
  def observe(context) do
    {visibility, visibility_invalid?} = Accelerators.visibility(context, "CUDA_VISIBLE_DEVICES")
    base = %{vendor: @vendor, source: @source, visibility: visibility, runtime: runtime(context)}

    case context.run.(:nvidia_smi, @query_args) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Accelerators.parse_devices(&parse_device(&1, context))
        |> Accelerators.provider(base, visibility_invalid?, context)

      {:error, reason} ->
        Accelerators.failed(base, reason, context)
    end
  end

  defp parse_device(line, context) do
    with [ordinal, stable_id, pci, model, memory_mib, driver] <-
           String.split(line, ~r/,\s*/, parts: 6),
         true <- Regex.match?(@uuid, stable_id),
         ordinal when is_integer(ordinal) <- Values.uint32(ordinal),
         memory when is_integer(memory) and memory > 0 and memory <= @max_memory_mib <-
           Values.uint64(memory_mib),
         {:ok, model} <- Values.text(String.trim(model)),
         {:ok, driver} <- Values.text(String.trim(driver)) do
      pci_address = pci_address(pci)

      {:ok,
       %AcceleratorObservation{
         evidence: Values.evidence(:observed, @source, context.now_ms),
         vendor: @vendor,
         stable_id:
           "GPU-" <> String.downcase(binary_part(stable_id, 4, byte_size(stable_id) - 4)),
         identity_kind: "nvidia_gpu_uuid",
         device_ordinal: ordinal,
         pci_address: pci_address,
         numa_node: Accelerators.numa_node(context, pci_address),
         model_name: model,
         memory_total_bytes: memory * 1_048_576,
         driver_version: driver
       }}
    else
      _malformed -> :error
    end
  end

  # nvidia-smi reports an 8-digit PCI domain; sysfs uses the 4-digit form.
  defp pci_address(value) do
    value = value |> String.trim() |> String.downcase()

    case Regex.run(~r/^(?:0000)?([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])$/, value) do
      [_, address] -> address
      _other -> ""
    end
  end

  defp runtime(context) do
    case context.run.(:nvcc, ["--version"]) do
      {:ok, output} ->
        with [_, release] <- Regex.run(~r/release\s+([0-9]+(?:\.[0-9]+)*)/, output),
             {:ok, version} <- Values.text(release) do
          %AcceleratorRuntimeObservation{
            evidence: Values.evidence(:observed, "nvcc", context.now_ms),
            name: "cuda",
            version: version
          }
        else
          _malformed -> runtime_failure(:error, "malformed_output", context)
        end

      {:error, reason} ->
        runtime_failure(Values.failure_state(reason), reason, context)
    end
  end

  defp runtime_failure(state, code, context) do
    %AcceleratorRuntimeObservation{
      evidence: Values.evidence(state, "nvcc", context.now_ms, code),
      name: "cuda"
    }
  end
end
