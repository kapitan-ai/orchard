defmodule OrchardCLI.Commands.Env do
  @moduledoc """
  CLI handler for `orchardctl env` commands.

  Supports:
    orchardctl env init [options]     — Generate env file templates for packaged services
  """

  @default_support_root "/Library/Application Support/Orchard"

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

    # Pre-validate: check all required executables exist before writing anything
    with :ok <- validate_executables(targets, support_root) do
      config_dir = Path.join(support_root, "config")

      try do
        ensure_config_dir(config_dir)

        results =
          Enum.map(targets, fn target ->
            {target, generate_env_file(target, config_dir, support_root, hostname, force)}
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

  defp generate_env_file(target, config_dir, support_root, hostname, force) do
    filename = env_filename(target)
    target_path = Path.join(config_dir, filename)

    cond do
      not File.regular?(target_path) ->
        content = render_env(target, support_root, hostname)
        write_env_file(target_path, content)
        :created

      force ->
        content = render_env(target, support_root, hostname)
        write_env_file(target_path, content)
        :overwritten

      true ->
        :skipped_existing
    end
  end

  defp env_filename(:controller), do: "controller.env"
  defp env_filename(:node_agent), do: "node-agent.env"

  defp render_env(:controller, support_root, _hostname) do
    tokenizer_path = resolve_executable(:tokenizer, support_root)

    """
    # Orchard Controller Environment
    # Generated by: orchardctl env init
    #
    # This file is sourced as POSIX shell. All values with spaces MUST be quoted.
    # See: packaging/pkg/README.md

    # ── Required (fill these in) ──────────────────────────────────────

    # DATABASE_URL="postgres://USER:PASSWORD@localhost:5432/orchard_controller"
    # SECRET_KEY_BASE="generate-with: mix phx.gen.secret"

    # ── Optional ──────────────────────────────────────────────────────

    # Browser-facing host for LiveView websocket origin check.
    # Set to the IP or hostname clients use to reach the console.
    # ORCHARD_PUBLIC_HOST="replace-with-browser-host-or-ip"

    # ── Packaged Paths (auto-detected) ────────────────────────────────

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

    # ── Node Identity ─────────────────────────────────────────────────

    ORCHARD_NODE_DISPLAY_NAME=#{shell_quote(hostname)}
    ORCHARD_WORKER_BACKEND="mlx"

    # ── Packaged Paths (auto-detected) ────────────────────────────────

    ORCHARD_WORKER_EXECUTABLE=#{shell_quote(worker_path)}
    """
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
        # Clean up temp file on failure
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
      Enum.map(results, fn {target, status} ->
        label = env_filename(target)

        case status do
          :created -> "  ✓ #{label} — created"
          :overwritten -> "  ✓ #{label} — overwritten"
          :skipped_existing -> "  ○ #{label} — skipped (already exists, use --force to overwrite)"
        end
      end)

    summary = Enum.join(["Environment files:" | lines], "\n")
    {:ok, summary}
  end

  # ── Default Runtime ─────────────────────────────────────────────────

  defp default_runtime do
    %{
      hostname: fn -> :inet.gethostname() end
    }
  end

  # ── Usage Text ──────────────────────────────────────────────────────

  defp group_usage do
    """
    orchardctl env <command>

    Commands:
      init        Generate env file templates for packaged services

    Run `orchardctl env <command> --help` for command-specific options.
    """
    |> String.trim()
  end

  defp init_usage do
    """
    orchardctl env init [options]

    Generate controller.env and node-agent.env templates with correctly-quoted
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
