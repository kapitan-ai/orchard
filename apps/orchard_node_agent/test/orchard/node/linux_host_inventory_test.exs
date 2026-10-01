defmodule Orchard.Node.LinuxHostInventoryTest do
  # SPEC.md §4.1 and the linux-node-platform "Linux Inventory Is Observation
  # Only" requirement: bounded provider-neutral observations with distinct
  # NVIDIA and AMD provenance; missing or malformed input is absent or error
  # evidence. All fixtures are synthetic.
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.HostInventoryObservation
  alias Orchard.Node.LinuxHostInventory
  alias Orchard.RuntimeEndpoint.HostInventory, as: InventoryBound

  @fixtures Path.expand("../../fixtures/linux_host_inventory", __DIR__)
  @now 1_789_743_600_000

  test "collects bounded host facts at the configured root without accelerator probes" do
    observation = observe()

    assert %HostInventoryObservation{
             schema_version: 1,
             observed_at_unix_ms: @now,
             authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY
           } = observation

    assert observation.cpu.evidence.state == :HOST_EVIDENCE_STATE_OBSERVED
    assert observation.cpu.architecture == "x86_64"
    assert observation.cpu.logical_processor_count == 16
    assert observation.cpu.core_count == 8
    assert observation.memory.physical_bytes == 67_108_864 * 1024
    assert observation.memory.available_bytes == 33_554_432 * 1024
    assert observation.disk.mount_point == "/srv/orchard"
    assert observation.disk.available_bytes == 500_000_000_000

    assert %{os_id: "ubuntu", os_version: "24.04", kernel_release: "6.8.0-1-fixture"} =
             observation.platform

    assert %{libc_name: "glibc", libc_version: "2.39", systemd_version: "255", cgroup_mode: "v2"} =
             observation.platform

    assert observation.platform.evidence.state == :HOST_EVIDENCE_STATE_OBSERVED
    assert Enum.map(observation.network.interfaces, & &1.name) == ["lo", "eth0"]

    assert [
             %{vendor: :ACCELERATOR_VENDOR_NVIDIA, devices: [], evidence: nvidia},
             %{vendor: :ACCELERATOR_VENDOR_AMD, devices: [], evidence: amd}
           ] = observation.accelerator_providers

    assert {nvidia.state, nvidia.error_code} == {:HOST_EVIDENCE_STATE_ABSENT, "not_enabled"}
    assert {amd.state, amd.error_code} == {:HOST_EVIDENCE_STATE_ABSENT, "not_enabled"}

    calls = received_calls()

    assert {:findmnt,
            [
              "--json",
              "--bytes",
              "--output",
              "TARGET,FSTYPE,SIZE,AVAIL",
              "--target",
              "/srv/orchard/node-identity"
            ]} in calls

    assert {:systemctl, ["--version"]} in calls
    refute Enum.any?(calls, fn {tool, _args} -> tool in [:nvidia_smi, :nvcc, :rocm_smi] end)
  end

  test "missing, denied, malformed, and unguarded probes stay local to their sections" do
    observation =
      observe(
        disk_path: nil,
        read: fn
          "/proc/meminfo" -> {:error, :eacces}
          path -> fixture_read(path)
        end,
        run: fn
          :lscpu, _args -> {:error, :missing_tool}
          :ip, _args -> {:ok, "not json"}
          :systemctl, _args -> {:error, :guardian_unavailable}
          tool, args -> fixture_run(tool, args)
        end
      )

    assert evidence(observation.cpu) == {:HOST_EVIDENCE_STATE_ABSENT, "missing_tool"}
    assert evidence(observation.memory) == {:HOST_EVIDENCE_STATE_ERROR, "eacces"}
    assert evidence(observation.disk) == {:HOST_EVIDENCE_STATE_ABSENT, "not_configured"}
    assert evidence(observation.network) == {:HOST_EVIDENCE_STATE_ERROR, "malformed_output"}
    assert evidence(observation.platform) == {:HOST_EVIDENCE_STATE_PARTIAL, "platform_partial"}
    assert observation.platform.systemd_version == ""
    assert observation.platform.kernel_release == "6.8.0-1-fixture"
    assert observation.cpu.logical_processor_count == 0
  end

  test "oversized values are partial evidence instead of truncated facts" do
    long = String.duplicate("v", 300)

    observation =
      observe(
        run: fn
          :systemctl, _args -> {:ok, "systemd 255 #{long}\n"}
          :lscpu, _args -> {:ok, lscpu_json(%{"Model name" => long})}
          tool, args -> fixture_run(tool, args)
        end
      )

    assert evidence(observation.cpu) == {:HOST_EVIDENCE_STATE_PARTIAL, "invalid_value"}
    assert observation.cpu.model_name == ""
    assert observation.cpu.logical_processor_count == 4
    assert observation.platform.systemd_version == "255"
  end

  test "one hung section is a section timeout while the others are observed" do
    observation =
      observe(
        section_timeout_ms: 200,
        run: fn
          :ip, _args -> Process.sleep(:infinity)
          tool, args -> fixture_run(tool, args)
        end
      )

    assert evidence(observation.network) == {:HOST_EVIDENCE_STATE_ERROR, "section_timeout"}
    assert evidence(observation.cpu) == {:HOST_EVIDENCE_STATE_OBSERVED, ""}
    assert evidence(observation.platform) == {:HOST_EVIDENCE_STATE_OBSERVED, ""}
  end

  test "without a verified GNU guardian no probe runs and command sections are absent" do
    observation =
      LinuxHostInventory.observe(
        now_ms: @now,
        disk_path: "/srv/orchard/node-identity",
        accelerators: [:nvidia, :amd],
        guardian_candidates: [],
        read: &fixture_read/1,
        env: fn _name -> nil end
      )

    for section <- [observation.cpu, observation.disk, observation.network] do
      assert evidence(section) == {:HOST_EVIDENCE_STATE_ABSENT, "guardian_unavailable"}
    end

    assert [nvidia, amd] = observation.accelerator_providers
    assert evidence(nvidia) == {:HOST_EVIDENCE_STATE_ABSENT, "guardian_unavailable"}
    assert evidence(amd) == {:HOST_EVIDENCE_STATE_ABSENT, "guardian_unavailable"}
    assert evidence(observation.memory) == {:HOST_EVIDENCE_STATE_OBSERVED, ""}
  end

  test "a realistic maximum-shape inventory stays within the shared wire bound" do
    interfaces =
      for index <- 1..64 do
        %{
          "ifindex" => index,
          "ifname" => "fixture#{index}",
          "mtu" => 9000,
          "operstate" => "UP",
          "link_type" => "ether",
          "address" => "02:00:00:00:00:01",
          "addr_info" =>
            for address <- 1..16 do
              %{
                "family" => "inet6",
                "local" => "2001:db8:0:#{index}::#{address}",
                "prefixlen" => 64,
                "scope" => "global"
              }
            end
        }
      end

    rows =
      for ordinal <- 0..63 do
        suffix = ordinal |> Integer.to_string() |> String.pad_leading(12, "0")

        "#{ordinal}, GPU-00000000-0000-4000-8000-#{suffix}, 00000000:17:00.0, NVIDIA Fixture GPU, 81920, 570.0.1"
      end

    cards =
      Map.new(0..63, fn ordinal ->
        {"card#{ordinal}",
         %{
           "Unique ID" => "0x#{Integer.to_string(ordinal + 1, 16)}",
           "PCI Bus" => "0000:41:00.0",
           "Card Series" => "AMD Fixture Accelerator",
           "VRAM Total Memory (B)" => "68719476736"
         }}
      end)

    observation =
      observe(
        accelerators: [:nvidia, :amd],
        run: fn
          :ip, _args -> {:ok, Jason.encode!(interfaces)}
          :nvidia_smi, _args -> {:ok, Enum.join(rows, "\n")}
          :rocm_smi, _args -> {:ok, Jason.encode!(cards)}
          tool, args -> fixture_run(tool, args)
        end
      )

    assert length(observation.network.interfaces) == 64
    assert InventoryBound.normalize(observation) == observation
  end

  describe "NVIDIA observations" do
    test "an enabled vendor reports stable identities with topology and distinct runtime evidence" do
      observation =
        observe(
          accelerators: [:nvidia],
          env: fn
            "CUDA_VISIBLE_DEVICES" -> "0,1"
            _name -> nil
          end
        )

      [nvidia, amd] = observation.accelerator_providers

      assert evidence(nvidia) == {:HOST_EVIDENCE_STATE_OBSERVED, ""}
      assert nvidia.visibility_filter == "0,1"
      assert {nvidia.runtime.name, nvidia.runtime.version} == {"cuda", "12.8"}

      assert [
               %{
                 stable_id: "GPU-00000000-0000-4000-8000-000000000001",
                 identity_kind: "nvidia_gpu_uuid",
                 device_ordinal: 0,
                 pci_address: "0000:17:00.0",
                 memory_total_bytes: 85_899_345_920,
                 vendor: :ACCELERATOR_VENDOR_NVIDIA
               },
               %{stable_id: "GPU-00000000-0000-4000-8000-000000000002", device_ordinal: 1}
             ] = nvidia.devices

      assert evidence(amd) == {:HOST_EVIDENCE_STATE_ABSENT, "not_enabled"}
      refute Enum.any?(received_calls(), fn {tool, _args} -> tool == :rocm_smi end)
    end

    test "repeated observations keep the stable identity while observation time advances" do
      first = observe(accelerators: [:nvidia], now_ms: @now)
      second = observe(accelerators: [:nvidia], now_ms: @now + 60_000)

      [first_nvidia, _amd] = first.accelerator_providers
      [second_nvidia, _amd2] = second.accelerator_providers

      assert Enum.map(first_nvidia.devices, & &1.stable_id) ==
               Enum.map(second_nvidia.devices, & &1.stable_id)

      assert second_nvidia.evidence.observed_at_unix_ms == @now + 60_000
    end

    test "duplicate identities fail closed and malformed rows make evidence partial" do
      duplicate =
        "0, GPU-00000000-0000-4000-8000-000000000001, 00000000:17:00.0, A, 1024, 1\n" <>
          "1, GPU-00000000-0000-4000-8000-000000000001, 00000000:18:00.0, B, 1024, 1\n"

      malformed =
        "0, GPU-00000000-0000-4000-8000-000000000001, 00000000:17:00.0, A, 1024, 1\n" <>
          "1, not-a-uuid, 00000000:18:00.0, B, 1024, 1\n"

      [dup, _amd] = nvidia_with(duplicate).accelerator_providers
      [partial, _amd2] = nvidia_with(malformed).accelerator_providers

      assert {evidence(dup), dup.devices} ==
               {{:HOST_EVIDENCE_STATE_ERROR, "duplicate_stable_identity"}, []}

      assert evidence(partial) == {:HOST_EVIDENCE_STATE_PARTIAL, "malformed_entries"}
      assert Enum.map(partial.devices, & &1.device_ordinal) == [0]
    end

    test "an oversized CUDA release is runtime error evidence without losing other sections" do
      release = String.duplicate("1", 300)

      observation =
        observe(
          accelerators: [:nvidia],
          run: fn
            :nvcc, _args -> {:ok, "Cuda compilation tools, release #{release}\n"}
            tool, args -> fixture_run(tool, args)
          end
        )

      [nvidia, _amd] = observation.accelerator_providers

      assert evidence(nvidia.runtime) == {:HOST_EVIDENCE_STATE_ERROR, "malformed_output"}
      assert nvidia.runtime.version == ""
      assert length(nvidia.devices) == 2
      assert evidence(observation.cpu) == {:HOST_EVIDENCE_STATE_OBSERVED, ""}
      assert InventoryBound.normalize(observation) == observation
    end

    test "NUMA topology is a bounded node number and is empty when malformed" do
      numa = fn
        "/sys/bus/pci/devices/0000:17:00.0/numa_node" -> {:ok, "1\n"}
        "/sys/bus/pci/devices/0000:18:00.0/numa_node" -> {:ok, String.duplicate("9", 300)}
        path -> fixture_read(path)
      end

      observation = observe(accelerators: [:nvidia], read: numa)
      [nvidia, _amd] = observation.accelerator_providers

      assert Enum.map(nvidia.devices, & &1.numa_node) == ["1", ""]
      assert InventoryBound.normalize(observation) == observation
    end

    test "missing vendor tooling is absent and a driver without nvcc invents no CUDA runtime" do
      [missing, _amd] =
        observe(
          accelerators: [:nvidia],
          run: fn
            :nvidia_smi, _args -> {:error, :missing_tool}
            tool, args -> fixture_run(tool, args)
          end
        ).accelerator_providers

      [no_runtime, _amd2] =
        observe(
          accelerators: [:nvidia],
          run: fn
            :nvcc, _args -> {:error, :missing_tool}
            tool, args -> fixture_run(tool, args)
          end
        ).accelerator_providers

      assert {evidence(missing), missing.devices} ==
               {{:HOST_EVIDENCE_STATE_ABSENT, "missing_tool"}, []}

      assert length(no_runtime.devices) == 2
      assert evidence(no_runtime.runtime) == {:HOST_EVIDENCE_STATE_ABSENT, "missing_tool"}
      assert no_runtime.runtime.version == ""
    end
  end

  describe "AMD observations" do
    test "an enabled vendor reports its unique identity and ROCm runtime evidence" do
      [nvidia, amd] = observe(accelerators: [:amd]).accelerator_providers

      assert evidence(nvidia) == {:HOST_EVIDENCE_STATE_ABSENT, "not_enabled"}
      assert evidence(amd) == {:HOST_EVIDENCE_STATE_OBSERVED, ""}
      assert {amd.runtime.name, amd.runtime.version} == {"rocm", "6.3.0"}

      assert [
               %{
                 vendor: :ACCELERATOR_VENDOR_AMD,
                 stable_id: "0x1234",
                 identity_kind: "amd_unique_id",
                 device_ordinal: 0,
                 pci_address: "0000:41:00.0",
                 model_name: "AMD Fixture Accelerator",
                 memory_total_bytes: 68_719_476_736,
                 driver_version: "6.8.0-fixture"
               }
             ] = amd.devices
    end

    test "padded equivalent identities fail closed and malformed cards make evidence partial" do
      card = fn id -> %{"Unique ID" => id, "VRAM Total Memory (B)" => "1024"} end

      [_nvidia, duplicate] =
        amd_with(%{"card0" => card.("0x1234"), "card1" => card.("0x0001234")}).accelerator_providers

      [_nvidia2, partial] =
        amd_with(%{"card0" => card.("0x1234"), "card1" => card.("not-hex")}).accelerator_providers

      assert {evidence(duplicate), duplicate.devices} ==
               {{:HOST_EVIDENCE_STATE_ERROR, "duplicate_stable_identity"}, []}

      assert evidence(partial) == {:HOST_EVIDENCE_STATE_PARTIAL, "malformed_entries"}
      assert Enum.map(partial.devices, & &1.stable_id) == ["0x1234"]
    end
  end

  defp amd_with(entries) do
    observe(
      accelerators: [:amd],
      run: fn
        :rocm_smi, _args -> {:ok, Jason.encode!(entries)}
        tool, args -> fixture_run(tool, args)
      end
    )
  end

  defp nvidia_with(csv) do
    observe(
      accelerators: [:nvidia],
      run: fn
        :nvidia_smi, _args -> {:ok, csv}
        tool, args -> fixture_run(tool, args)
      end
    )
  end

  defp evidence(%{evidence: evidence}), do: {evidence.state, evidence.error_code}

  defp lscpu_json(overrides) do
    fields =
      %{
        "Architecture" => "x86_64",
        "CPU(s)" => "4",
        "Core(s) per socket" => "4",
        "Socket(s)" => "1"
      }
      |> Map.merge(overrides)
      |> Enum.map(fn {field, data} -> %{"field" => field <> ":", "data" => data} end)

    Jason.encode!(%{"lscpu" => fields})
  end

  defp observe(opts \\ []) do
    test = self()

    defaults = [
      now_ms: @now,
      disk_path: "/srv/orchard/node-identity",
      read: &fixture_read/1,
      run: fn tool, args ->
        send(test, {:probe, tool, args})
        fixture_run(tool, args)
      end,
      env: fn _name -> nil end
    ]

    defaults |> Keyword.merge(opts) |> LinuxHostInventory.observe()
  end

  defp received_calls(calls \\ []) do
    receive do
      {:probe, tool, args} -> received_calls([{tool, args} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp fixture_read("/proc/meminfo"), do: fixture("meminfo")
  defp fixture_read("/etc/os-release"), do: fixture("os-release")
  defp fixture_read("/sys/fs/cgroup/cgroup.controllers"), do: {:ok, "cpu memory io\n"}
  defp fixture_read("/opt/rocm/.info/version"), do: fixture("rocm-version")
  defp fixture_read(_path), do: {:error, :enoent}

  defp fixture_run(:lscpu, ["--json"]), do: fixture("lscpu.json")
  defp fixture_run(:findmnt, _args), do: fixture("findmnt.json")
  defp fixture_run(:uname, ["-r"]), do: fixture("uname-r")
  defp fixture_run(:uname, ["-m"]), do: fixture("uname-m")
  defp fixture_run(:ldd, ["--version"]), do: fixture("ldd-version.txt")
  defp fixture_run(:systemctl, ["--version"]), do: fixture("systemctl-version.txt")
  defp fixture_run(:ip, ["--json", "address", "show"]), do: fixture("ip-address.json")
  defp fixture_run(:nvidia_smi, _args), do: fixture("nvidia-query.csv")
  defp fixture_run(:nvcc, ["--version"]), do: fixture("nvcc.txt")
  defp fixture_run(:rocm_smi, _args), do: fixture("rocm-smi.json")
  defp fixture_run(_tool, _args), do: {:error, :missing_tool}

  defp fixture(name), do: File.read(Path.join(@fixtures, name))
end
