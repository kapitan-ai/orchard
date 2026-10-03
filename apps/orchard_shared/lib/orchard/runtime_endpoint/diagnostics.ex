defmodule Orchard.RuntimeEndpoint.Diagnostics do
  @moduledoc """
  Pure, redacted runtime-target observations for `SPEC.md` §4.6.1.

  Counts describe observed inventory, never capacity. Neither projection nor
  normalization performs I/O or changes runtime, Node or scheduling authority.
  """

  alias Orchard.RuntimeEndpoint.HostInventory

  @inventory_max_age_ms 195_000
  @runtime_max_age_ms 15_000
  @sections [:cpu, :memory, :disk, :platform, :network, :nvidia, :amd]
  @states ~w(observed absent partial error invalid stale)
  @workers ~w(starting idle busy stopping failed stopped unknown)
  @sources %{
    "lscpu --json" => "cpu_probe",
    "/proc/meminfo" => "memory_probe",
    "findmnt --json --bytes" => "disk_probe",
    "os-release+uname+ldd+systemctl+cgroupfs" => "platform_probe",
    "ip --json address show" => "network_probe",
    "nvidia-smi" => "nvidia_probe",
    "rocm-smi" => "amd_probe"
  }
  @source_categories Map.values(@sources)
  @evidence_states %{
    HOST_EVIDENCE_STATE_OBSERVED: "observed",
    HOST_EVIDENCE_STATE_ABSENT: "absent",
    HOST_EVIDENCE_STATE_PARTIAL: "partial",
    HOST_EVIDENCE_STATE_ERROR: "error"
  }

  @type t :: %{
          schema_version: 1,
          authority: String.t(),
          runtime: map(),
          inventory: map()
        }

  @doc "Projects an existing status response without retaining raw payloads."
  @spec project(map(), integer()) :: t()
  def project(response, now_ms) do
    runtime = %{
      status: "observed",
      observed_at_unix_ms: timestamp(get(response, :observed_at)),
      health: health(get(response, :health) || get(response, :runtime_health)),
      worker_state: worker(get(response, :worker_state))
    }

    normalize(
      %{
        schema_version: 1,
        runtime: runtime,
        inventory: inventory(get(response, :host_inventory), now_ms)
      },
      now_ms
    )
  end

  @doc "Re-applies the allowlist and freshness bounds to a previously projected block."
  @spec normalize(term(), integer()) :: t() | nil
  def normalize(value, now_ms) do
    if get(value, :schema_version) === 1 do
      %{
        schema_version: 1,
        authority: "observation_only",
        runtime: runtime(get(value, :runtime), now_ms),
        inventory: normalize_inventory(get(value, :inventory), now_ms)
      }
    end
  end

  defp runtime(value, now_ms) do
    evidence = evidence(value, now_ms, @runtime_max_age_ms)
    fresh? = evidence.status == "observed"

    Map.merge(evidence, %{
      source: "runtime_endpoint",
      health:
        if(fresh?,
          do: category(get(value, :health), ~w(ready not_ready unknown)),
          else: "unknown"
        ),
      worker_state: if(fresh?, do: category(get(value, :worker_state), @workers), else: "unknown")
    })
  end

  defp inventory(nil, _now_ms), do: %{status: "absent"}

  defp inventory(raw, now_ms) do
    if bounded?([{raw, 0}], 4096, 131_072) and HostInventory.normalize(raw) != nil do
      sections = Map.new(@sections, &{&1, section(raw, &1, now_ms)})
      Map.merge(sections, %{status: "observed", observed_at_unix_ms: raw.observed_at_unix_ms})
    else
      %{status: "invalid"}
    end
  end

  defp normalize_inventory(value, now_ms) do
    envelope = evidence(value, now_ms, @inventory_max_age_ms)

    Map.merge(
      envelope,
      Map.new(@sections, fn key ->
        section = if envelope.status == "observed", do: get(value, key)
        normalized = evidence(section, now_ms, @inventory_max_age_ms)

        count =
          if normalized.status == "observed" and valid_source?(key, get(section, :source)),
            do: diagnostic_count(get(section, :count), key)

        {key,
         Map.merge(normalized, %{
           source: category(get(section, :source), @source_categories),
           count: count
         })}
      end)
    )
  end

  defp section(raw, vendor, now_ms) when vendor in [:nvidia, :amd] do
    expected = if vendor == :nvidia, do: :ACCELERATOR_VENDOR_NVIDIA, else: :ACCELERATOR_VENDOR_AMD
    provider = Enum.find(raw.accelerator_providers, &(&1.vendor == expected))
    evidence = section_evidence(provider, now_ms)
    devices = get(provider, :devices)

    valid_devices? =
      is_list(devices) and
        Enum.all?(devices, fn device ->
          device_evidence = section_evidence(device, now_ms)

          device.vendor == expected and device_evidence.status == "observed" and
            valid_source?(vendor, device_evidence.source)
        end)

    if evidence.status == "observed" and valid_source?(vendor, evidence.source) and valid_devices? do
      oldest =
        Enum.reduce(devices, evidence.observed_at_unix_ms, fn device, time ->
          min(time, device.evidence.observed_at_unix_ms)
        end)

      Map.merge(evidence, %{count: length(devices), observed_at_unix_ms: oldest})
    else
      Map.put(evidence, :count, nil)
    end
  end

  defp section(raw, key, now_ms) do
    section = get(raw, key)
    evidence = section_evidence(section, now_ms)
    count = if evidence.status == "observed", do: section_count(section, key)
    Map.put(evidence, :count, count)
  end

  defp section_count(section, :cpu), do: positive_count(get(section, :logical_processor_count))
  defp section_count(section, :network), do: length(section.interfaces)
  defp section_count(_section, _key), do: nil

  defp valid_source?(:nvidia, source), do: source == "nvidia_probe"
  defp valid_source?(:amd, source), do: source == "amd_probe"
  defp valid_source?(_section, _source), do: true

  defp section_evidence(section, now_ms) do
    raw = get(section, :evidence)

    state =
      if is_nil(raw), do: "absent", else: Map.get(@evidence_states, get(raw, :state), "invalid")

    %{status: state, observed_at_unix_ms: get(raw, :observed_at_unix_ms)}
    |> evidence(now_ms, @inventory_max_age_ms)
    |> Map.put(:source, Map.get(@sources, get(raw, :source), "unknown"))
  end

  defp evidence(value, now_ms, max_age_ms) do
    state = category(get(value, :status), @states, "absent")
    time = get(value, :observed_at_unix_ms)
    valid_time? = is_integer(time) and time > 0 and time <= now_ms
    age = if valid_time?, do: now_ms - time

    status =
      cond do
        state in ["absent", "invalid"] -> state
        not valid_time? -> "invalid"
        age > max_age_ms -> "stale"
        true -> state
      end

    %{status: status, observed_at_unix_ms: if(valid_time?, do: time), age_ms: age}
  end

  defp timestamp(%DateTime{} = time), do: DateTime.to_unix(time, :millisecond)
  defp timestamp(_time), do: nil
  defp health(%{ready: true}), do: "ready"
  defp health(%{ready: false}), do: "not_ready"
  defp health(_health), do: "unknown"

  defp worker(state) when is_atom(state) do
    state
    |> Atom.to_string()
    |> String.replace_prefix("WORKER_STATE_", "")
    |> String.downcase()
    |> category(@workers)
  end

  defp worker(_state), do: "unknown"
  defp diagnostic_count(value, :cpu), do: positive_count(value)

  defp diagnostic_count(value, key)
       when key in [:network, :nvidia, :amd] and is_integer(value) and value in 0..64,
       do: value

  defp diagnostic_count(_value, _key), do: nil
  defp positive_count(value) when is_integer(value) and value > 0, do: count(value)
  defp positive_count(_value), do: nil
  defp count(value) when is_integer(value) and value in 0..4_294_967_295, do: value
  defp count(_value), do: nil

  defp category(value, allowed, default \\ "unknown"),
    do: if(value in allowed, do: value, else: default)

  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_map, _key), do: nil

  # Bound total work before protobuf validation, including malicious raw BEAM terms.
  defp bounded?(_pending, nodes, bytes) when nodes < 0 or bytes < 0, do: false
  defp bounded?([], _nodes, _bytes), do: true
  defp bounded?([{_value, depth} | _rest], _nodes, _bytes) when depth > 12, do: false

  defp bounded?([{value, depth} | rest], nodes, bytes)
       when is_map(value) and map_size(value) <= 32 do
    children =
      Enum.flat_map(Map.to_list(value), fn {key, item} ->
        [{key, depth + 1}, {item, depth + 1}]
      end)

    bounded?(children ++ rest, nodes - 1, bytes)
  end

  defp bounded?([{[head | tail], depth} | rest], nodes, bytes),
    do: bounded?([{head, depth + 1}, {tail, depth} | rest], nodes - 1, bytes)

  defp bounded?([{value, depth} | rest], nodes, bytes)
       when is_tuple(value) and tuple_size(value) <= 3,
       do: bounded?(Enum.map(Tuple.to_list(value), &{&1, depth + 1}) ++ rest, nodes - 1, bytes)

  defp bounded?([{value, _depth} | rest], nodes, bytes) when is_binary(value),
    do: bounded?(rest, nodes - 1, bytes - byte_size(value))

  defp bounded?([{value, _depth} | rest], nodes, bytes)
       when is_atom(value) or value == [] or
              (is_integer(value) and value in 0..18_446_744_073_709_551_615),
       do: bounded?(rest, nodes - 1, bytes)

  defp bounded?(_pending, _nodes, _bytes), do: false
end
