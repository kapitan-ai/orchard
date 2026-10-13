defmodule Orchard.Node.LinuxHostInventory do
  @moduledoc """
  Read-only Linux host capability provider.

  Every value is bounded observation evidence. The returned envelope contains
  no Worker Unit, allocation, scheduling, runtime-readiness, or custody state.
  """

  alias Orchard.Cluster.V1.{
    AcceleratorProviderObservation,
    AcceleratorRuntimeObservation,
    HostCpuObservation,
    HostDiskObservation,
    HostEvidence,
    HostInventoryObservation,
    HostMemoryObservation,
    HostNetworkAddressObservation,
    HostNetworkInterfaceObservation,
    HostNetworkObservation,
    HostPlatformObservation
  }

  alias Orchard.Node.LinuxHostInventory.{Amd, Nvidia}

  @schema_version 1
  @max_interfaces 64
  @max_addresses 16
  @max_string_bytes 256
  @uint32_max 4_294_967_295
  @uint64_max 18_446_744_073_709_551_615
  @command_timeout_ms 5_000
  @max_command_output_bytes 1_048_576
  @command_kill_grace_ms 250
  @command_guard_kill_ms 1_000

  @type command_result :: {:ok, String.t()} | {:error, atom()}
  @type context :: %{
          now_ms: non_neg_integer(),
          read: (String.t() -> {:ok, binary()} | {:error, atom()}),
          run: (String.t(), [String.t()] -> command_result()),
          env: (String.t() -> String.t() | nil),
          disk_path: String.t()
        }

  @spec observe(keyword()) :: HostInventoryObservation.t()
  def observe(opts \\ []) do
    context = context(opts)

    %HostInventoryObservation{
      schema_version: @schema_version,
      observed_at_unix_ms: context.now_ms,
      authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY,
      cpu: cpu(context),
      memory: memory(context),
      disk: disk(context),
      platform: platform(context),
      network: network(context),
      accelerator_providers: [Nvidia.observe(context), Amd.observe(context)]
    }
  end

  @spec error_observation(non_neg_integer(), String.t()) :: HostInventoryObservation.t()
  def error_observation(now_ms, error_code) do
    error = evidence(:error, "linux_host_inventory", now_ms, error_code)

    %HostInventoryObservation{
      schema_version: @schema_version,
      observed_at_unix_ms: now_ms,
      authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY,
      cpu: %HostCpuObservation{evidence: error},
      memory: %HostMemoryObservation{evidence: error},
      disk: %HostDiskObservation{evidence: error},
      platform: %HostPlatformObservation{evidence: error},
      network: %HostNetworkObservation{evidence: error},
      accelerator_providers: [
        error_accelerator_provider(:ACCELERATOR_VENDOR_NVIDIA, "cuda", error),
        error_accelerator_provider(:ACCELERATOR_VENDOR_AMD, "rocm", error)
      ]
    }
  end

  defp error_accelerator_provider(vendor, runtime_name, evidence) do
    %AcceleratorProviderObservation{
      evidence: evidence,
      vendor: vendor,
      runtime: %AcceleratorRuntimeObservation{
        evidence: evidence,
        name: runtime_name
      }
    }
  end

  @doc "Builds bounded provenance for one host observation section."
  @spec evidence(
          :observed | :absent | :partial | :error,
          String.t(),
          non_neg_integer(),
          String.t()
        ) ::
          HostEvidence.t()
  def evidence(state, source, now_ms, error_code \\ "") do
    %HostEvidence{
      state: evidence_state(state),
      source: bounded_string(source),
      observed_at_unix_ms: now_ms,
      error_code: error_code(error_code)
    }
  end

  @doc "Bounds an observed string to the inventory wire limit."
  @spec bounded_string(term()) :: String.t()
  def bounded_string(value) when is_binary(value) do
    cond do
      not String.valid?(value) -> ""
      byte_size(value) <= @max_string_bytes -> value
      true -> truncate_utf8(value, @max_string_bytes)
    end
  end

  def bounded_string(_value), do: ""

  defp error_code(value) when is_atom(value), do: value |> Atom.to_string() |> bounded_string()
  defp error_code(value) when is_binary(value), do: bounded_string(value)
  defp error_code(_value), do: "malformed_output"

  @doc "Parses a non-negative integer without accepting trailing data."
  @spec non_negative_integer(term()) :: non_neg_integer() | nil
  def non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  def non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _other -> nil
    end
  end

  def non_negative_integer(_value), do: nil

  @doc "Parses an unsigned 32-bit integer without accepting trailing data."
  @spec uint32(term()) :: non_neg_integer() | nil
  def uint32(value), do: bounded_unsigned_integer(value, @uint32_max)

  @doc "Parses an unsigned 64-bit integer without accepting trailing data."
  @spec uint64(term()) :: non_neg_integer() | nil
  def uint64(value), do: bounded_unsigned_integer(value, @uint64_max)

  defp bounded_unsigned_integer(value, maximum) do
    case non_negative_integer(value) do
      integer when is_integer(integer) and integer <= maximum -> integer
      _value -> nil
    end
  end

  defp truncate_utf8(value, size) do
    candidate = binary_part(value, 0, size)
    if String.valid?(candidate), do: candidate, else: truncate_utf8(value, size - 1)
  end

  defp context(opts) do
    %{
      now_ms: Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end),
      read: Keyword.get(opts, :read, &File.read/1),
      run: Keyword.get(opts, :run, &run_command/2),
      env: Keyword.get(opts, :env, &System.get_env/1),
      disk_path: Keyword.get(opts, :disk_path, "/var/lib/orchard/node")
    }
  end

  defp cpu(context) do
    source = "lscpu --json"

    with {:ok, output} <- context.run.("lscpu", ["--json"]),
         {:ok, %{"lscpu" => fields}} when is_list(fields) <- Jason.decode(output) do
      values =
        Enum.reduce(fields, %{}, fn
          %{"field" => field} = entry, values when is_binary(field) ->
            Map.put(values, String.trim_trailing(field, ":"), Map.get(entry, "data"))

          _entry, values ->
            values
        end)

      logical = uint32(values["CPU(s)"])
      sockets = uint32(values["Socket(s)"])
      cores_per_socket = uint32(values["Core(s) per socket"])
      architecture = bounded_string(values["Architecture"])
      cores = multiply_uint32(cores_per_socket, sockets)

      if logical && logical > 0 && cores && architecture != "" do
        %HostCpuObservation{
          evidence: evidence(:observed, source, context.now_ms),
          architecture: architecture,
          logical_processor_count: logical,
          core_count: cores,
          socket_count: sockets || 0,
          vendor_id: bounded_string(values["Vendor ID"]),
          model_name: bounded_string(values["Model name"])
        }
      else
        %HostCpuObservation{
          evidence: evidence(:error, source, context.now_ms, "malformed_output")
        }
      end
    else
      {:error, reason} ->
        %HostCpuObservation{
          evidence: evidence(error_state(reason), source, context.now_ms, reason)
        }

      _other ->
        %HostCpuObservation{
          evidence: evidence(:error, source, context.now_ms, "malformed_output")
        }
    end
  end

  defp memory(context) do
    source = "/proc/meminfo"

    with {:ok, contents} <- context.read.(source),
         values = parse_meminfo(contents),
         physical when is_integer(physical) and physical > 0 <- values["MemTotal"],
         available when is_integer(available) and available >= 0 <- values["MemAvailable"] do
      %HostMemoryObservation{
        evidence: evidence(:observed, source, context.now_ms),
        physical_bytes: physical,
        available_bytes: available,
        swap_total_bytes: values["SwapTotal"] || 0,
        swap_free_bytes: values["SwapFree"] || 0
      }
    else
      {:error, reason} ->
        %HostMemoryObservation{
          evidence: evidence(error_state(reason), source, context.now_ms, reason)
        }

      _other ->
        %HostMemoryObservation{
          evidence: evidence(:error, source, context.now_ms, "malformed_output")
        }
    end
  end

  defp disk(context) do
    source = "findmnt --json --bytes"

    args = [
      "--json",
      "--bytes",
      "--output",
      "TARGET,FSTYPE,SIZE,AVAIL",
      "--target",
      context.disk_path
    ]

    with {:ok, output} <- context.run.("findmnt", args),
         {:ok, %{"filesystems" => [filesystem | _]}} when is_map(filesystem) <-
           Jason.decode(output),
         total when is_integer(total) and total > 0 <- uint64(filesystem["size"]),
         available when is_integer(available) <- uint64(filesystem["avail"]),
         mount_point when mount_point != "" <- bounded_string(filesystem["target"]),
         filesystem_name when filesystem_name != "" <- bounded_string(filesystem["fstype"]) do
      %HostDiskObservation{
        evidence: evidence(:observed, source, context.now_ms),
        mount_point: mount_point,
        filesystem: filesystem_name,
        total_bytes: total,
        available_bytes: available
      }
    else
      {:error, reason} ->
        %HostDiskObservation{
          evidence: evidence(error_state(reason), source, context.now_ms, reason)
        }

      _other ->
        %HostDiskObservation{
          evidence: evidence(:error, source, context.now_ms, "malformed_output")
        }
    end
  end

  defp platform(context) do
    source = "os-release+uname+ldd+systemd+cgroupfs"
    os_release = read_os_release(context)
    kernel = run_value(context, "uname", ["-r"])
    architecture = run_value(context, "uname", ["-m"])
    libc = run_value(context, "ldd", ["--version"])
    systemd = run_value(context, "systemd", ["--version"])
    cgroup = cgroup_mode(context)
    components = [os_release, kernel, architecture, libc, systemd, cgroup]
    values = platform_values(os_release, kernel, architecture, libc, systemd, cgroup)

    state =
      if Enum.all?(components, &match?({:ok, _}, &1)) and
           Enum.all?(Map.values(values), &(&1 != "")),
         do: :observed,
         else: :partial

    %HostPlatformObservation{
      evidence: evidence(state, source, context.now_ms, platform_error_code(state)),
      os_id: values.os_id,
      os_name: values.os_name,
      os_version: values.os_version,
      kernel_release: values.kernel_release,
      architecture: values.architecture,
      libc_name: values.libc_name,
      libc_version: values.libc_version,
      systemd_version: values.systemd_version,
      cgroup_mode: values.cgroup_mode
    }
  end

  defp platform_values(os_release, kernel, architecture, libc, systemd, cgroup) do
    %{
      os_id: os_value(os_release, "ID"),
      os_name: os_value(os_release, "PRETTY_NAME"),
      os_version: os_value(os_release, "VERSION_ID"),
      kernel_release: result_value(kernel),
      architecture: result_value(architecture),
      libc_name: libc_name(libc),
      libc_version: libc_version(libc),
      systemd_version: systemd_version(systemd),
      cgroup_mode: result_value(cgroup)
    }
  end

  defp network(context) do
    source = "ip --json address show"

    with {:ok, output} <- context.run.("ip", ["--json", "address", "show"]),
         {:ok, interfaces} when is_list(interfaces) <- Jason.decode(output) do
      {parsed, invalid_count} = parse_interfaces(interfaces)
      state = if invalid_count == 0, do: :observed, else: :partial
      code = if invalid_count == 0, do: "", else: "malformed_entries"

      %HostNetworkObservation{
        evidence: evidence(state, source, context.now_ms, code),
        interfaces: parsed
      }
    else
      {:error, reason} ->
        %HostNetworkObservation{
          evidence: evidence(error_state(reason), source, context.now_ms, reason)
        }

      _other ->
        %HostNetworkObservation{
          evidence: evidence(:error, source, context.now_ms, "malformed_output")
        }
    end
  end

  defp parse_interfaces(interfaces) do
    retained = Enum.take(interfaces, @max_interfaces)
    truncated = max(length(interfaces) - length(retained), 0)

    retained
    |> Enum.reduce({[], 0}, fn interface, {parsed, invalid} ->
      case parse_interface(interface) do
        {:ok, observation, discarded_addresses} ->
          {[observation | parsed], invalid + discarded_addresses}

        :error ->
          {parsed, invalid + 1}
      end
    end)
    |> then(fn {parsed, invalid} -> {Enum.reverse(parsed), invalid + truncated} end)
  end

  defp parse_interface(%{"ifname" => name, "ifindex" => index} = interface)
       when is_binary(name) and is_integer(index) and index >= 0 and index <= @uint32_max do
    {addresses, discarded_addresses} = parse_addresses(Map.get(interface, "addr_info"))
    bounded_name = bounded_string(name)

    with true <- bounded_name != "",
         mtu when is_integer(mtu) <- uint32(interface["mtu"]) do
      {:ok,
       %HostNetworkInterfaceObservation{
         name: bounded_name,
         index: index,
         oper_state: bounded_string(interface["operstate"]),
         mtu: mtu,
         link_type: bounded_string(interface["link_type"]),
         hardware_address: bounded_string(interface["address"]),
         addresses: addresses
       }, discarded_addresses}
    else
      _value -> :error
    end
  end

  defp parse_interface(_interface), do: :error

  defp parse_addresses(nil), do: {[], 0}

  defp parse_addresses(entries) when is_list(entries) do
    retained = Enum.take(entries, @max_addresses)
    truncated = max(length(entries) - length(retained), 0)

    retained
    |> Enum.reduce({[], truncated}, fn entry, {parsed, discarded} ->
      case parse_address(entry) do
        {:ok, address} -> {[address | parsed], discarded}
        :error -> {parsed, discarded + 1}
      end
    end)
    |> then(fn {parsed, discarded} -> {Enum.reverse(parsed), discarded} end)
  end

  defp parse_addresses(_entries), do: {[], 1}

  defp parse_address(%{"family" => family, "local" => address} = entry)
       when family in ["inet", "inet6"] and is_binary(address) do
    with {:ok, parsed_address} <- :inet.parse_address(String.to_charlist(address)),
         true <- address_family(parsed_address) == family,
         prefix when is_integer(prefix) <- uint32(entry["prefixlen"]),
         true <- prefix <= max_prefix(family) do
      {:ok,
       %HostNetworkAddressObservation{
         family: family,
         address: bounded_string(address),
         prefix_length: prefix,
         scope: bounded_string(entry["scope"])
       }}
    else
      _other -> :error
    end
  end

  defp parse_address(_entry), do: :error

  defp address_family({_a, _b, _c, _d}), do: "inet"
  defp address_family({_a, _b, _c, _d, _e, _f, _g, _h}), do: "inet6"
  defp max_prefix("inet"), do: 32
  defp max_prefix("inet6"), do: 128

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

  defp run_value(context, tool, args) do
    case context.run.(tool, args) do
      {:ok, output} ->
        case output |> String.split("\n", trim: true) |> List.first() do
          nil -> {:error, :malformed_output}
          value -> {:ok, String.trim(value)}
        end

      error ->
        error
    end
  end

  defp cgroup_mode(context) do
    case context.read.("/sys/fs/cgroup/cgroup.controllers") do
      {:ok, _contents} -> {:ok, "v2"}
      {:error, :enoent} -> {:ok, "v1_or_unavailable"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_meminfo(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, values ->
      case Regex.run(~r/^([A-Za-z]+):\s+([0-9]+)\s+kB$/, line) do
        [_, key, value] -> put_kib_value(values, key, value)
        _other -> values
      end
    end)
  end

  defp put_kib_value(values, key, value) do
    case uint64(value) do
      integer when is_integer(integer) and integer <= div(@uint64_max, 1024) ->
        Map.put(values, key, integer * 1024)

      _value ->
        values
    end
  end

  defp os_value({:ok, values}, key), do: bounded_string(values[key])
  defp os_value(_result, _key), do: ""
  defp result_value({:ok, value}), do: bounded_string(value)
  defp result_value(_result), do: ""

  defp libc_name({:ok, output}) do
    if String.contains?(String.downcase(output), "glibc"), do: "glibc", else: "unknown"
  end

  defp libc_name(_result), do: ""

  defp libc_version({:ok, output}) do
    case Regex.run(~r/([0-9]+\.[0-9]+(?:\.[0-9]+)?)\s*$/, output) do
      [_, version] -> bounded_string(version)
      _other -> ""
    end
  end

  defp libc_version(_result), do: ""

  defp systemd_version({:ok, output}) do
    case Regex.run(~r/^systemd\s+([0-9]+)/, output) do
      [_, version] -> bounded_string(version)
      _other -> ""
    end
  end

  defp systemd_version(_result), do: ""

  defp platform_error_code(:observed), do: ""
  defp platform_error_code(:partial), do: "platform_partial"

  defp multiply_uint32(a, b) when is_integer(a) and is_integer(b) do
    product = a * b
    if product <= @uint32_max, do: product
  end

  defp multiply_uint32(_a, _b), do: nil

  defp evidence_state(:observed), do: :HOST_EVIDENCE_STATE_OBSERVED
  defp evidence_state(:absent), do: :HOST_EVIDENCE_STATE_ABSENT
  defp evidence_state(:partial), do: :HOST_EVIDENCE_STATE_PARTIAL
  defp evidence_state(:error), do: :HOST_EVIDENCE_STATE_ERROR

  defp error_state(reason) when reason in [:missing_tool, :enoent], do: :absent
  defp error_state(_reason), do: :error

  @doc "Runs one inventory command with bounded output and termination escalation."
  @spec run_command(String.t(), [String.t()], pos_integer()) :: command_result()
  def run_command(tool, args, timeout_ms \\ @command_timeout_ms) do
    with executable when is_binary(executable) <- System.find_executable(tool),
         guard_name when is_binary(guard_name) <- command_guard_name(),
         command_guard when is_binary(command_guard) <- System.find_executable(guard_name) do
      guard_args = [
        "--signal=TERM",
        "--kill-after=#{duration(@command_guard_kill_ms)}",
        duration(timeout_ms),
        executable | args
      ]

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(command_guard)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(guard_args, &String.to_charlist/1)
          ]
        )

      deadline =
        System.monotonic_time(:millisecond) + timeout_ms + @command_guard_kill_ms +
          @command_kill_grace_ms

      collect_command(port, [], 0, deadline)
    else
      nil -> {:error, :missing_tool}
    end
  rescue
    _error -> {:error, :command_failed}
  catch
    _kind, _reason -> {:error, :command_failed}
  end

  defp command_guard_name do
    case System.get_env("ORCHARD_LINUX_COREUTILS_PREFIX") do
      nil -> "timeout"
      "" -> "timeout"
      "gnu" -> "gnutimeout"
      _unsupported -> nil
    end
  end

  defp collect_command(port, output, size, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when size + byte_size(data) <= @max_command_output_bytes ->
        collect_command(port, [data | output], size + byte_size(data), deadline)

      {^port, {:data, _data}} ->
        close_port(port)
        {:error, :output_too_large}

      {^port, {:exit_status, 0}} ->
        {:ok, output |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} when status in [124, 137] ->
        {:error, :command_timeout}

      {^port, {:exit_status, _status}} ->
        output = output |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, command_error(output)}
    after
      timeout ->
        close_port(port)
        {:error, :command_timeout}
    end
  end

  defp duration(milliseconds) do
    seconds = div(milliseconds, 1_000)
    remainder = milliseconds |> rem(1_000) |> Integer.to_string() |> String.pad_leading(3, "0")
    "#{seconds}.#{remainder}s"
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _error -> :ok
  end

  defp command_error(output) do
    if String.contains?(String.downcase(output), "permission"),
      do: :permission_denied,
      else: :command_failed
  end
end
