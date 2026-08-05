defmodule OrchardCLI.Commands.Console do
  @moduledoc false

  alias OrchardCLI.Commands.LifecycleSupport
  alias OrchardCLI.SecretTTY
  alias OrchardCLI.ShellEnv

  @default_support_root "/Library/Application Support/Orchard"

  @type action :: :enable | :disable | :rotate
  @type credentials :: %{required(:username) => String.t(), required(:password) => String.t()}

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  @doc false
  @spec run([String.t()], map()) :: OrchardCLI.command_result()
  def run(args, runtime) do
    case args do
      ["enable" | rest] -> run_action(:enable, rest, runtime)
      ["disable" | rest] -> run_action(:disable, rest, runtime)
      ["rotate" | rest] -> run_action(:rotate, rest, runtime)
      ["help"] -> {:ok, group_usage()}
      ["--help"] -> {:ok, group_usage()}
      [] -> {:error, group_usage(), 1}
      _other -> {:error, group_usage(), 1}
    end
  end

  defp run_action(action, args, runtime) do
    with {:ok, :run} <- parse_action_args(action, args),
         {:ok, role} <- LifecycleSupport.install_role(role_runtime(runtime)) do
      run_for_role(action, role, runtime)
    else
      {:help, usage} -> {:ok, usage}
      {:error, _message, _code} = error -> error
    end
  end

  defp parse_action_args(action, args) do
    case OptionParser.parse(args, strict: [help: :boolean]) do
      {parsed, [], []} ->
        if Keyword.get(parsed, :help, false), do: {:help, action_usage(action)}, else: {:ok, :run}

      {_parsed, [_first | _rest], []} ->
        {:error,
         "Error: unexpected argument(s). Console credentials must be entered interactively.\n\n#{action_usage(action)}",
         1}

      {_parsed, _positional, _invalid} ->
        {:error,
         "Error: unknown option(s). Console credentials must be entered interactively.\n\n#{action_usage(action)}",
         1}
    end
  end

  defp run_for_role(_action, :node_agent, _runtime) do
    {:ok,
     "Console configuration is not applicable for node-agent role.\n" <>
       "Role: node-agent\n" <>
       "Run on a controller or all-role Orchard host."}
  end

  defp run_for_role(action, role, runtime) when role in [:all, :controller] do
    with :ok <- require_root(action, runtime),
         {:ok, assignments} <- build_assignments(action, runtime),
         :ok <- write_console_env(assignments, runtime),
         {:ok, restart_line} <- restart_controller_if_loaded(role, runtime) do
      {:ok, success_message(action, restart_line)}
    else
      {:error, _message, _code} = error -> error
      {:error, message} -> {:error, "Error: #{message}", 1}
    end
  end

  defp require_root(action, runtime) do
    uid = runtime |> Map.get(:uid, &default_uid/0) |> then(& &1.())

    if uid == 0 do
      :ok
    else
      {:error,
       "Error: root privileges required to configure Orchard Console.\n" <>
         "Run: sudo orchardctl console #{action_name(action)}", 1}
    end
  end

  defp build_assignments(:disable, _runtime) do
    {:ok, [{"ORCHARD_CONSOLE_ENABLED", "false"}]}
  end

  defp build_assignments(action, runtime) when action in [:enable, :rotate] do
    with :ok <- require_tty(action, runtime),
         {:ok, credentials} <- prompt_credentials(runtime) do
      {:ok,
       [
         {"ORCHARD_CONSOLE_ENABLED", "true"},
         {"ORCHARD_CONSOLE_USERNAME", credentials.username},
         {"ORCHARD_CONSOLE_PASSWORD", credentials.password}
       ]}
    end
  end

  defp require_tty(action, runtime) do
    tty? = Map.get(runtime, :tty?, &default_tty?/0)

    if tty?.() do
      :ok
    else
      {:error,
       "Error: interactive TTY required to collect Console credentials.\n" <>
         "Run from a terminal: sudo orchardctl console #{action_name(action)}", 1}
    end
  end

  defp prompt_credentials(runtime) do
    if Map.has_key?(runtime, :prompt) do
      prompt_injected_credentials(runtime)
    else
      SecretTTY.run(&prompt_guarded_credentials/1)
    end
  end

  defp prompt_injected_credentials(runtime) do
    with {:ok, username} <- prompt_value(runtime, "Console username: ", echo: true),
         :ok <- validate_credential(:username, username),
         {:ok, password} <- prompt_value(runtime, "Console password: ", echo: false),
         :ok <- validate_credential(:password, password),
         {:ok, confirmation} <- prompt_value(runtime, "Confirm console password: ", echo: false),
         :ok <- validate_credential(:password_confirmation, confirmation),
         :ok <- validate_confirmation(password, confirmation) do
      {:ok, %{username: username, password: password}}
    end
  end

  defp prompt_guarded_credentials(reader) do
    with {:ok, username} <- guarded_prompt_value(reader, "Console username: "),
         :ok <- validate_credential(:username, username),
         {:ok, password} <- guarded_prompt_value(reader, "Console password: "),
         :ok <- validate_credential(:password, password),
         {:ok, confirmation} <- guarded_prompt_value(reader, "Confirm console password: "),
         :ok <- validate_credential(:password_confirmation, confirmation),
         :ok <- validate_confirmation(password, confirmation) do
      {:ok, %{username: username, password: password}}
    end
  end

  defp guarded_prompt_value(reader, prompt) do
    case reader.(prompt) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      :eof -> {:error, "unable to read Console credential prompt input"}
      {:error, message} when is_binary(message) -> {:error, message}
      _other -> {:error, "unable to read Console credential prompt input"}
    end
  end

  defp prompt_value(runtime, prompt, opts) do
    prompt_fn = Map.fetch!(runtime, :prompt)

    case prompt_fn.(prompt, opts) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      value when is_binary(value) -> {:ok, value}
      :eof -> {:error, "unable to read Console credential prompt input"}
      {:error, message} when is_binary(message) -> {:error, message}
      other -> {:error, "invalid Console credential prompt response: #{inspect(other)}"}
    end
  end

  defp validate_credential(field, value) do
    label = credential_label(field)

    cond do
      String.trim(value) == "" ->
        {:error, "#{label} must not be blank."}

      match?({:error, _message}, ShellEnv.validate_value(value)) ->
        {:error, "#{label} contains newline or NUL/control characters."}

      true ->
        :ok
    end
  end

  defp credential_label(:username), do: "Console username"
  defp credential_label(:password), do: "Console password"
  defp credential_label(:password_confirmation), do: "Console password confirmation"

  defp validate_confirmation(password, confirmation) do
    if password == confirmation do
      :ok
    else
      {:error, "Console password confirmation did not match."}
    end
  end

  defp write_console_env(assignments, runtime) do
    path = console_env_path(runtime)
    writer = Map.get(runtime, :shell_env_write_assignments, &ShellEnv.write_assignments/2)

    case writer.(path, assignments) do
      :ok -> :ok
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} when is_atom(reason) -> {:error, :file.format_error(reason)}
    end
  end

  defp restart_controller_if_loaded(role, runtime) do
    case LifecycleSupport.restart_loaded(role, :controller, runtime) do
      {:restarted, _svc} -> {:ok, "Controller restarted."}
      {:not_loaded, _svc} -> {:ok, "Controller is not loaded. Run: sudo orchardctl start"}
      {:error, _message, _code} = error -> error
    end
  end

  defp success_message(:enable, restart_line), do: "Console enabled.\n#{restart_line}"
  defp success_message(:disable, restart_line), do: "Console disabled.\n#{restart_line}"
  defp success_message(:rotate, restart_line), do: "Console credentials rotated.\n#{restart_line}"

  defp console_env_path(runtime), do: Path.join([support_root(runtime), "config", "console.env"])

  defp support_root(runtime) do
    Map.get(runtime, :support_root) ||
      System.get_env("ORCHARD_SUPPORT_ROOT") ||
      @default_support_root
  end

  defp role_runtime(runtime) do
    marker =
      Map.get(runtime, :install_role_marker) ||
        Path.join([support_root(runtime), "support", ".install-role"])

    runtime
    |> Map.put(:install_role_marker, marker)
    |> Map.put_new_lazy(:read_install_role, fn -> fn -> File.read(marker) end end)
  end

  defp default_tty?, do: SecretTTY.available?()

  defp default_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.to_integer()
      _other -> -1
    end
  end

  defp default_runtime, do: %{}

  defp action_name(:enable), do: "enable"
  defp action_name(:disable), do: "disable"
  defp action_name(:rotate), do: "rotate"

  defp group_usage do
    """
    orchardctl console <command>

    Commands:
      enable    Enable the browser Console with interactive Basic Auth credentials
      disable   Disable the browser Console and remove stored Console credentials
      rotate    Replace browser Console credentials interactively

    Run `orchardctl console <enable|disable|rotate> --help` for command-specific usage.
    """
    |> String.trim()
  end

  defp action_usage(:enable) do
    """
    orchardctl console enable

    Prompt on an interactive TTY for a Console username and no-echo password,
    write config/console.env with Console-only keys, and restart the loaded
    controller service if present.

    Credentials are not accepted through flags, environment variables, or argv.

    Example:
      sudo orchardctl console enable
    """
    |> String.trim()
  end

  defp action_usage(:disable) do
    """
    orchardctl console disable

    Disable the browser Console by writing config/console.env with only
    ORCHARD_CONSOLE_ENABLED=false, removing stored Console credentials.

    Example:
      sudo orchardctl console disable
    """
    |> String.trim()
  end

  defp action_usage(:rotate) do
    """
    orchardctl console rotate

    Prompt on an interactive TTY for replacement Console credentials and
    restart the loaded controller service if present.

    Credentials are not accepted through flags, environment variables, or argv.

    Example:
      sudo orchardctl console rotate
    """
    |> String.trim()
  end
end
