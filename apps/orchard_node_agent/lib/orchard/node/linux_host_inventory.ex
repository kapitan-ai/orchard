defmodule Orchard.Node.LinuxHostInventory do
  @moduledoc """
  Read-only Linux host capability provider (`SPEC.md` §4.1 and §4.9).

  This is a platform adapter selected only by explicit configuration. Every
  value is bounded observation evidence; the envelope contains no worker unit,
  allocation, device binding, scheduling, readiness, or custody state.

  Probes run allowlisted absolute executables under a verified GNU `timeout`
  guardian (see `Orchard.Node.HostInventory.Command`). Sections run concurrently
  under their own time budget, so one hung probe affects only its section.
  Accelerator probes run only for explicitly enabled vendors.
  """

  @behaviour Orchard.Node.HostInventory.Provider

  alias Orchard.Cluster.V1.{
    AcceleratorProviderObservation,
    AcceleratorRuntimeObservation,
    HostCpuObservation,
    HostDiskObservation,
    HostInventoryObservation,
    HostMemoryObservation,
    HostNetworkAddressObservation,
    HostNetworkInterfaceObservation,
    HostNetworkObservation,
    HostPlatformObservation
  }

  alias Orchard.Node.HostInventory.Command
  alias Orchard.Node.LinuxHostInventory.{Amd, Nvidia, Values}
  alias Orchard.RuntimeEndpoint.HostInventory, as: InventoryBound

  @tools %{
    lscpu: ["/usr/bin/lscpu"],
    findmnt: ["/usr/bin/findmnt"],
    ip: ["/usr/sbin/ip", "/usr/bin/ip"],
    uname: ["/usr/bin/uname"],
    ldd: ["/usr/bin/ldd"],
    systemctl: ["/usr/bin/systemctl"],
    nvidia_smi: ["/usr/bin/nvidia-smi"],
    nvcc: ["/usr/local/cuda/bin/nvcc", "/usr/bin/nvcc"],
    rocm_smi: ["/opt/rocm/bin/rocm-smi", "/usr/bin/rocm-smi"]
  }
  @guardians ["/usr/bin/timeout"]
  @max_file_bytes 65_536
  @max_interfaces 64
  @max_addresses 16
  @default_section_timeout_ms 10_000
  @sections [:cpu, :memory, :disk, :platform, :network, :nvidia, :amd]

  @type probe_result :: {:ok, binary()} | {:error, atom()}
  @type context :: %{
          now_ms: non_neg_integer(),
          read: (String.t() -> probe_result()),
          run: (atom(), [String.t()] -> probe_result()),
          env: (String.t() -> String.t() | nil),
          disk_path: String.t() | nil,
          accelerators: [:nvidia | :amd]
        }

  @impl true
  @spec observe(keyword()) :: HostInventoryObservation.t()
  def observe(opts \\ []) do
    context = context(opts)
    section_timeout_ms = Keyword.get(opts, :section_timeout_ms, @default_section_timeout_ms)

    sections =
      @sections
      |> Task.async_stream(&{&1, section(&1, context)},
        timeout: section_timeout_ms,
        on_timeout: :kill_task,
        max_concurrency: length(@sections)
      )
      |> Enum.zip(@sections)
      |> Map.new(fn
        {{:ok, result}, _name} -> result
        {{:exit, _reason}, name} -> {name, section_error(name, context.now_ms, "section_timeout")}
      end)

    %HostInventoryObservation{
      schema_version: InventoryBound.schema_version(),
      observed_at_unix_ms: context.now_ms,
      authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY,
      cpu: sections.cpu,
      memory: sections.memory,
      disk: sections.disk,
      platform: sections.platform,
      network: sections.network,
      accelerator_providers: [sections.nvidia, sections.amd]
    }
  end

  @impl true
  @spec error_observation(non_neg_integer(), String.t()) :: HostInventoryObservation.t()
  def error_observation(now_ms, error_code) do
    sections = Map.new(@sections, &{&1, section_error(&1, now_ms, error_code)})

    %HostInventoryObservation{
      schema_version: InventoryBound.schema_version(),
      observed_at_unix_ms: now_ms,
      authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY,
      cpu: sections.cpu,
      memory: sections.memory,
      disk: sections.disk,
      platform: sections.platform,
      network: sections.network,
      accelerator_providers: [sections.nvidia, sections.amd]
    }
  end

  defp context(opts) do
    %{
      now_ms: Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end),
      read: Keyword.get(opts, :read, &read_bounded/1),
      run: Keyword.get_lazy(opts, :run, fn -> guarded_runner(opts) end),
      env: Keyword.get(opts, :env, &System.get_env/1),
      disk_path: Keyword.get(opts, :disk_path),
      accelerators: Keyword.get(opts, :accelerators, [])
    }
  end

  defp guarded_runner(opts) do
    guardian = Command.guardian(Keyword.get(opts, :guardian_candidates, @guardians))
    command_opts = Keyword.get(opts, :command, [])

    fn tool, args ->
      with {:ok, guardian_path} <- guardian,
           {:ok, executable} <- Command.resolve(Map.fetch!(@tools, tool)) do
        Command.run(guardian_path, executable, args, command_opts)
      end
    end
  end

  defp read_bounded(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_file_bytes + 1)) do
      {:ok, data} when is_binary(data) and byte_size(data) > @max_file_bytes ->
        {:error, :output_too_large}

      {:ok, data} when is_binary(data) ->
        {:ok, data}

      {:ok, :eof} ->
        {:ok, ""}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp section(:cpu, context), do: cpu(context)
  defp section(:memory, context), do: memory(context)
  defp section(:disk, context), do: disk(context)
  defp section(:platform, context), do: platform(context)
  defp section(:network, context), do: network(context)
  defp section(:nvidia, context), do: accelerator(:nvidia, context)
  defp section(:amd, context), do: accelerator(:amd, context)

  defp section_error(name, now_ms, code) do
    evidence = Values.evidence(:error, source(name), now_ms, code)
    empty_section(name, evidence)
  end

  defp empty_section(:cpu, evidence), do: %HostCpuObservation{evidence: evidence}
  defp empty_section(:memory, evidence), do: %HostMemoryObservation{evidence: evidence}
  defp empty_section(:disk, evidence), do: %HostDiskObservation{evidence: evidence}
  defp empty_section(:platform, evidence), do: %HostPlatformObservation{evidence: evidence}
  defp empty_section(:network, evidence), do: %HostNetworkObservation{evidence: evidence}

  defp empty_section(:nvidia, evidence),
    do: empty_provider(:ACCELERATOR_VENDOR_NVIDIA, "cuda", evidence)

  defp empty_section(:amd, evidence),
    do: empty_provider(:ACCELERATOR_VENDOR_AMD, "rocm", evidence)

  defp empty_provider(vendor, runtime_name, evidence) do
    %AcceleratorProviderObservation{
      evidence: evidence,
      vendor: vendor,
      runtime: %AcceleratorRuntimeObservation{evidence: evidence, name: runtime_name}
    }
  end

  defp source(:cpu), do: "lscpu --json"
  defp source(:memory), do: "/proc/meminfo"
  defp source(:disk), do: "findmnt --json --bytes"
  defp source(:platform), do: "os-release+uname+ldd+systemctl+cgroupfs"
  defp source(:network), do: "ip --json address show"
  defp source(:nvidia), do: "nvidia-smi"
  defp source(:amd), do: "rocm-smi"

  defp failure(name, reason, context) do
    evidence = Values.evidence(Values.failure_state(reason), source(name), context.now_ms, reason)
    empty_section(name, evidence)
  end

  defp malformed(name, context), do: section_error(name, context.now_ms, "malformed_output")

  defp accelerator(vendor, context) do
    if vendor in context.accelerators,
      do: vendor_module(vendor).observe(context),
      else: not_enabled(vendor, context)
  end

  defp vendor_module(:nvidia), do: Nvidia
  defp vendor_module(:amd), do: Amd

  defp not_enabled(vendor, context) do
    evidence = Values.evidence(:absent, source(vendor), context.now_ms, "not_enabled")
    empty_section(vendor, evidence)
  end

  defp cpu(context) do
    with {:ok, output} <- context.run.(:lscpu, ["--json"]),
         {:ok, %{"lscpu" => fields}} when is_list(fields) <- Jason.decode(output) do
      cpu_from_fields(fields, context)
    else
      {:error, reason} when is_atom(reason) -> failure(:cpu, reason, context)
      _malformed -> malformed(:cpu, context)
    end
  end

  defp cpu_from_fields(fields, context) do
    values =
      Enum.reduce(fields, %{}, fn
        %{"field" => field} = entry, acc when is_binary(field) ->
          Map.put(acc, String.trim_trailing(field, ":"), Map.get(entry, "data"))

        _entry, acc ->
          acc
      end)

    logical = Values.uint32(values["CPU(s)"])
    sockets = Values.uint32(values["Socket(s)"])
    cores = Values.multiply_uint32(Values.uint32(values["Core(s) per socket"]), sockets)

    {texts, invalid?} =
      Values.texts(%{
        architecture: values["Architecture"],
        vendor_id: values["Vendor ID"],
        model_name: values["Model name"]
      })

    if is_integer(logical) and logical > 0 and is_integer(cores) and texts.architecture != "" do
      %HostCpuObservation{
        evidence: partial_or_observed(:cpu, invalid?, context),
        architecture: texts.architecture,
        logical_processor_count: logical,
        core_count: cores,
        socket_count: sockets,
        vendor_id: texts.vendor_id,
        model_name: texts.model_name
      }
    else
      malformed(:cpu, context)
    end
  end

  defp partial_or_observed(name, true, context),
    do: Values.evidence(:partial, source(name), context.now_ms, "invalid_value")

  defp partial_or_observed(name, false, context),
    do: Values.evidence(:observed, source(name), context.now_ms)

  defp memory(context) do
    with {:ok, contents} <- context.read.("/proc/meminfo"),
         values = parse_meminfo(contents),
         physical when is_integer(physical) and physical > 0 <- values["MemTotal"],
         available when is_integer(available) <- values["MemAvailable"] do
      %HostMemoryObservation{
        evidence: Values.evidence(:observed, source(:memory), context.now_ms),
        physical_bytes: physical,
        available_bytes: available,
        swap_total_bytes: values["SwapTotal"] || 0,
        swap_free_bytes: values["SwapFree"] || 0
      }
    else
      {:error, reason} when is_atom(reason) -> failure(:memory, reason, context)
      _malformed -> malformed(:memory, context)
    end
  end

  defp parse_meminfo(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, values ->
      with [_, key, kib] <- Regex.run(~r/^([A-Za-z]+):\s+([0-9]+)\s+kB$/, line),
           kib when is_integer(kib) <- Values.uint64(kib),
           bytes when is_integer(bytes) <- Values.uint64(kib * 1024) do
        Map.put(values, key, bytes)
      else
        _other -> values
      end
    end)
  end

  defp disk(%{disk_path: nil} = context),
    do: %HostDiskObservation{
      evidence: Values.evidence(:absent, source(:disk), context.now_ms, "not_configured")
    }

  defp disk(context) do
    args = [
      "--json",
      "--bytes",
      "--output",
      "TARGET,FSTYPE,SIZE,AVAIL",
      "--target",
      context.disk_path
    ]

    with {:ok, output} <- context.run.(:findmnt, args),
         {:ok, %{"filesystems" => [filesystem | _]}} when is_map(filesystem) <-
           Jason.decode(output),
         total when is_integer(total) and total > 0 <- Values.uint64(filesystem["size"]),
         available when is_integer(available) <- Values.uint64(filesystem["avail"]),
         {:ok, mount_point} when mount_point != "" <- Values.text(filesystem["target"]),
         {:ok, fstype} when fstype != "" <- Values.text(filesystem["fstype"]) do
      %HostDiskObservation{
        evidence: Values.evidence(:observed, source(:disk), context.now_ms),
        mount_point: mount_point,
        filesystem: fstype,
        total_bytes: total,
        available_bytes: available
      }
    else
      {:error, reason} when is_atom(reason) -> failure(:disk, reason, context)
      _malformed -> malformed(:disk, context)
    end
  end

  defp platform(context) do
    os_release = read_os_release(context)
    kernel = first_line(context.run.(:uname, ["-r"]))
    architecture = first_line(context.run.(:uname, ["-m"]))
    libc = first_line(context.run.(:ldd, ["--version"]))
    systemd = first_line(context.run.(:systemctl, ["--version"]))
    cgroup = cgroup_mode(context)

    {texts, invalid?} =
      Values.texts(%{
        os_id: os_value(os_release, "ID"),
        os_name: os_value(os_release, "PRETTY_NAME"),
        os_version: os_value(os_release, "VERSION_ID"),
        kernel_release: ok_value(kernel),
        architecture: ok_value(architecture),
        libc_name: libc_name(libc),
        libc_version: capture(libc, ~r/([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$/),
        systemd_version: capture(systemd, ~r/^systemd\s+([0-9]+)/),
        cgroup_mode: ok_value(cgroup)
      })

    complete? =
      not invalid? and
        Enum.all?(
          [os_release, kernel, architecture, libc, systemd, cgroup],
          &match?({:ok, _}, &1)
        ) and
        Enum.all?(Map.values(texts), &(&1 != ""))

    evidence =
      if complete?,
        do: Values.evidence(:observed, source(:platform), context.now_ms),
        else: Values.evidence(:partial, source(:platform), context.now_ms, "platform_partial")

    struct(HostPlatformObservation, Map.put(texts, :evidence, evidence))
  end

  defp read_os_release(context) do
    with {:ok, contents} <- context.read.("/etc/os-release") do
      values =
        contents
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, &put_os_release_value/2)

      if values["ID"] && values["VERSION_ID"],
        do: {:ok, values},
        else: {:error, :malformed_output}
    end
  end

  defp put_os_release_value(line, values) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> Map.put(values, key, value |> String.trim() |> String.trim("\""))
      _other -> values
    end
  end

  defp first_line({:ok, output}) do
    case output |> String.split("\n", trim: true) |> List.first() do
      nil -> {:error, :malformed_output}
      line -> {:ok, String.trim(line)}
    end
  end

  defp first_line(error), do: error

  defp cgroup_mode(context) do
    case context.read.("/sys/fs/cgroup/cgroup.controllers") do
      {:ok, _contents} -> {:ok, "v2"}
      {:error, :enoent} -> {:ok, "v1_or_unavailable"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp os_value({:ok, values}, key), do: values[key]
  defp os_value(_result, _key), do: nil
  defp ok_value({:ok, value}), do: value
  defp ok_value(_result), do: nil

  defp libc_name({:ok, line}),
    do: if(String.contains?(String.downcase(line), "glibc"), do: "glibc", else: "unknown")

  defp libc_name(_result), do: nil

  defp capture({:ok, line}, regex) do
    case Regex.run(regex, line) do
      [_, value] -> value
      _other -> nil
    end
  end

  defp capture(_result, _regex), do: nil

  defp network(context) do
    with {:ok, output} <- context.run.(:ip, ["--json", "address", "show"]),
         {:ok, interfaces} when is_list(interfaces) <- Jason.decode(output) do
      {parsed, invalid} = parse_interfaces(interfaces)

      evidence =
        if invalid == 0,
          do: Values.evidence(:observed, source(:network), context.now_ms),
          else: Values.evidence(:partial, source(:network), context.now_ms, "malformed_entries")

      %HostNetworkObservation{evidence: evidence, interfaces: parsed}
    else
      {:error, reason} when is_atom(reason) -> failure(:network, reason, context)
      _malformed -> malformed(:network, context)
    end
  end

  defp parse_interfaces(interfaces) do
    retained = Enum.take(interfaces, @max_interfaces)
    truncated = length(interfaces) - length(retained)

    {parsed, invalid} =
      Enum.reduce(retained, {[], truncated}, fn interface, {parsed, invalid} ->
        case parse_interface(interface) do
          {:ok, observation, discarded} -> {[observation | parsed], invalid + discarded}
          :error -> {parsed, invalid + 1}
        end
      end)

    {Enum.reverse(parsed), invalid}
  end

  defp parse_interface(%{"ifname" => name, "ifindex" => index} = interface) do
    {addresses, discarded} = parse_addresses(Map.get(interface, "addr_info"))

    {texts, invalid?} =
      Values.texts(%{
        name: name,
        oper_state: interface["operstate"],
        link_type: interface["link_type"],
        hardware_address: interface["address"]
      })

    with false <- invalid?,
         true <- texts.name != "",
         index when is_integer(index) <- Values.uint32(index),
         mtu when is_integer(mtu) <- Values.uint32(interface["mtu"]) do
      observation =
        struct(
          HostNetworkInterfaceObservation,
          Map.merge(texts, %{index: index, mtu: mtu, addresses: addresses})
        )

      {:ok, observation, discarded}
    else
      _invalid -> :error
    end
  end

  defp parse_interface(_interface), do: :error

  defp parse_addresses(nil), do: {[], 0}

  defp parse_addresses(entries) when is_list(entries) do
    retained = Enum.take(entries, @max_addresses)

    {parsed, discarded} =
      Enum.reduce(retained, {[], length(entries) - length(retained)}, fn entry,
                                                                         {parsed, discarded} ->
        case parse_address(entry) do
          {:ok, address} -> {[address | parsed], discarded}
          :error -> {parsed, discarded + 1}
        end
      end)

    {Enum.reverse(parsed), discarded}
  end

  defp parse_addresses(_entries), do: {[], 1}

  defp parse_address(%{"family" => family, "local" => address} = entry)
       when family in ["inet", "inet6"] and is_binary(address) do
    with {:ok, parsed} <- :inet.parse_strict_address(String.to_charlist(address)),
         true <- address_family(parsed) == family,
         prefix when is_integer(prefix) <- Values.uint32(entry["prefixlen"]),
         true <- prefix <= max_prefix(family),
         {:ok, scope} <- Values.text(entry["scope"]) do
      {:ok,
       %HostNetworkAddressObservation{
         family: family,
         address: address,
         prefix_length: prefix,
         scope: scope
       }}
    else
      _invalid -> :error
    end
  end

  defp parse_address(_entry), do: :error

  defp address_family({_, _, _, _}), do: "inet"
  defp address_family({_, _, _, _, _, _, _, _}), do: "inet6"
  defp max_prefix("inet"), do: 32
  defp max_prefix("inet6"), do: 128
end
