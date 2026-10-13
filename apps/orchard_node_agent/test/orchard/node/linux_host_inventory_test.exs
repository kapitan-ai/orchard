defmodule Orchard.Node.LinuxHostInventoryTest do
  use ExUnit.Case, async: false

  alias Orchard.Cluster.V1.{AcceleratorProviderObservation, StatusResponse}
  alias Orchard.Node.LinuxHostInventory

  @fixture_root Path.expand("../../fixtures/linux_host_inventory", __DIR__)
  @observed_at 1_789_743_600_000

  test "collects bounded provider-neutral host facts and distinct vendor evidence" do
    observation = observe()

    assert observation.schema_version == 1
    assert observation.observed_at_unix_ms == @observed_at
    assert observation.authority == :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY

    assert observation.cpu.evidence.state == :HOST_EVIDENCE_STATE_OBSERVED
    assert observation.cpu.architecture == "x86_64"
    assert observation.cpu.logical_processor_count == 32
    assert observation.cpu.core_count == 32
    assert observation.cpu.socket_count == 4

    assert observation.memory.physical_bytes == 270_183_583_744
    assert observation.memory.available_bytes == 266_310_631_424
    assert observation.disk.mount_point == "/"
    assert observation.disk.filesystem == "ext4"

    assert observation.platform.os_id == "ubuntu"
    assert observation.platform.os_version == "24.04"
    assert observation.platform.kernel_release == "6.8.0-139-generic"
    assert observation.platform.libc_name == "glibc"
    assert observation.platform.libc_version == "2.39"
    assert observation.platform.systemd_version == "255"
    assert observation.platform.cgroup_mode == "v2"

    assert Enum.map(observation.network.interfaces, & &1.name) == ["lo", "eth0"]

    nvidia = provider(observation, :ACCELERATOR_VENDOR_NVIDIA)
    amd = provider(observation, :ACCELERATOR_VENDOR_AMD)

    assert nvidia.evidence.state == :HOST_EVIDENCE_STATE_OBSERVED
    assert nvidia.visibility_filter == "GPU-aaaaaaaa-1111-2222-3333-444444444444"
    assert Enum.map(nvidia.devices, & &1.stable_id) == fixture_nvidia_ids()
    assert Enum.map(nvidia.devices, & &1.pci_address) == ["0000:06:10.0", "0000:06:11.0"]
    assert Enum.map(nvidia.devices, & &1.numa_node) == ["0", "0"]

    assert nvidia.runtime.name == "cuda"
    assert nvidia.runtime.version == "13.0"
    assert nvidia.runtime.evidence.source == "nvcc"
    assert nvidia.runtime.evidence.state == :HOST_EVIDENCE_STATE_OBSERVED

    assert amd.evidence.state == :HOST_EVIDENCE_STATE_OBSERVED
    assert [%{stable_id: "0x1234", driver_version: "6.8.5"}] = amd.devices
    assert amd.runtime.name == "rocm"
    assert amd.runtime.version == "6.3.0"
    assert amd.runtime.evidence.source == "/opt/rocm/.info/version"
    assert amd.runtime.evidence.state == :HOST_EVIDENCE_STATE_OBSERVED

    refute Map.has_key?(Map.from_struct(observation), :schedulable_capacity)
    refute Map.has_key?(Map.from_struct(observation), :worker_units)
    refute Map.has_key?(Map.from_struct(observation), :allocations)
  end

  test "stable accelerator identity survives repeated observations while freshness advances" do
    first = observe(now_ms: @observed_at)
    second = observe(now_ms: @observed_at + 60_000)

    assert provider(first, :ACCELERATOR_VENDOR_NVIDIA).devices
           |> Enum.map(& &1.stable_id) ==
             provider(second, :ACCELERATOR_VENDOR_NVIDIA).devices
             |> Enum.map(& &1.stable_id)

    assert first.observed_at_unix_ms != second.observed_at_unix_ms

    assert Enum.all?(second.accelerator_providers, fn provider ->
             provider.evidence.observed_at_unix_ms == second.observed_at_unix_ms
           end)
  end

  test "missing tools, permission denial, malformed output, and partial vendor data stay explicit" do
    run = fn
      "lscpu", _args ->
        {:ok, "not-json"}

      "findmnt", _args ->
        {:error, :permission_denied}

      "ip", _args ->
        {:ok, "{}"}

      "nvidia-smi", ["--query-gpu=" <> _rest, _format] ->
        {:ok, fixture("nvidia-query.csv") <> "invalid row\n"}

      "nvcc", ["--version"] ->
        {:ok, fixture("nvcc.txt")}

      "rocm-smi", _args ->
        {:error, :missing_tool}

      tool, args ->
        fixture_run(tool, args)
    end

    read = fn
      "/proc/meminfo" -> {:error, :eacces}
      "/opt/rocm/.info/version" -> {:error, :enoent}
      path -> fixture_read(path)
    end

    observation = observe(run: run, read: read)

    assert observation.cpu.evidence.state == :HOST_EVIDENCE_STATE_ERROR
    assert observation.cpu.evidence.error_code == "malformed_output"
    assert observation.memory.evidence.state == :HOST_EVIDENCE_STATE_ERROR
    assert observation.memory.evidence.error_code == "eacces"
    assert observation.disk.evidence.error_code == "permission_denied"
    assert observation.network.evidence.state == :HOST_EVIDENCE_STATE_ERROR

    nvidia = provider(observation, :ACCELERATOR_VENDOR_NVIDIA)
    assert nvidia.evidence.state == :HOST_EVIDENCE_STATE_PARTIAL
    assert nvidia.evidence.error_code == "malformed_entries"
    assert Enum.map(nvidia.devices, & &1.stable_id) == fixture_nvidia_ids()

    amd = provider(observation, :ACCELERATOR_VENDOR_AMD)
    assert amd.evidence.state == :HOST_EVIDENCE_STATE_ABSENT
    assert amd.evidence.error_code == "missing_tool"
    assert amd.devices == []
    assert amd.runtime.evidence.state == :HOST_EVIDENCE_STATE_ABSENT
  end

  test "duplicate stable identities fail closed instead of inventing distinct devices" do
    duplicate =
      fixture("nvidia-query.csv")
      |> String.replace(
        "GPU-bbbbbbbb-1111-2222-3333-444444444444",
        "GPU-aaaaaaaa-1111-2222-3333-444444444444"
      )

    run = fn
      "nvidia-smi", ["--query-gpu=" <> _rest, _format] -> {:ok, duplicate}
      "nvcc", ["--version"] -> {:ok, fixture("nvcc.txt")}
      tool, args -> fixture_run(tool, args)
    end

    nvidia = observe(run: run) |> provider(:ACCELERATOR_VENDOR_NVIDIA)

    assert nvidia.evidence.state == :HOST_EVIDENCE_STATE_ERROR
    assert nvidia.evidence.error_code == "duplicate_stable_identity"
    assert nvidia.devices == []
  end

  test "installed driver and observed GPUs do not invent CUDA runtime evidence" do
    run = fn
      "nvcc", ["--version"] -> {:error, :missing_tool}
      tool, args -> fixture_run(tool, args)
    end

    nvidia = observe(run: run) |> provider(:ACCELERATOR_VENDOR_NVIDIA)

    assert nvidia.evidence.state == :HOST_EVIDENCE_STATE_OBSERVED
    assert Enum.map(nvidia.devices, & &1.stable_id) == fixture_nvidia_ids()
    assert nvidia.runtime.name == "cuda"
    assert nvidia.runtime.version == ""
    assert nvidia.runtime.evidence.state == :HOST_EVIDENCE_STATE_ABSENT
    assert nvidia.runtime.evidence.error_code == "missing_tool"
  end

  test "malformed AMD entries are omitted and make otherwise valid evidence partial" do
    output =
      fixture("rocm-smi.json")
      |> Jason.decode!()
      |> Map.put("card1", %{"Card series" => "marketing name is not identity"})
      |> Jason.encode!()

    run = fn
      "rocm-smi", _args -> {:ok, output}
      tool, args -> fixture_run(tool, args)
    end

    amd = observe(run: run) |> provider(:ACCELERATOR_VENDOR_AMD)

    assert amd.evidence.state == :HOST_EVIDENCE_STATE_PARTIAL
    assert amd.evidence.error_code == "malformed_entries"
    assert Enum.map(amd.devices, & &1.stable_id) == ["0x1234"]
  end

  test "equivalent padded AMD identities fail closed as duplicates" do
    output =
      fixture("rocm-smi.json")
      |> Jason.decode!()
      |> then(fn entries ->
        duplicate = entries["card0"] |> Map.put("Unique ID", "0x00001234")
        Map.put(entries, "card1", duplicate)
      end)
      |> Jason.encode!()

    run = fn
      "rocm-smi", _args -> {:ok, output}
      tool, args -> fixture_run(tool, args)
    end

    amd = observe(run: run) |> provider(:ACCELERATOR_VENDOR_AMD)

    assert amd.evidence.state == :HOST_EVIDENCE_STATE_ERROR
    assert amd.evidence.error_code == "duplicate_stable_identity"
    assert amd.devices == []
  end

  test "wire-width overflow and UTF-8 boundaries fail closed without breaking status encoding" do
    oversized_cpu =
      fixture("lscpu.json")
      |> Jason.decode!()
      |> update_in(["lscpu"], fn fields ->
        Enum.map(fields, fn
          %{"field" => "CPU(s):"} = field -> %{field | "data" => "4294967296"}
          field -> field
        end)
      end)
      |> Jason.encode!()

    long_model = String.duplicate("a", 255) <> "é"

    nvidia_output =
      fixture("nvidia-query.csv")
      |> String.replace("NVIDIA Fixture A", long_model)
      |> String.replace("NVIDIA Fixture B, 95830", "NVIDIA Fixture B, 17592186044416")

    run = fn
      "lscpu", ["--json"] -> {:ok, oversized_cpu}
      "nvidia-smi", ["--query-gpu=" <> _rest, _format] -> {:ok, nvidia_output}
      tool, args -> fixture_run(tool, args)
    end

    observation = observe(run: run)
    nvidia = provider(observation, :ACCELERATOR_VENDOR_NVIDIA)

    assert observation.cpu.evidence.state == :HOST_EVIDENCE_STATE_ERROR
    assert nvidia.evidence.state == :HOST_EVIDENCE_STATE_PARTIAL
    assert [%{model_name: model_name}] = nvidia.devices
    assert String.valid?(model_name)
    assert byte_size(model_name) <= 256
    assert LinuxHostInventory.bounded_string(<<255>>) == ""

    response = %StatusResponse{host_inventory: observation}
    assert response == response |> StatusResponse.encode() |> StatusResponse.decode()
  end

  test "malformed network addresses and successful invalid platform text remain partial" do
    malformed_network =
      fixture("ip-address.json")
      |> Jason.decode!()
      |> put_in([Access.at(0), "addr_info", Access.at(0), "prefixlen"], 999)
      |> Jason.encode!()

    run = fn
      "ip", ["--json", "address", "show"] -> {:ok, malformed_network}
      "ldd", ["--version"] -> {:ok, "unexpected output\n"}
      "systemd", ["--version"] -> {:ok, "unexpected output\n"}
      tool, args -> fixture_run(tool, args)
    end

    observation = observe(run: run)

    assert observation.network.evidence.state == :HOST_EVIDENCE_STATE_PARTIAL
    assert hd(observation.network.interfaces).addresses == []
    assert observation.platform.evidence.state == :HOST_EVIDENCE_STATE_PARTIAL
    assert observation.platform.libc_version == ""
    assert observation.platform.systemd_version == ""
  end

  test "malformed disk shape stays local and systemd evidence remains bounded" do
    long_version = String.duplicate("9", 100_000)

    run = fn
      "findmnt", _args -> {:ok, ~s({"filesystems":[42]})}
      "systemd", ["--version"] -> {:ok, "systemd #{long_version}\n"}
      tool, args -> fixture_run(tool, args)
    end

    observation = observe(run: run)

    assert observation.disk.evidence.state == :HOST_EVIDENCE_STATE_ERROR
    assert observation.disk.evidence.error_code == "malformed_output"
    assert observation.cpu.evidence.state == :HOST_EVIDENCE_STATE_OBSERVED
    assert observation.network.evidence.state == :HOST_EVIDENCE_STATE_OBSERVED
    assert byte_size(observation.platform.systemd_version) == 256

    response = %StatusResponse{host_inventory: observation}
    assert response == response |> StatusResponse.encode() |> StatusResponse.decode()
  end

  test "command timeout terminates the observed operating-system process" do
    pid_path =
      Path.join(System.tmp_dir!(), "orchard-kap80-probe-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(pid_path) end)

    script = ~S(echo $$ > "$1"; exec sleep 30)

    assert {:error, :command_timeout} =
             LinuxHostInventory.run_command("sh", ["-c", script, "sh", pid_path], 100)

    os_pid = pid_path |> File.read!() |> String.trim()
    refute File.exists?("/proc/#{os_pid}")
  end

  test "output limit leaves TERM-ignoring probe under guardian KILL escalation" do
    pid_path =
      Path.join(System.tmp_dir!(), "orchard-kap80-output-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(pid_path) end)

    script =
      ~s(trap '' TERM; echo $$ > "$1"; head -c 1048577 /dev/zero; exec sleep 30)

    assert {:error, :output_too_large} =
             LinuxHostInventory.run_command("sh", ["-c", script, "sh", pid_path], 200)

    os_pid = pid_path |> File.read!() |> String.trim()
    assert await_process_exit(os_pid)
  end

  test "Ubuntu 26.04 profile explicitly selects the GNU-prefixed command guardian" do
    tools =
      Path.join(
        System.tmp_dir!(),
        "orchard-kap78-coreutils-#{System.unique_integer([:positive])}"
      )

    original_path = System.get_env("PATH")
    original_prefix = System.get_env("ORCHARD_LINUX_COREUTILS_PREFIX")
    File.mkdir_p!(tools)
    File.cp!(System.find_executable("timeout"), Path.join(tools, "gnutimeout"))
    File.cp!(System.find_executable("echo"), Path.join(tools, "probe"))

    on_exit(fn ->
      File.rm_rf!(tools)
      restore_env("PATH", original_path)
      restore_env("ORCHARD_LINUX_COREUTILS_PREFIX", original_prefix)
    end)

    System.put_env("PATH", tools)
    System.put_env("ORCHARD_LINUX_COREUTILS_PREFIX", "gnu")

    assert {:ok, "observed\n"} = LinuxHostInventory.run_command("probe", ["observed"], 1_000)

    System.put_env("ORCHARD_LINUX_COREUTILS_PREFIX", "unsupported")
    assert {:error, :missing_tool} = LinuxHostInventory.run_command("probe", [], 1_000)
  end

  defp observe(overrides \\ []) do
    defaults = [
      now_ms: @observed_at,
      run: &fixture_run/2,
      read: &fixture_read/1,
      env: fn
        "CUDA_VISIBLE_DEVICES" -> "GPU-aaaaaaaa-1111-2222-3333-444444444444"
        "ROCR_VISIBLE_DEVICES" -> nil
      end,
      disk_path: "/var/lib/orchard/node"
    ]

    LinuxHostInventory.observe(Keyword.merge(defaults, overrides))
  end

  defp fixture_run("lscpu", ["--json"]), do: {:ok, fixture("lscpu.json")}

  defp fixture_run("findmnt", [
         "--json",
         "--bytes",
         "--output",
         "TARGET,FSTYPE,SIZE,AVAIL",
         "--target",
         _path
       ]),
       do: {:ok, fixture("findmnt.json")}

  defp fixture_run("uname", ["-r"]), do: {:ok, "6.8.0-139-generic\n"}
  defp fixture_run("uname", ["-m"]), do: {:ok, "x86_64\n"}
  defp fixture_run("ldd", ["--version"]), do: {:ok, "ldd (Ubuntu GLIBC 2.39) 2.39\n"}
  defp fixture_run("systemd", ["--version"]), do: {:ok, "systemd 255 (255.4)\n"}
  defp fixture_run("ip", ["--json", "address", "show"]), do: {:ok, fixture("ip-address.json")}

  defp fixture_run("nvidia-smi", ["--query-gpu=" <> _rest, _format]),
    do: {:ok, fixture("nvidia-query.csv")}

  defp fixture_run("nvcc", ["--version"]), do: {:ok, fixture("nvcc.txt")}
  defp fixture_run("rocm-smi", _args), do: {:ok, fixture("rocm-smi.json")}

  defp fixture_read("/etc/os-release"), do: {:ok, fixture("os-release")}
  defp fixture_read("/proc/meminfo"), do: {:ok, fixture("meminfo")}
  defp fixture_read("/sys/fs/cgroup/cgroup.controllers"), do: {:ok, "cpu memory pids\n"}
  defp fixture_read("/sys/bus/pci/devices/0000:06:10.0/numa_node"), do: {:ok, "0\n"}
  defp fixture_read("/sys/bus/pci/devices/0000:06:11.0/numa_node"), do: {:ok, "0\n"}
  defp fixture_read("/opt/rocm/.info/version"), do: {:ok, "6.3.0\n"}
  defp fixture_read(_path), do: {:error, :enoent}

  defp fixture(name), do: File.read!(Path.join(@fixture_root, name))

  defp provider(observation, vendor) do
    Enum.find(observation.accelerator_providers, &(&1.vendor == vendor)) ||
      %AcceleratorProviderObservation{}
  end

  defp fixture_nvidia_ids do
    [
      "GPU-aaaaaaaa-1111-2222-3333-444444444444",
      "GPU-bbbbbbbb-1111-2222-3333-444444444444"
    ]
  end

  defp await_process_exit(os_pid, attempts \\ 500)

  defp await_process_exit(_os_pid, 0), do: false

  defp await_process_exit(os_pid, attempts) do
    if File.exists?("/proc/#{os_pid}") do
      Process.sleep(5)
      await_process_exit(os_pid, attempts - 1)
    else
      true
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
