defmodule Orchard.RuntimeEndpoint.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1, as: Proto
  alias Orchard.RuntimeEndpoint.{Diagnostics, Observation}

  @now 1_800_000_000_000
  @time @now - 1234

  test "SPEC.md §4.6.1 CPU-only observations are redacted counts, not capacity" do
    result = project(inventory())
    assert result.authority == "observation_only"
    assert result.runtime.health == "ready"
    assert result.runtime.worker_state == "busy"
    assert result.runtime.age_ms == 1234
    assert result.inventory.status == "observed"

    assert result.inventory.cpu == %{
             status: "observed",
             source: "cpu_probe",
             count: 12,
             observed_at_unix_ms: @time,
             age_ms: 1234
           }

    assert result.inventory.network.count == 1
    assert result.inventory.nvidia.status == "absent"
    assert result.inventory.nvidia.count == nil
    assert result.inventory.amd.count == nil
    assert result.inventory.memory.count == nil
    refute Map.has_key?(result, :capacity)
    refute Map.has_key?(result, :scheduling)
  end

  test "NVIDIA and AMD retain distinct provenance without identities or qualification" do
    raw = %{inventory() | accelerator_providers: [provider(:nvidia, 1), provider(:amd, 2)]}
    result = project(raw)
    assert result.inventory.nvidia.count == 1
    assert result.inventory.nvidia.source == "nvidia_probe"
    assert result.inventory.amd.count == 2
    assert result.inventory.amd.source == "amd_probe"
    refute Jason.encode!(result) =~ "sensitive"

    [nvidia, amd] = raw.accelerator_providers
    [device] = nvidia.devices
    stale = %{device | evidence: %{device.evidence | observed_at_unix_ms: @now - 195_001}}
    result = project(%{raw | accelerator_providers: [%{nvidia | devices: [stale]}, amd]})
    assert result.inventory.nvidia.count == nil
    assert result.inventory.amd.count == 2
  end

  for {vendor, opposite_source} <- [nvidia: "rocm-smi", amd: "nvidia-smi"] do
    test "SPEC.md §4.6.1 #{vendor} counts require the provider's vendor-specific source" do
      vendor = unquote(vendor)
      provider = provider(vendor, 2)

      for count <- [2, 0] do
        provider = %{provider | devices: Enum.take(provider.devices, count)}
        raw = %{inventory() | accelerator_providers: [provider]}
        assert project(raw).inventory[vendor].count == count

        for source <- [
              unquote(opposite_source),
              "",
              nil,
              "unknown",
              "lscpu --json",
              "sensitive source"
            ] do
          poisoned = %{provider | evidence: %{provider.evidence | source: source}}
          result = project(%{raw | accelerator_providers: [poisoned]})
          assert result.inventory[vendor].count == nil
          refute Jason.encode!(result) =~ "sensitive"
        end
      end
    end

    test "SPEC.md §4.6.1 every #{vendor} device requires the vendor-specific source" do
      vendor = unquote(vendor)
      provider = provider(vendor, 2)
      raw = %{inventory() | accelerator_providers: [provider]}

      for index <- [0, 1],
          source <- [
            unquote(opposite_source),
            "",
            nil,
            "unknown",
            "/proc/meminfo",
            "sensitive source"
          ] do
        devices =
          List.update_at(provider.devices, index, fn device ->
            %{device | evidence: %{device.evidence | source: source}}
          end)

        result = project(%{raw | accelerator_providers: [%{provider | devices: devices}]})
        assert result.inventory[vendor].count == nil
        refute Jason.encode!(result) =~ "sensitive"
      end
    end

    test "matching #{vendor} sources do not override stale, partial or error evidence" do
      vendor = unquote(vendor)
      provider = provider(vendor, 2)

      for evidence <- [
            %{provider.evidence | state: :HOST_EVIDENCE_STATE_PARTIAL},
            %{provider.evidence | state: :HOST_EVIDENCE_STATE_ERROR},
            %{provider.evidence | observed_at_unix_ms: @now - 195_001}
          ],
          location <- [:provider, :device] do
        changed =
          case location do
            :provider ->
              %{provider | evidence: evidence}

            :device ->
              %{
                provider
                | devices: List.update_at(provider.devices, 1, &%{&1 | evidence: evidence})
              }
          end

        result = project(%{inventory() | accelerator_providers: [changed]})
        assert result.inventory[vendor].count == nil
      end
    end
  end

  for {vendor, opposite_source} <- [nvidia: "amd_probe", amd: "nvidia_probe"],
      json? <- [false, true] do
    test "SPEC.md §4.6.1 normalized #{vendor} counts require matching sources (JSON: #{json?})" do
      vendor = unquote(vendor)
      block = project(%{inventory() | accelerator_providers: [provider(vendor, 2)]})

      for count <- [2, 0] do
        block = put_in(block, [:inventory, vendor, :count], count)
        assert Diagnostics.normalize(block, @now).inventory[vendor].count == count
        json = Jason.decode!(Jason.encode!(block))
        assert Diagnostics.normalize(json, @now).inventory[vendor].count == count

        for source <- [
              unquote(opposite_source),
              :missing,
              nil,
              "unknown",
              "cpu_probe",
              "nvidia-smi",
              "sensitive source"
            ] do
          poisoned =
            update_in(block, [:inventory, vendor], fn section ->
              if source == :missing,
                do: Map.delete(section, :source),
                else: Map.put(section, :source, source)
            end)

          input = if unquote(json?), do: Jason.decode!(Jason.encode!(poisoned)), else: poisoned
          result = Diagnostics.normalize(input, @now)
          assert result.inventory[vendor].count == nil
          assert result.inventory.cpu.count == 12
          refute Jason.encode!(result) =~ "sensitive"
        end
      end
    end
  end

  test "device counts expire at the oldest contributing device timestamp" do
    for vendor <- [:nvidia, :amd] do
      provider = provider(vendor, 1)
      [device] = provider.devices
      device = %{device | evidence: %{device.evidence | observed_at_unix_ms: @now - 195_000}}
      raw = %{inventory() | accelerator_providers: [%{provider | devices: [device]}]}
      result = project(raw)
      assert result.inventory[vendor].count == 1
      assert result.inventory[vendor].observed_at_unix_ms == @now - 195_000
      assert Diagnostics.normalize(result, @now + 1).inventory[vendor].count == nil
    end
  end

  test "old or disabled inventory is absent and missing runtime timestamps are invalid" do
    result = Diagnostics.project(%{}, @now)
    assert result.inventory.status == "absent"
    assert result.inventory.cpu.count == nil
    assert result.runtime.status == "invalid"
    assert result.runtime.health == "unknown"
    assert Diagnostics.normalize(nil, @now) == nil

    for version <- [0, 2, 1.0, "1"] do
      assert Diagnostics.normalize(%{schema_version: version}, @now) == nil
    end
  end

  test "source timestamp boundaries do not manufacture freshness" do
    for {time, status} <- [
          {@now - 195_000, "observed"},
          {@now - 195_001, "stale"},
          {@now + 1, "invalid"},
          {0, "invalid"},
          {-1, "invalid"},
          {"invalid", "invalid"}
        ] do
      result = project(%{inventory() | observed_at_unix_ms: time})
      assert result.inventory.status == status
      if status != "observed", do: assert(result.inventory.cpu.count == nil)
    end

    for time <- [@now - 195_001, @now + 1, 0] do
      cpu = inventory().cpu
      raw = %{inventory() | cpu: %{cpu | evidence: %{cpu.evidence | observed_at_unix_ms: time}}}
      assert project(raw).inventory.cpu.count == nil
      assert project(raw).inventory.network.count == 1
    end

    result = project(inventory())
    aged = Diagnostics.normalize(result, @now + 195_000)
    assert aged.inventory.status == "stale"
    assert aged.inventory.observed_at_unix_ms == @time
    assert aged.inventory.age_ms == 196_234
    assert aged.inventory.cpu.count == nil
    assert aged.runtime.health == "unknown"
    assert aged.runtime.worker_state == "unknown"
  end

  test "runtime timestamp boundaries suppress stale health and lifecycle categories" do
    for {age, status} <- [{15_000, "observed"}, {15_001, "stale"}, {-1, "invalid"}] do
      response = %{
        observed_at: DateTime.from_unix!(@now - age, :millisecond),
        health: %{ready: false},
        worker_state: :WORKER_STATE_FAILED
      }

      result = Diagnostics.project(response, @now).runtime
      assert result.status == status
      assert result.health == if(status == "observed", do: "not_ready", else: "unknown")
      assert result.worker_state == if(status == "observed", do: "failed", else: "unknown")
    end
  end

  test "unknown schema, malformed and oversized nested inventory fail closed" do
    raw = inventory()
    nested = Enum.reduce(1..100, "sensitive", fn _, acc -> [acc] end)

    for invalid <- [
          %{raw | schema_version: 2},
          %{raw | authority: :HOST_INVENTORY_AUTHORITY_UNSPECIFIED},
          %{raw | cpu: %{raw.cpu | model_name: String.duplicate("x", 257)}},
          %{
            raw
            | network: %{raw.network | interfaces: List.duplicate(hd(raw.network.interfaces), 65)}
          },
          %{raw | __unknown_fields__: [{99, 2, String.duplicate("x", 131_073)}]},
          %{raw | cpu: nested},
          %{raw | cpu: List.duplicate([], 100_000)},
          %{raw | cpu: [1 | :improper]},
          %{raw | cpu: %{}},
          %{raw | cpu: %{raw.cpu | logical_processor_count: Integer.pow(2, 100_000)}},
          Map.put(raw, :secret, "sensitive"),
          "sensitive"
        ] do
      result = project(invalid)
      assert result.inventory.status == "invalid"
      assert result.inventory.cpu.count == nil
      assert byte_size(Jason.encode!(result)) < 2048
    end
  end

  test "unknown protobuf fields and sensitive source strings never pass through" do
    raw = %{inventory() | __unknown_fields__: [{99, 2, "sensitive certificate prompt tenant"}]}
    result = project(raw)
    assert result.inventory.cpu.count == 12
    refute Jason.encode!(result) =~ "sensitive"

    cpu = %{raw.cpu | evidence: %{raw.cpu.evidence | source: "sensitive path"}}
    assert project(%{raw | cpu: cpu}).inventory.cpu.source == "unknown"
  end

  test "normalized input has a fixed shape even with malicious unknown nested values" do
    result = project(inventory())
    secret = List.duplicate(%{secret: "sensitive"}, 100_000)
    poisoned = result |> Map.put(:secret, secret) |> put_in([:inventory, :cpu, :secret], secret)
    assert Diagnostics.normalize(poisoned, @now) == result
    assert Diagnostics.normalize(Jason.decode!(Jason.encode!(result)), @now) == result

    assert Diagnostics.project(%{health: secret, worker_state: secret}, @now).runtime.health ==
             "unknown"

    for {key, value} <- [cpu: 0, network: 65, memory: 1, disk: 1, platform: 1] do
      poisoned = put_in(result, [:inventory, key, :count], value)
      assert Diagnostics.normalize(poisoned, @now).inventory[key].count == nil
    end
  end

  test "partial, error and unknown evidence cannot contribute counts" do
    for state <- [
          :HOST_EVIDENCE_STATE_PARTIAL,
          :HOST_EVIDENCE_STATE_ERROR,
          :HOST_EVIDENCE_STATE_ABSENT,
          :HOST_EVIDENCE_STATE_UNSPECIFIED,
          99
        ] do
      raw = inventory()
      raw = %{raw | cpu: %{raw.cpu | evidence: %{raw.cpu.evidence | state: state}}}
      assert project(raw).inventory.cpu.count == nil
    end
  end

  defp project(raw) do
    Diagnostics.project(
      %Observation{
        observed_at: DateTime.from_unix!(@time, :millisecond),
        worker_state: :busy,
        health: %{ready: true, health_message: "sensitive prompt", health_code: "sensitive"},
        host_inventory: raw
      },
      @now
    )
  end

  defp inventory do
    %Proto.HostInventoryObservation{
      schema_version: 1,
      authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY,
      observed_at_unix_ms: @time,
      cpu: %Proto.HostCpuObservation{
        evidence: evidence("lscpu --json"),
        logical_processor_count: 12,
        model_name: "sensitive cpu"
      },
      network: %Proto.HostNetworkObservation{
        evidence: evidence("ip --json address show"),
        interfaces: [
          %Proto.HostNetworkInterfaceObservation{
            name: "sensitive interface",
            hardware_address: "sensitive mac",
            addresses: [
              %Proto.HostNetworkAddressObservation{
                address: "sensitive address"
              }
            ]
          }
        ]
      },
      disk: %Proto.HostDiskObservation{
        evidence: evidence("findmnt --json --bytes"),
        mount_point: "sensitive path",
        total_bytes: 999
      },
      memory: %Proto.HostMemoryObservation{
        evidence: evidence("/proc/meminfo"),
        physical_bytes: 123
      },
      platform: %Proto.HostPlatformObservation{
        evidence: evidence("os-release+uname+ldd+systemctl+cgroupfs"),
        os_name: "sensitive os"
      }
    }
  end

  defp provider(vendor, count) do
    {enum, source} =
      case vendor do
        :nvidia -> {:ACCELERATOR_VENDOR_NVIDIA, "nvidia-smi"}
        :amd -> {:ACCELERATOR_VENDOR_AMD, "rocm-smi"}
      end

    %Proto.AcceleratorProviderObservation{
      vendor: enum,
      evidence: evidence(source),
      visibility_filter: "sensitive env",
      devices:
        Enum.map(1..count, fn _ ->
          %Proto.AcceleratorObservation{
            vendor: enum,
            evidence: evidence(source),
            stable_id: "sensitive UUID",
            pci_address: "sensitive PCI",
            model_name: "sensitive model"
          }
        end)
    }
  end

  defp evidence(source),
    do: %Proto.HostEvidence{
      state: :HOST_EVIDENCE_STATE_OBSERVED,
      source: source,
      observed_at_unix_ms: @time,
      error_code: "sensitive message"
    }
end
