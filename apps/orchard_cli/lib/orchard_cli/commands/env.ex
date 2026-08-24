defmodule OrchardCLI.Commands.Env do
  @moduledoc """
  CLI handler for `orchardctl env` commands.

  Supports:
    orchardctl env init [options]     — Generate env files for packaged services
  """

  alias OrchardCLI.ShellEnv

  @default_support_root "/Library/Application Support/Orchard"
  @default_db_name "orchard_controller"

  # ── Public API ──────────────────────────────────────────────────────

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  # Public only so tests can inject filesystem/process runtime without exposing CLI API docs.
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

  # Installer tests inspect binary resolution without promoting this to public CLI API.
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
           "Ensure the Orchard application payload was installed correctly.", 1}
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
    ShellEnv.write_file(target_path, content)

    %{status: status, notes: controller_settings.notes}
  end

  defp write_rendered_env(:node_agent, target_path, support_root, hostname, _runtime, status) do
    content = render_env(:node_agent, support_root, hostname)
    ShellEnv.write_file(target_path, content)

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
    # See: packaging/README.md

    # ── Required ──────────────────────────────────────────────────────

    # Operator-managed external PostgreSQL is required for packaged controller installs.
    # Managed Postgres is unavailable in this build.
    #{controller_settings.database_url_line}
    SECRET_KEY_BASE=#{shell_quote(controller_settings.secret_key_base)}

    # ── Optional ──────────────────────────────────────────────────────

    # Public API transport mode for packaged controller releases.
    # plain_http_localhost: degraded loopback HTTP for local/recovery use.
    # direct_https: controller terminates HTTPS with operator cert/key paths
    # or explicit local-CA helper output from `orchardctl tls init`.
    # reverse_proxy: controller listens on a local HTTP backend; an operator
    # proxy terminates public HTTPS. Orchard does not generate or procure
    # production TLS certificates by default.
    # ORCHARD_TRANSPORT_MODE="plain_http_localhost"

    # Reverse-proxy backend/public URL settings.
    # Default backend bind is loopback. If ORCHARD_API_BIND_IP is non-loopback
    # in reverse_proxy mode, ORCHARD_TRUSTED_PROXIES must be set to CIDRs for
    # the proxy hops allowed to supply x-forwarded-* headers.
    # ORCHARD_API_BIND_IP="127.0.0.1"
    # PORT="4000"
    # ORCHARD_PUBLIC_PORT="443"
    # ORCHARD_TRUSTED_PROXIES="127.0.0.1/32,::1/128"

    # Direct HTTPS certificate paths. Use operator-owned certs from a public,
    # paid/proprietary, or internal PKI CA; or use explicit local-CA helper
    # output for dev-lab bootstrap. /ca.crt publishes only generated-local CA
    # metadata output, never operator CA/cert material.
    # ORCHARD_TLS_CERTFILE="/path/to/server.crt"
    # ORCHARD_TLS_KEYFILE="/path/to/server.key"
    # ORCHARD_TLS_CACERTFILE="/path/to/ca.crt"

    # ── Runtime Endpoint: BEAM-first packaged multi-Mac ───────────────

    # BEAM Runtime Endpoint is the packaged multi-Mac happy path.
    # Leave this as beam unless intentionally opting into gRPC compatibility.
    ORCHARD_RUNTIME_ENDPOINT_TRANSPORT="beam"

    # Controller BEAM node name. Replace 127.0.0.1 with this Mac's private
    # IPv4 address for multi-Mac installs. Remote BEAM targets are rejected
    # when the controller node name still uses a loopback host.
    ORCHARD_BEAM_NODE_NAME="orchard_controller@127.0.0.1"

    # Shared BEAM cookie file. Provision the same owner-only file on every
    # controller and node-agent Mac before starting services.
    # Example:
    # sudo install -d -o root -g wheel -m 0750 #{shell_quote(Path.join([support_root, "config"]))}
    # openssl rand -base64 48 | sudo tee #{shell_quote(Path.join([support_root, "config", "beam.cookie"]))} >/dev/null
    # sudo chown root:wheel #{shell_quote(Path.join([support_root, "config", "beam.cookie"]))}
    # sudo chmod 0600 #{shell_quote(Path.join([support_root, "config", "beam.cookie"]))}
    ORCHARD_BEAM_COOKIE_FILE=#{shell_quote(Path.join([support_root, "config", "beam.cookie"]))}

    # Controller target node names. Use BEAM node names, not gRPC host:port
    # targets. Replace with the private IPv4 address for each node-agent Mac.
    # ORCHARD_RUNTIME_ENDPOINT_TARGETS="orchard_node_agent@10.0.0.21,orchard_node_agent@10.0.0.22"
    # For an all-in-one host with the packaged node-agent service:
    # ORCHARD_RUNTIME_ENDPOINT_TARGETS="orchard_node_agent@127.0.0.1"

    # EPMD and BEAM distribution ports. If another EPMD owns 4369, set the
    # same nonstandard ORCHARD_BEAM_EPMD_PORT on every participating Mac.
    ORCHARD_BEAM_EPMD_PORT="4369"
    ORCHARD_BEAM_DIST_PORT_MIN="52171"
    ORCHARD_BEAM_DIST_PORT_MAX="52171"

    # gRPC compatibility fallback. Use only when intentionally opting out of
    # BEAM by setting ORCHARD_RUNTIME_ENDPOINT_TRANSPORT="grpc" on controller
    # and node-agent hosts.
    # ORCHARD_RUNTIME_CLIENT_TARGETS="10.0.0.21:50061,10.0.0.22:50061"

    # Browser-facing host for LiveView websocket origin checks.
    # Set to the LAN/Tailscale hostname or IP operators use in the browser URL.
    # In reverse_proxy mode this is the public HTTPS host exposed by the proxy.
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
    # See: packaging/README.md

    # ── Runtime Endpoint: BEAM-first packaged multi-Mac ───────────────

    # BEAM Runtime Endpoint is the packaged multi-Mac happy path.
    # Leave this as beam unless intentionally opting into gRPC compatibility.
    ORCHARD_RUNTIME_ENDPOINT_TRANSPORT="beam"

    # Node-agent BEAM node name. Replace 127.0.0.1 with this Mac's private
    # IPv4 address for multi-Mac installs.
    ORCHARD_BEAM_NODE_NAME="orchard_node_agent@127.0.0.1"

    # Shared BEAM cookie file. Use the same owner-only file as the controller.
    # The file must be root-owned and mode 0600 before the service starts.
    # Copy the same cookie contents to every participating Mac.
    ORCHARD_BEAM_COOKIE_FILE=#{shell_quote(Path.join([support_root, "config", "beam.cookie"]))}

    # EPMD and BEAM distribution ports. If another EPMD owns 4369, set the
    # same nonstandard ORCHARD_BEAM_EPMD_PORT on every participating Mac.
    ORCHARD_BEAM_EPMD_PORT="4369"
    ORCHARD_BEAM_DIST_PORT_MIN="52172"
    ORCHARD_BEAM_DIST_PORT_MAX="52172"

    # ── gRPC Compatibility Listener ───────────────────────────────────

    # Node-agent gRPC bind host.
    # Default is loopback so first start does not expose unauthenticated gRPC.
    # Change to a private interface address or 0.0.0.0 only when explicitly
    # running the gRPC compatibility path on a trusted private network or VPN
    # with firewall controls. Do not expose this port to the public internet.
    ORCHARD_NODE_AGENT_LISTEN_HOST="127.0.0.1"
    # ORCHARD_NODE_AGENT_LISTEN_HOST="0.0.0.0"

    # Node-agent gRPC listen port for compatibility/fallback mode.
    # Packaged default is 50061 (source-dev scripts typically use 50071).
    ORCHARD_NODE_AGENT_LISTEN_PORT="50061"

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

    %{
      secret_key_base: secret_key_base,
      database_url_line:
        "# DATABASE_URL=\"ecto://USER:PASSWORD@postgres.example.internal:5432/#{@default_db_name}?ssl=true\"",
      notes: [
        "SECRET_KEY_BASE generated.",
        "DATABASE_URL left for operator-managed external PostgreSQL."
      ]
    }
  end

  defp generate_secret_key_base(runtime) do
    strong_rand_bytes = Map.fetch!(runtime, :strong_rand_bytes)

    32
    |> strong_rand_bytes.()
    |> Base.encode16(case: :lower)
  end

  # ── Shell Quoting ────────────────────────────────────────────────────

  # Env-file tests inspect quoting without promoting this helper to public CLI API.
  # credo:disable-for-lines:2 ExSlop.Check.Readability.DocFalseOnPublicFunction
  @doc false
  def shell_quote(value) when is_binary(value), do: ShellEnv.shell_quote(value)

  # ── File I/O ────────────────────────────────────────────────────────

  defp ensure_config_dir(config_dir) do
    unless File.dir?(config_dir) do
      File.mkdir_p!(config_dir)
      File.chmod!(config_dir, 0o700)
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
      strong_rand_bytes: &:crypto.strong_rand_bytes/1
    }
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
