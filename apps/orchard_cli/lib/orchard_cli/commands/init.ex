defmodule OrchardCLI.Commands.Init do
  @moduledoc false

  alias OrchardCLI.Commands.{
    Console,
    Env,
    License,
    LifecycleSupport,
    Migrate,
    Start,
    Status,
    Transport
  }

  @install_role_request_marker "/Library/Application Support/Orchard/support/.install-role.request"
  @default_port "8443"

  @type step :: %{
          required(:command) => atom(),
          required(:args) => [String.t()],
          required(:line) => String.t(),
          required(:sudo?) => boolean()
        }

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  @doc false
  @spec run([String.t()], map()) :: OrchardCLI.command_result()
  def run(args, runtime) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, role} <- first_run_role(runtime),
         {:ok, config} <- build_config(opts, role),
         :ok <- require_root(config, runtime) do
      run_steps(role, config, runtime)
    else
      {:help} -> {:ok, usage()}
      {:error, _message, _code} = error -> error
    end
  end

  defp parse_opts(args) do
    switches = [
      host: :string,
      port: :string,
      console: :boolean,
      skip_start: :boolean,
      help: :boolean
    ]

    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        if Keyword.get(parsed, :help, false) do
          {:help}
        else
          {:ok, Keyword.put_new(parsed, :port, @default_port)}
        end

      {_parsed, [_first | _rest], []} ->
        {:error, "Error: unexpected argument(s).\n\n#{usage()}", 1}

      {_parsed, _positional, _invalid} ->
        {:error, "Error: unknown option(s).\n\n#{usage()}", 1}
    end
  end

  defp first_run_role(runtime) do
    case read_requested_role(runtime) do
      {:ok, role} ->
        {:ok, role}

      :missing ->
        persisted_or_default_role(runtime)

      {:error, _message, _code} = error ->
        error
    end
  end

  defp read_requested_role(runtime) do
    reader = Map.get(runtime, :read_install_role_request, &default_read_install_role_request/0)

    case reader.() do
      {:ok, contents} when is_binary(contents) ->
        parse_marker_role(contents, @install_role_request_marker)

      contents when is_binary(contents) ->
        parse_marker_role(contents, @install_role_request_marker)

      {:error, reason} when reason in [:enoent, :enotdir] ->
        :missing

      {:error, reason} ->
        {:error, "Error: unable to read Orchard install role request: #{inspect(reason)}", 1}

      other ->
        {:error, "Error: invalid Orchard install role request reader response: #{inspect(other)}",
         1}
    end
  end

  defp persisted_or_default_role(runtime) do
    runtime
    |> Map.put(:file_regular?, fn _path -> false end)
    |> LifecycleSupport.detect_install_role()
    |> case do
      {:ok, role} -> {:ok, role}
      {:error, :legacy_not_found, _message, _code} -> {:ok, :all}
      {:error, _reason, message, code} -> {:error, message, code}
    end
  end

  defp parse_marker_role(contents, path) do
    case String.trim(contents) do
      "all" -> {:ok, :all}
      "controller" -> {:ok, :controller}
      "node-agent" -> {:ok, :node_agent}
      value -> {:error, invalid_role_marker_message(path, value), 1}
    end
  end

  defp invalid_role_marker_message(path, value) do
    found = if value == "", do: "empty marker", else: inspect(value)

    "Error: invalid Orchard install role marker at #{path}.\n" <>
      "Expected one of: all, controller, node-agent.\n" <>
      "Found: #{found}"
  end

  defp build_config(opts, role) do
    config = %{
      role: role,
      host: Keyword.get(opts, :host),
      port: Keyword.fetch!(opts, :port),
      console?: Keyword.get(opts, :console, false),
      skip_start?: Keyword.get(opts, :skip_start, false)
    }

    cond do
      controller_role?(role) and blank?(config.host) ->
        {:error,
         "Error: --host is required for role #{LifecycleSupport.display_role(role)}.\n" <>
           "Role: #{LifecycleSupport.display_role(role)}\n\n" <>
           usage(), 1}

      controller_role?(role) ->
        with {:ok, host} <- validate_host(config.host),
             {:ok, port} <- validate_port(config.port) do
          {:ok, %{config | host: host, port: port}}
        end

      config.console? ->
        {:error,
         "Error: --console is only applicable for controller-bearing roles.\n" <>
           "Role: #{LifecycleSupport.display_role(role)}", 1}

      true ->
        {:ok, config}
    end
  end

  defp require_root(config, runtime) do
    uid_fn = Map.get(runtime, :uid, &default_uid/0)

    if uid_fn.() == 0 do
      :ok
    else
      {:error,
       "Error: root privileges required to run Orchard first-run initialization.\n" <>
         "Run: #{init_resume_command(config)}", 1}
    end
  end

  defp run_steps(role, config, runtime) do
    runtime = Map.put(runtime, :install_role, role)
    steps = steps_for_role(role, config)

    heading = [
      "Orchard guided first-run initialization",
      "Role: #{LifecycleSupport.display_role(role)}"
    ]

    execute_steps(steps, runtime, config, heading, 1)
  end

  defp steps_for_role(:node_agent, config) do
    [
      step(:license, ["status"], "orchardctl license status", true),
      step(
        :env,
        ["init", "--service", "node-agent"],
        "orchardctl env init --service node-agent",
        true
      )
    ] ++ start_steps(config)
  end

  defp steps_for_role(role, config) when role in [:all, :controller] do
    service = LifecycleSupport.display_role(role)

    [
      step(:license, ["status"], "orchardctl license status", true),
      step(
        :env,
        ["init", "--service", service],
        "orchardctl env init --service #{service}",
        true
      ),
      step(:migrate, [], "orchardctl migrate", true),
      step(
        :transport,
        ["enable-local-https", "--host", config.host, "--port", config.port],
        "orchardctl transport enable-local-https --host #{config.host} --port #{config.port}",
        true
      )
    ]
    |> maybe_add_console_step(config)
    |> Kernel.++(start_steps(config))
  end

  defp maybe_add_console_step(steps, %{console?: true}) do
    steps ++ [step(:console, ["enable"], "orchardctl console enable", true)]
  end

  defp maybe_add_console_step(steps, _config), do: steps

  defp start_steps(%{skip_start?: true}), do: []

  defp start_steps(%{role: :node_agent}) do
    [step(:start, [], "orchardctl start", true)]
  end

  defp start_steps(_config) do
    [
      step(:start, [], "orchardctl start", true),
      step(:status, [], "orchardctl status", false)
    ]
  end

  defp step(command, args, line, sudo?) do
    %{command: command, args: args, line: line, sudo?: sudo?}
  end

  defp execute_steps([], _runtime, config, lines, _index) do
    {:ok, Enum.join(lines ++ completion_lines(config), "\n")}
  end

  defp execute_steps([step | rest], runtime, config, lines, index) do
    step_line = "Step #{index}: #{display_step(step)}"

    case run_command(step, runtime) |> normalize_command_result() do
      {:ok, message, metadata} ->
        handle_step_success(
          step,
          message,
          metadata,
          rest,
          runtime,
          config,
          lines ++ [step_line, message],
          index
        )

      {:error, message, code} ->
        {:error, step_failure_message(lines, step_line, message, step, config), code}
    end
  end

  defp normalize_command_result(:ok), do: {:ok, "OK", %{}}

  defp normalize_command_result({:ok, %{message: message} = metadata}),
    do: {:ok, message, metadata}

  defp normalize_command_result({:ok, message}), do: {:ok, message, %{}}
  defp normalize_command_result({:error, _message, _code} = error), do: error

  defp handle_step_success(
         %{command: :license} = step,
         _message,
         metadata,
         rest,
         runtime,
         config,
         lines,
         index
       ) do
    if valid_license?(metadata) do
      execute_steps(rest, runtime, config, lines, index + 1)
    else
      {:error, invalid_license_message(lines, step, config), 1}
    end
  end

  defp handle_step_success(
         %{command: :console},
         _message,
         _metadata,
         rest,
         runtime,
         config,
         lines,
         index
       ) do
    execute_steps(rest, runtime, %{config | console?: false}, lines, index + 1)
  end

  defp handle_step_success(_step, _message, _metadata, rest, runtime, config, lines, index) do
    execute_steps(rest, runtime, config, lines, index + 1)
  end

  defp run_command(%{command: command, args: args}, runtime) do
    runner = Map.get(runtime, :command_runner, &default_command_runner/3)
    runner.(command, args, runtime)
  end

  defp valid_license?(%{valid?: true}), do: true
  defp valid_license?(_metadata), do: false

  defp invalid_license_message(lines, step, config) do
    Enum.join(
      lines ++
        [
          "License is not valid; first-run initialization stopped.",
          "Provision a license through the supported path:",
          "Run: sudo orchardctl license activate --key-stdin",
          "Resume: #{init_resume_command(config)}",
          "Checked by: #{display_step(step)}"
        ],
      "\n"
    )
  end

  defp step_failure_message(lines, step_line, message, step, config) do
    Enum.join(
      lines ++
        [
          step_line,
          "First-run initialization stopped at: #{display_step(step)}",
          message,
          "Resume this step: #{display_step(step)}",
          "Then rerun: #{init_resume_command(config)}"
        ],
      "\n"
    )
  end

  defp completion_lines(%{role: :node_agent, skip_start?: true}) do
    [
      "Start skipped by --skip-start.",
      "Run: sudo orchardctl start",
      "Node-agent first-run initialization complete."
    ]
  end

  defp completion_lines(%{role: :node_agent}) do
    ["Node-agent first-run initialization complete."]
  end

  defp completion_lines(%{skip_start?: true}) do
    [
      "Start skipped by --skip-start.",
      "Run: sudo orchardctl start",
      "Then run: orchardctl status",
      "First-run initialization complete."
    ]
  end

  defp completion_lines(_config), do: ["First-run initialization complete."]

  defp display_step(%{line: line, sudo?: true}), do: "sudo #{line}"
  defp display_step(%{line: line}), do: line

  defp init_resume_command(config) do
    ["sudo orchardctl init"]
    |> maybe_add_host(config)
    |> maybe_add_port(config)
    |> maybe_add_flag(config.console?, "--console")
    |> maybe_add_flag(config.skip_start?, "--skip-start")
    |> Enum.join(" ")
  end

  defp maybe_add_host(parts, %{host: host}) when is_binary(host) and host != "" do
    parts ++ ["--host", host]
  end

  defp maybe_add_host(parts, _config), do: parts

  defp maybe_add_port(parts, %{host: host, port: port}) when is_binary(host) and host != "" do
    parts ++ ["--port", port]
  end

  defp maybe_add_port(parts, _config), do: parts

  defp maybe_add_flag(parts, true, flag), do: parts ++ [flag]
  defp maybe_add_flag(parts, _enabled, _flag), do: parts

  defp controller_role?(role), do: role in [:all, :controller]

  defp validate_host(host) when is_binary(host) do
    host = String.trim(host)

    cond do
      blank?(host) -> invalid_host()
      String.contains?(host, ["://", " ", "\t", "\n", "\r", ",", "/"]) -> invalid_host()
      ip_literal?(host) -> {:ok, host}
      hostname?(host) -> {:ok, host}
      true -> invalid_host()
    end
  end

  defp validate_host(_host), do: invalid_host()

  defp validate_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {parsed, ""} when parsed in 1..65_535 -> {:ok, Integer.to_string(parsed)}
      _other -> invalid_port()
    end
  end

  defp validate_port(port) when is_integer(port) and port in 1..65_535 do
    {:ok, Integer.to_string(port)}
  end

  defp validate_port(_port), do: invalid_port()

  defp invalid_host, do: {:error, "Error: invalid --host.\n\n#{usage()}", 1}
  defp invalid_port, do: {:error, "Error: invalid --port.\n\n#{usage()}", 1}

  defp ip_literal?(string) do
    case :inet.parse_address(String.to_charlist(string)) do
      {:ok, _ip} -> true
      {:error, _reason} -> false
    end
  end

  defp hostname?(host) do
    byte_size(host) <= 253 and
      host
      |> String.split(".")
      |> Enum.all?(&hostname_label?/1)
  end

  defp hostname_label?(label) do
    byte_size(label) in 1..63 and
      Regex.match?(~r/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/, label)
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp default_command_runner(:license, _args, runtime) do
    command_runtime = command_runtime(runtime)

    with {:ok, json} <- License.run(["status", "--json"], command_runtime),
         {:ok, payload} <- Jason.decode(json),
         {:ok, message} <- License.run(["status"], command_runtime) do
      {:ok, %{message: message, valid?: payload["state"] == "valid"}}
    else
      {:error, _message, _code} = error -> error
      _other -> {:error, "Error: unable to determine structured license status", 1}
    end
  end

  defp default_command_runner(:env, args, runtime) do
    if Map.has_key?(runtime, :command_runtime) do
      Env.run(args, command_runtime(runtime))
    else
      Env.run(args)
    end
  end

  defp default_command_runner(:migrate, args, runtime),
    do: Migrate.run(args, command_runtime(runtime))

  defp default_command_runner(:transport, args, runtime),
    do: Transport.run(args, command_runtime(runtime))

  defp default_command_runner(:console, args, runtime),
    do: Console.run(args, command_runtime(runtime))

  defp default_command_runner(:start, args, runtime),
    do: Start.run(args, command_runtime(runtime))

  defp default_command_runner(:status, args, runtime),
    do: Status.run(args, command_runtime(runtime))

  defp command_runtime(runtime) do
    runtime
    |> Map.get(:command_runtime, %{})
    |> Map.put(:install_role, Map.get(runtime, :install_role))
  end

  defp default_read_install_role_request, do: File.read(@install_role_request_marker)

  defp default_runtime, do: %{}

  defp default_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.to_integer()
      _other -> -1
    end
  end

  defp usage do
    """
    sudo orchardctl init --host HOST [--port 8443] [--console] [--skip-start]

    Guided packaged first-run setup. `orchardctl first-run` is an alias.

    Role behavior:
      node-agent       license check, node-agent env init, start guidance
      controller/all   license check, env init, migrate, transport, optional Console, start/status

    Options:
      --host HOST     Browser/API hostname or IP for controller/all transport setup
      --port PORT     Public HTTPS port for controller/all transport setup (default: 8443)
      --console       Enable Console through the same interactive prompt path as orchardctl console enable
      --skip-start    Configure without starting services
      --help          Show this help

    License provisioning:
      sudo orchardctl license activate --key-stdin

    Examples:
      sudo orchardctl init --host mawarduri --port 8443
      sudo orchardctl init --host mawarduri --console
      sudo orchardctl first-run --host mawarduri --skip-start
    """
    |> String.trim()
  end
end
