defmodule OrchardCLI.Commands.Env do
  @moduledoc """
  CLI handler for `orchardctl env` commands.

  Supports:
    orchardctl env init [options]     — Generate env files for packaged services
  """

  @default_support_root "/Library/Application Support/Orchard"
  @default_db_name "orchard_controller"

  # ── Public API ──────────────────────────────────────────────────────

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  # credo:disable-for-lines:3 ExSlop.Check.Readability.DocFalseOnPublicFunction
  @doc false
  @spec run([String.t()], map()) :: OrchardCLI.command_result()
  def run(args, runtime) do
    case args do
      ["init" | rest] -> run_init(rest, runtime)
      ["help"] -> {:ok, group_usage()}
      ["--help"] -> {:ok, group_usage()}
      [] -> {:error, group_usage(), 1}
      _ -> {:error, group_usage(), 1}
    end
  end

  # ── Init Subcommand ─────────────────────────────────────────────────

  defp run_init(args, runtime) do
    case parse_init_opts(args) do
      {:help} ->
        {:ok, init_usage()}

      {:error, _, _} = err ->
        err

      {:ok, opts} ->
        do_init(opts, runtime)
    end
  end

  defp parse_init_opts(args) do
    switches = [
      support_root: :string,
      service: :string,
      force: :boolean,
      help: :boolean
    ]

    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        if Keyword.get(parsed, :help, false) do
          {:help}
        else
          validate_service_opt(parsed)
        end

      {_parsed, positional, []} ->
        {:error,
         "Error: unexpected argument(s): #{Enum.join(positional, ", ")}\n\n#{init_usage()}", 1}

      {_parsed, _positional, invalid} ->
        invalid_str = Enum.map_join(invalid, ", ", fn {flag, _} -> flag end)
        {:error, "Error: unknown option(s): #{invalid_str}\n\n#{init_usage()}", 1}
    end
  end

  defp validate_service_opt(parsed) do
    case Keyword.get(parsed, :service, "all") do
      s when s in ["controller", "node-agent", "all"] ->
        {:ok, parsed}

      other ->
        {:error,
         "Error: invalid --service value: #{inspect(other)}. Must be controller, node-agent, or all.\n\n#{init_usage()}",
         1}
    end
  end

  # ── Init Execution ──────────────────────────────────────────────────

  defp do_init(opts, runtime) do
    support_root = resolve_support_root(opts)
    service = Keyword.get(opts, :service, "all")
    force = Keyword.get(opts, :force, false)
    hostname = discover_hostname(runtime)

    targets = targets_for_service(service)

    with :ok <- validate_executables(targets, support_root) do
      config_dir = Path.join(support_root, "config")

      try do
        ensure_config_dir(config_dir)

        results =
          Enum.map(targets, fn target ->
            {target,
             generate_env_file(target, config_dir, support_root, hostname, force, runtime)}
          end)

        format_results(results)
      rescue
        e in File.Error ->
          {:error, "Error: #{Exception.message(e)}\nHint: try running with sudo.", 1}
      end
    end
  end

  defp targets_for_service("controller"), do: [:controller]
  defp targets_for_service("node-agent"), do: [:node_agent]
  defp targets_for_service("all"), do: [:controller, :node_agent]

  # ── Executable Resolution ───────────────────────────────────────────

  # credo:disable-for-lines:2 ExSlop.Check.Readability.DocFalseOnPublicFunction
  @doc false
  def resolve_executable(:tokenizer, support_root) do
    candidates = [
      Path.join([
        support_root,
        "native",
        "orchard_tokenizer",
        ".venv",
        "bin",
        "orchard-tokenizer"
      ]),
      Path.join([support_root, "native", "orchard_tokenizer", "bin", "orchard-tokenizer"])
    ]

    find_executable(candidates)
  end

  def resolve_executable(:worker, support_root) do
    candidates = [
      Path.join([
        support_root,
        "native",
        "orchard_worker_mlx",
        ".venv",
        "bin",
        "orchard-worker-mlx"
      ]),
      Path.join([support_root, "native", "orchard_worker_mlx", "bin", "orchard-worker-mlx"])
    ]

    find_executable(candidates)
  end

  defp find_executable(candidates) do
    Enum.find(candidates, fn path ->
      File.regular?(path) and executable?(path)
    end)
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp validate_executables(targets, support_root) do
    missing =
      targets
      |> Enum.flat_map(fn
        :controller -> [{:tokenizer, "tokenizer"}]
        :node_agent -> [{:worker, "worker"}]
      end)
      |> Enum.reject(fn {kind, _label} -> resolve_executable(kind, support_root) end)

    case missing do
      [] ->
        :ok

      items ->
        labels = Enum.map_join(items, ", ", fn {_kind, label} -> label end)

        {:error,
         "Error: packaged executable(s) not found: #{labels}\n" <>
           "Expected under: #{support_root}/native/\n" <>
           "Ensure the PKG was installed correctly.", 1}
    end
  end

  # ── Env File Generation ─────────────────────────────────────────────

  defp generate_env_file(target, config_dir, support_root, hostname, force, runtime) do
    filename = env_filename(target)
    target_path = Path.join(config_dir, filename)

    cond do
      not File.regular?(target_path) ->
        write_rendered_env(target, target_path, support_root, hostname, runtime, :created)

      force ->
        write_rendered_env(target, target_path, support_root, hostname, runtime, :overwritten)

      true ->
        %{status: :skipped_existing, notes: []}
    end
  end

  defp write_rendered_env(:controller, target_path, support_root, _hostname, runtime, status) do
    controller_settings = build_controller_settings(runtime)

    content = render_env(:controller, support_root, controller_settings)
    write_env_file(target_path, content)

    notes = controller_settings.notes ++ maybe_create_database(runtime, controller_settings)

    %{status: status, notes: notes}
  end

  defp write_rendered_env(:node_agent, target_path, support_root, hostname, _runtime, status) do
    content = render_env(:node_agent, support_root, hostname)
    write_env_file(target_path, content)

    %{status: status, notes: []}
  end

  defp env_filename(:controller), do: "controller.env"
  defp env_filename(:node_agent), do: "node-agent.env"

  defp render_env(:controller, support_root, controller_settings) do
    tokenizer_path = resolve_executable(:tokenizer, support_root)

    """
    # Orchard Controller Environment
    # Generated by: orchardctl env init
    #
    # This file is sourced as POSIX shell. All values with spaces MUST be quoted.
    # See: packaging/pkg/README.md

    # ── Required ──────────────────────────────────────────────────────

    #{controller_settings.database_url_line}
    SECRET_KEY_BASE=#{shell_quote(controller_settings.secret_key_base)}

    # ── Optional ──────────────────────────────────────────────────────

    # Controller gRPC runtime targets for worker placement.
    # Comma-separated host:port entries (example: "10.0.0.21:50061,10.0.0.22:50061").
    # Leave unset for single-node/all-in-one installs.
    # ORCHARD_RUNTIME_CLIENT_TARGETS="replace-with-host:port,host:port"

    # Browser-facing host for LiveView websocket origin checks.
    # Set to the LAN/Tailscale hostname or IP operators use in the browser URL.
    # ORCHARD_PUBLIC_HOST="replace-with-lan-or-tailscale-host"

    # ── Packaged Paths (auto-detected) ────────────────────────────────

    # Defaults to the packaged tokenizer path under support_root/native/.
    # Override only when intentionally using a custom tokenizer executable.
    ORCHARD_TOKENIZER_EXECUTABLE=#{shell_quote(tokenizer_path)}
    """
  end

  defp render_env(:node_agent, support_root, hostname) do
    worker_path = resolve_executable(:worker, support_root)

    """
    # Orchard Node Agent Environment
    # Generated by: orchardctl env init
    #
    # This file is sourced as POSIX shell. All values with spaces MUST be quoted.
    # See: packaging/pkg/README.md

    # ── Node Agent Network ────────────────────────────────────────────

    # Node-agent bind host. Default runtime behavior is loopback-only.
    # Set 0.0.0.0 when this node must be reachable by a remote controller.
    # ORCHARD_NODE_AGENT_LISTEN_HOST="0.0.0.0"

    # Node-agent gRPC listen port.
    # Packaged default is 50061 (source-dev scripts typically use 50071).
    # ORCHARD_NODE_AGENT_LISTEN_PORT="50061"

    # ── Node Identity ─────────────────────────────────────────────────

    # Friendly node name shown in controller inventory/status views.
    ORCHARD_NODE_DISPLAY_NAME=#{shell_quote(hostname)}
    ORCHARD_WORKER_BACKEND="mlx"

    # ── Packaged Paths (auto-detected) ────────────────────────────────

    # Defaults to the packaged worker path under support_root/native/.
    # Override only when intentionally using a custom worker executable.
    ORCHARD_WORKER_EXECUTABLE=#{shell_quote(worker_path)}

    # ── Future Join / Bootstrap Placeholders (M3, not active yet) ─────

    # Pending M3 join flow: these placeholders are documentation only today.
    # Do not set until M3 join/bootstrap support is implemented.
    # ORCHARD_JOIN_CONTROLLER_TARGET="controller-host:50061"
    # ORCHARD_JOIN_BOOTSTRAP_TOKEN="replace-with-issued-token"
    # ORCHARD_JOIN_TLS_CA_PATH="/Library/Application Support/Orchard/config/tls/ca.crt"
    """
  end

  defp build_controller_settings(runtime) do
    secret_key_base = generate_secret_key_base(runtime)
    user_result = resolve_current_user(runtime)
    postgresql_result = detect_postgresql(runtime)

    case {user_result, postgresql_result} do
      {{:ok, username}, {:ok, _postgres_path}} ->
        database_url = "ecto://#{username}@localhost:5432/#{@default_db_name}"

        %{
          secret_key_base: secret_key_base,
          database_url: database_url,
          database_url_line: "DATABASE_URL=#{shell_quote(database_url)}",
          notes: [
            "SECRET_KEY_BASE generated.",
            "DATABASE_URL generated for local PostgreSQL."
          ]
        }

      {{:error, :unknown_user}, _} ->
        %{
          secret_key_base: secret_key_base,
          database_url: nil,
          database_url_line: "# DATABASE_URL=\"ecto://USER@localhost:5432/#{@default_db_name}\"",
          notes: [
            "SECRET_KEY_BASE generated.",
            "Could not resolve current user; DATABASE_URL left commented for manual setup."
          ]
        }

      _ ->
        %{
          secret_key_base: secret_key_base,
          database_url: nil,
          database_url_line: "# DATABASE_URL=\"ecto://USER@localhost:5432/#{@default_db_name}\"",
          notes: [
            "SECRET_KEY_BASE generated.",
            "PostgreSQL executable not detected; DATABASE_URL left commented for manual setup."
          ]
        }
    end
  end

  defp resolve_current_user(runtime) do
    current_user_fn = Map.fetch!(runtime, :current_user)

    case current_user_fn.() do
      {:ok, user} when is_binary(user) ->
        user = String.trim(user)

        if user == "" do
          {:error, :unknown_user}
        else
          {:ok, user}
        end

      _ ->
        {:error, :unknown_user}
    end
  end

  defp detect_postgresql(runtime) do
    case Map.get(runtime, :detect_postgresql) do
      detector when is_function(detector, 0) ->
        detector.()

      _ ->
        finder = Map.fetch!(runtime, :find_executable)

        homebrew_candidates =
          Path.wildcard("/opt/homebrew/opt/postgresql*/bin/psql") ++
            Path.wildcard("/usr/local/opt/postgresql*/bin/psql")

        case Enum.find(homebrew_candidates, &executable?/1) || finder.("psql") do
          nil -> :error
          path -> {:ok, path}
        end
    end
  end

  defp maybe_create_database(_runtime, %{database_url: nil}), do: []

  defp maybe_create_database(runtime, %{database_url: _database_url}) do
    finder = Map.fetch!(runtime, :find_executable)

    with {:ok, username} <- resolve_current_user(runtime),
         createdb_path when is_binary(createdb_path) <- detect_createdb(finder) do
      run_createdb(runtime, createdb_path, username)
    else
      {:error, :unknown_user} ->
        ["Could not resolve current user for createdb; database auto-create skipped."]

      nil ->
        ["createdb not found; database auto-create skipped."]

      _ ->
        ["createdb invocation skipped due to unsupported runtime command configuration."]
    end
  end

  defp run_createdb(runtime, createdb_path, username) do
    cmd = Map.fetch!(runtime, :cmd)
    args = ["-U", username, @default_db_name]

    case cmd.(createdb_path, args, stderr_to_stdout: true) do
      {:ok, _output} ->
        ["Database #{@default_db_name} created (or already available)."]

      {:error, _status, output} ->
        createdb_error_note(output)
    end
  end

  defp createdb_error_note(output) do
    if String.contains?(String.downcase(output), "already exists") do
      ["Database #{@default_db_name} already exists."]
    else
      ["Database auto-create failed; continue after creating #{@default_db_name} manually."]
    end
  end

  defp detect_createdb(finder) do
    homebrew_candidates =
      Path.wildcard("/opt/homebrew/opt/postgresql*/bin/createdb") ++
        Path.wildcard("/usr/local/opt/postgresql*/bin/createdb")

    Enum.find(homebrew_candidates, &executable?/1) || finder.("createdb")
  end

  defp generate_secret_key_base(runtime) do
    strong_rand_bytes = Map.fetch!(runtime, :strong_rand_bytes)

    32
    |> strong_rand_bytes.()
    |> Base.encode16(case: :lower)
  end

  # ── Shell Quoting ────────────────────────────────────────────────────

  # credo:disable-for-lines:2 ExSlop.Check.Readability.DocFalseOnPublicFunction
  @doc false
  def shell_quote(value) when is_binary(value) do
    if String.contains?(value, ["\n", "\0"]) do
      raise ArgumentError, "env value contains newline or NUL: #{inspect(value)}"
    end

    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("$", "\\$")
      |> String.replace("`", "\\`")
      |> String.replace("#", "\\#")

    "\"#{escaped}\""
  end

  # ── File I/O ────────────────────────────────────────────────────────

  defp ensure_config_dir(config_dir) do
    unless File.dir?(config_dir) do
      File.mkdir_p!(config_dir)
      File.chmod!(config_dir, 0o700)
    end
  end

  defp write_env_file(target_path, content) do
    dir = Path.dirname(target_path)
    tmp_path = Path.join(dir, ".#{Path.basename(target_path)}.tmp")

    try do
      File.write!(tmp_path, content)
      File.chmod!(tmp_path, 0o600)
      File.rename!(tmp_path, target_path)
    rescue
      e ->
        File.rm(tmp_path)
        reraise e, __STACKTRACE__
    end
  end

  # ── Hostname Discovery ──────────────────────────────────────────────

  defp discover_hostname(runtime) do
    hostname_fn = Map.get(runtime, :hostname, fn -> :inet.gethostname() end)

    case hostname_fn.() do
      {:ok, name} when is_list(name) -> List.to_string(name)
      {:ok, name} when is_binary(name) -> name
      _ -> "orchard-node"
    end
  end

  # ── Support Root ────────────────────────────────────────────────────

  defp resolve_support_root(opts) do
    Keyword.get(
      opts,
      :support_root,
      System.get_env("ORCHARD_SUPPORT_ROOT") || @default_support_root
    )
  end

  # ── Result Formatting ───────────────────────────────────────────────

  defp format_results(results) do
    lines =
      Enum.flat_map(results, fn {target, result} ->
        label = env_filename(target)

        status = result_status(result)

        status_line =
          case status do
            :created ->
              "  ✓ #{label} — created"

            :overwritten ->
              "  ✓ #{label} — overwritten"

            :skipped_existing ->
              "  ○ #{label} — skipped (already exists, use --force to overwrite)"
          end

        notes =
          result_notes(result)
          |> Enum.map(fn note -> "      - #{note}" end)

        [status_line | notes]
      end)

    summary = Enum.join(["Environment files:" | lines], "\n")
    {:ok, summary}
  end

  defp result_status(%{status: status}), do: status
  defp result_status(status) when is_atom(status), do: status

  defp result_notes(%{notes: notes}) when is_list(notes), do: notes
  defp result_notes(_), do: []

  # ── Default Runtime ─────────────────────────────────────────────────

  defp default_runtime do
    %{
      hostname: fn -> :inet.gethostname() end,
      current_user: &default_current_user/0,
      find_executable: &System.find_executable/1,
      cmd: &default_cmd/3,
      strong_rand_bytes: &:crypto.strong_rand_bytes/1
    }
  end

  defp default_current_user do
    sudo_user = System.get_env("SUDO_USER")
    user = System.get_env("USER")

    cond do
      present?(sudo_user) -> {:ok, String.trim(sudo_user)}
      present?(user) -> {:ok, String.trim(user)}
      true -> fallback_current_user()
    end
  end

  defp fallback_current_user do
    case default_cmd("id", ["-un"], stderr_to_stdout: true) do
      {:ok, output} -> normalize_resolved_user(output)
      _ -> {:error, :unknown_user}
    end
  end

  defp normalize_resolved_user(output) do
    value = String.trim(output)

    if value == "" do
      {:error, :unknown_user}
    else
      {:ok, value}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp default_cmd(command, args, opts) do
    {stderr_to_stdout, system_opts} = Keyword.pop(opts, :stderr_to_stdout, false)

    try do
      {output, status} =
        System.cmd(command, args, [{:stderr_to_stdout, stderr_to_stdout} | system_opts])

      if status == 0 do
        {:ok, output}
      else
        {:error, status, output}
      end
    rescue
      _ ->
        {:error, 127, "command failed: #{command}"}
    end
  end

  # ── Usage Text ──────────────────────────────────────────────────────

  defp group_usage do
    """
    orchardctl env <command>

    Commands:
      init        Generate env files for packaged services

    Run `orchardctl env <command> --help` for command-specific options.
    """
    |> String.trim()
  end

  defp init_usage do
    """
    orchardctl env init [options]

    Generate controller.env and node-agent.env with correctly-quoted
    paths for the packaged Orchard installation. Values containing spaces are
    safely shell-quoted.

    Options:
      --support-root PATH    Support root directory
                             (default: $ORCHARD_SUPPORT_ROOT or /Library/Application Support/Orchard)
      --service SERVICE      Generate for: controller, node-agent, or all (default: all)
      --force                Overwrite existing env files
      --help                 Show this help

    Examples:
      sudo orchardctl env init
      sudo orchardctl env init --service controller
      sudo orchardctl env init --force
    """
    |> String.trim()
  end
end
