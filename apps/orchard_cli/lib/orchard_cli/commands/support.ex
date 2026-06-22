defmodule OrchardCLI.Commands.Support do
  @moduledoc false

  alias OrchardCLI.Commands.{LifecycleSupport, Status}

  @default_support_root "/Library/Application Support/Orchard"
  @default_max_log_bytes 1_048_576
  @usage_exit_code 2

  @config_files ~w(controller.env node-agent.env console.env)
  @sensitive_env_fragments ~w(
    access_key activation apikey api_key authorization bearer cacertfile certfile cookie
    database_url dsn keyfile license password pem private_key secret sentry_dsn token
  )
  @sensitive_log_markers [
    "authorization",
    "bearer ",
    "cookie:",
    "database_url",
    "postgres://",
    "ecto://",
    "secret",
    "private_key",
    "license",
    "api_key",
    "x-api-key",
    "sentry_dsn",
    "canonical_request",
    "request_payload",
    "response_payload",
    "\"messages\"",
    "\"prompt\"",
    "prompt="
  ]

  @type runtime :: map()
  @type command_opts :: %{
          required(:json?) => boolean(),
          required(:max_log_bytes) => non_neg_integer(),
          required(:output_dir) => String.t() | nil,
          required(:support_root) => String.t()
        }

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  @doc false
  @spec run([String.t()], runtime()) :: OrchardCLI.command_result()
  def run([], _runtime), do: {:error, group_usage(), 1}
  def run(["help"], _runtime), do: {:ok, group_usage()}
  def run(["--help"], _runtime), do: {:ok, group_usage()}

  def run(["bundle"], _runtime),
    do: usage_error("Missing support bundle subcommand.", group_usage())

  def run(["bundle", "help"], _runtime), do: {:ok, bundle_usage()}
  def run(["bundle", "--help"], _runtime), do: {:ok, bundle_usage()}
  def run(["bundle", "create" | rest], runtime), do: run_create(rest, runtime)

  def run([arg | _rest], _runtime) do
    if option?(arg) do
      usage_error("Unknown option: #{arg}", group_usage())
    else
      usage_error("Unknown support subcommand: #{arg}", group_usage())
    end
  end

  defp run_create(args, runtime) do
    case parse_create_args(args, default_create_opts(runtime)) do
      {:run, opts} -> create_bundle(opts, runtime)
      :help -> {:ok, create_usage()}
      {:error, message} -> usage_error(message, create_usage())
    end
  end

  defp parse_create_args(["help"], _opts), do: :help

  defp parse_create_args(args, opts) do
    case rejected_boolean_negation(args) do
      nil ->
        parse_create_options(args, opts)

      option ->
        {:error, "Unknown option: #{option}"}
    end
  end

  defp parse_create_options(args, opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          support_root: :string,
          max_log_bytes: :integer,
          json: :boolean,
          help: :boolean
        ],
        aliases: [o: :output]
      )

    cond do
      invalid != [] ->
        {option, _value} = List.first(invalid)
        {:error, "Unknown option: #{option}"}

      rest != [] ->
        {:error, "Unexpected argument for support bundle create: #{List.first(rest)}"}

      Keyword.get(parsed, :help, false) ->
        :help

      Keyword.get(parsed, :max_log_bytes, opts.max_log_bytes) < 0 ->
        {:error, "--max-log-bytes must be greater than or equal to 0"}

      true ->
        {:run,
         %{
           opts
           | json?: Keyword.get(parsed, :json, false),
             max_log_bytes: Keyword.get(parsed, :max_log_bytes, opts.max_log_bytes),
             output_dir: Keyword.get(parsed, :output, opts.output_dir),
             support_root: Keyword.get(parsed, :support_root, opts.support_root)
         }}
    end
  end

  defp rejected_boolean_negation(args), do: Enum.find(args, &(&1 in ["--no-json", "--no-help"]))

  defp create_bundle(opts, runtime) do
    now = runtime.now.()
    output_dir = opts.output_dir || Path.join(opts.support_root, "support")
    basename = "orchard-support-bundle-#{timestamp_for_path(now)}"
    bundle_name = available_bundle_name(output_dir, basename)
    archive_path = Path.join(output_dir, bundle_name <> ".tar.gz")
    path_nonce = runtime.path_nonce.()
    temp_archive_path = Path.join(output_dir, ".#{bundle_name}-#{path_nonce}.tar.gz.tmp")
    stage_dir = Path.join(output_dir, ".#{bundle_name}-#{path_nonce}.stage")

    result =
      try do
        ensure_output_dir!(output_dir)

        File.rm_rf!(stage_dir)
        File.rm(temp_archive_path)
        ensure_private_dir!(stage_dir)
        build_stage!(stage_dir, opts, runtime, now)

        with :ok <- runtime.archive.(stage_dir, temp_archive_path),
             :ok <- secure_archive(temp_archive_path),
             :ok <- move_archive(temp_archive_path, archive_path) do
          audit =
            record_audit(runtime, %{
              archive_name: Path.basename(archive_path),
              bundle_format: "orchard.support_bundle.v1",
              generated_at: DateTime.to_iso8601(now),
              max_log_bytes: opts.max_log_bytes
            })

          bundle = %{
            archive_path: archive_path,
            audit: audit,
            generated_at: DateTime.to_iso8601(now)
          }

          {:ok, bundle}
        end
      rescue
        exception ->
          {:error, "Error: failed to create support bundle: #{Exception.message(exception)}", 1}
      catch
        kind, reason ->
          {:error, "Error: failed to create support bundle: #{inspect({kind, reason})}", 1}
      after
        File.rm_rf(stage_dir)
        File.rm(temp_archive_path)
      end

    case result do
      {:ok, bundle} -> {:ok, render_success(bundle, opts)}
      {:error, message, code} -> {:error, message, code}
      {:error, message} -> {:error, message, 1}
    end
  end

  defp build_stage!(stage_dir, opts, runtime, now) do
    write_text!(stage_dir, "README.txt", readme_text())
    write_json!(stage_dir, "manifest.json", manifest(opts, runtime, now))
    write_json!(stage_dir, "diagnostics/system.json", system_snapshot(opts, runtime, now))
    write_json!(stage_dir, "diagnostics/status.json", status_snapshot(opts.support_root, runtime))

    write_json!(
      stage_dir,
      "diagnostics/services.json",
      service_snapshot(opts.support_root, runtime)
    )

    write_json!(stage_dir, "diagnostics/nodes.json", nodes_snapshot(runtime))
    write_json!(stage_dir, "diagnostics/requests.json", requests_snapshot(runtime))

    collect_config!(stage_dir, opts.support_root)
    collect_logs!(stage_dir, opts.support_root, opts.max_log_bytes)
  end

  defp manifest(opts, runtime, now) do
    %{
      bundle_format: "orchard.support_bundle.v1",
      command: "orchardctl support bundle create",
      generated_at: DateTime.to_iso8601(now),
      orchard_version: runtime.version.(),
      max_log_bytes: opts.max_log_bytes,
      spec_references: [
        "SPEC.md 7.3.1 Operator API support-bundles endpoint",
        "SPEC.md 11.9 CLI orchardctl support bundle create",
        "SPEC.md Milestone 5 support bundle contains logs, config, node snapshots, request summary"
      ],
      contents: [
        "diagnostics/system.json",
        "diagnostics/status.json",
        "diagnostics/services.json",
        "diagnostics/nodes.json",
        "diagnostics/requests.json",
        "config/*.env redacted when present",
        "logs/** bounded and redacted tail copies when present"
      ]
    }
  end

  defp system_snapshot(_opts, runtime, now) do
    %{
      status: "ok",
      data: %{
        generated_at: DateTime.to_iso8601(now),
        orchard_version: runtime.version.(),
        elixir_version: System.version(),
        otp_release: System.otp_release(),
        os_type: inspect(:os.type())
      }
    }
  end

  defp status_snapshot(support_root, runtime) do
    status_runtime =
      runtime
      |> Map.put(:read_install_role, fn -> File.read(install_role_marker(support_root)) end)
      |> Map.put(:endpoint_metadata_path, Path.join([support_root, "public", "endpoint.json"]))

    safe_snapshot(fn ->
      runtime.status_snapshot.(status_runtime)
      |> Orchard.SentryFilter.filter()
    end)
  end

  defp service_snapshot(support_root, runtime) do
    service_runtime =
      Map.put(runtime, :read_install_role, fn -> File.read(install_role_marker(support_root)) end)

    safe_snapshot(fn ->
      role = detected_role(service_runtime)

      %{
        role: role,
        services:
          :start
          |> LifecycleSupport.services(service_runtime)
          |> Enum.map(&service_status(&1, service_runtime))
      }
    end)
  end

  defp nodes_snapshot(runtime) do
    safe_snapshot(fn ->
      %{
        summary: runtime.nodes_summary.(),
        nodes: Enum.map(runtime.list_nodes.(), &node_summary/1)
      }
    end)
  end

  defp requests_snapshot(runtime) do
    safe_snapshot(fn ->
      %{
        summary: runtime.requests_summary.(),
        performance: runtime.requests_performance_summary.(),
        recent: Enum.map(runtime.list_recent_requests.(25), &request_summary/1)
      }
    end)
  end

  defp safe_snapshot(fun) do
    %{status: "ok", data: fun.()}
  rescue
    exception ->
      %{status: "unavailable", error: "snapshot unavailable", reason: exception_type(exception)}
  catch
    kind, _reason ->
      %{status: "unavailable", error: "snapshot unavailable", reason: inspect(kind)}
  end

  defp exception_type(%{__struct__: module}), do: inspect(module)

  defp detected_role(runtime) do
    case LifecycleSupport.detect_install_role(runtime) do
      {:ok, role} -> LifecycleSupport.display_role(role)
      {:error, reason, _message, _code} -> Atom.to_string(reason)
    end
  end

  defp service_status(service, runtime) do
    file_regular? = Map.get(runtime, :file_regular?, &File.regular?/1)

    %{
      id: service.id,
      label: service.label,
      display_name: service.display_name,
      plist: Path.basename(service.plist_path),
      plist_present: file_regular?.(service.plist_path),
      launchd_loaded: LifecycleSupport.service_loaded?(service, runtime)
    }
  end

  defp node_summary(node) do
    %{
      id: field(node, :id),
      display_name: field(node, :display_name),
      hostname: field(node, :hostname),
      state: field(node, :state),
      health: field(node, :health),
      agent_version: field(node, :agent_version),
      last_heartbeat_at: field(node, :last_heartbeat_at),
      connect_host: field(node, :connect_host),
      connect_port: field(node, :connect_port),
      capabilities: field(node, :capabilities),
      tool_readiness: field(node, :tool_readiness)
    }
  end

  defp request_summary(request) do
    %{
      id: field(request, :id),
      public_id: field(request, :public_id),
      endpoint: field(request, :endpoint),
      requested_model: field(request, :requested_model),
      state: field(request, :state),
      stream: field(request, :stream),
      node_id: field(request, :node_id),
      http_status: field(request, :http_status),
      error_code: field(request, :error_code),
      input_tokens: field(request, :input_tokens),
      output_tokens: field(request, :output_tokens),
      inserted_at: field(request, :inserted_at),
      completed_at: field(request, :completed_at)
    }
  end

  defp collect_config!(stage_dir, support_root) do
    copied =
      support_root
      |> Path.join("config")
      |> config_paths()
      |> Enum.reduce(0, fn {source_path, dest_name}, count ->
        if File.regular?(source_path) do
          contents = source_path |> File.read!() |> redact_env_file()
          write_text!(stage_dir, Path.join("config", dest_name), contents)
          count + 1
        else
          count
        end
      end)

    if copied == 0 do
      write_text!(stage_dir, "config/README.txt", "No Orchard env config files were found.\n")
    end
  end

  defp config_paths(config_dir) do
    Enum.map(@config_files, fn file -> {Path.join(config_dir, file), file} end)
  end

  defp redact_env_file(contents) do
    contents
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", &redact_env_line/1)
  end

  defp redact_env_line("#" <> _rest = line), do: line
  defp redact_env_line(""), do: ""

  defp redact_env_line(line) do
    case String.split(line, "=", parts: 2) do
      [key, _value] ->
        if sensitive_env_key?(key), do: "#{key}=[redacted]", else: line

      _other ->
        line
    end
  end

  defp sensitive_env_key?(key) do
    normalized = key |> String.trim() |> String.downcase()
    Enum.any?(@sensitive_env_fragments, &String.contains?(normalized, &1))
  end

  defp collect_logs!(stage_dir, support_root, max_log_bytes) do
    logs_root = Path.join(support_root, "logs")

    case regular_files(logs_root) do
      [] ->
        write_text!(stage_dir, "logs/README.txt", "No Orchard log files were found.\n")

      paths ->
        Enum.each(paths, fn source_path ->
          rel = Path.relative_to(source_path, logs_root)
          dest = Path.join("logs", rel)

          write_text!(
            stage_dir,
            dest,
            source_path |> tail_file!(max_log_bytes) |> redact_log_file()
          )
        end)
    end
  end

  defp ensure_output_dir!(path) do
    existed? = File.dir?(path)
    File.mkdir_p!(path)
    unless existed?, do: File.chmod!(path, 0o700)
  end

  defp ensure_private_dir!(path) do
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
  end

  defp available_bundle_name(output_dir, basename),
    do: available_bundle_name(output_dir, basename, 0)

  defp available_bundle_name(output_dir, basename, 0) do
    if File.exists?(Path.join(output_dir, basename <> ".tar.gz")) do
      available_bundle_name(output_dir, basename, 1)
    else
      basename
    end
  end

  defp available_bundle_name(output_dir, basename, suffix) do
    candidate = "#{basename}-#{suffix}"

    if File.exists?(Path.join(output_dir, candidate <> ".tar.gz")) do
      available_bundle_name(output_dir, basename, suffix + 1)
    else
      candidate
    end
  end

  defp regular_files(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory}} -> regular_files_in_dir(root)
      _other -> []
    end
  end

  defp regular_files_in_dir(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      case File.lstat(path) do
        {:ok, %{type: :regular}} -> [path]
        {:ok, %{type: :directory}} -> regular_files_in_dir(path)
        _other -> []
      end
    end)
    |> Enum.sort()
  rescue
    _exception -> []
  end

  defp tail_file!(path, max_bytes) do
    {:ok, stat} = File.stat(path)

    {:ok, content} =
      File.open(path, [:read, :binary], fn file ->
        offset = max(stat.size - max_bytes, 0)
        {:ok, _position} = :file.position(file, offset)

        case IO.binread(file, max_bytes) do
          :eof -> ""
          data -> data
        end
      end)

    if stat.size > max_bytes do
      "[truncated to last #{max_bytes} bytes]\n" <> discard_partial_first_line(content)
    else
      content
    end
  end

  defp discard_partial_first_line(""), do: ""

  defp discard_partial_first_line(content) do
    case :binary.match(content, "\n") do
      {index, 1} -> binary_part(content, index + 1, byte_size(content) - index - 1)
      :nomatch -> ""
    end
  end

  defp redact_log_file(content) do
    if String.valid?(content) do
      content
      |> String.split("\n", trim: false)
      |> Enum.map_join("\n", &redact_log_line/1)
    else
      "[redacted binary log content]\n"
    end
  end

  defp redact_log_line(""), do: ""

  defp redact_log_line(line) do
    normalized = String.downcase(line)

    if Enum.any?(@sensitive_log_markers, &String.contains?(normalized, &1)) do
      "[redacted log line]"
    else
      line
    end
  end

  defp write_json!(stage_dir, relative_path, data) do
    write_text!(stage_dir, relative_path, Jason.encode!(json_safe(data), pretty: true) <> "\n")
  end

  defp write_text!(stage_dir, relative_path, content) do
    write_binary!(stage_dir, relative_path, content)
  end

  defp write_binary!(stage_dir, relative_path, content) do
    path = Path.join(stage_dir, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    File.chmod!(path, 0o600)
  end

  defp archive_stage(stage_dir, archive_path) do
    case System.cmd("tar", ["-czf", archive_path, "-C", stage_dir, "."], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, "Error: tar failed with exit #{code}: #{String.trim(output)}"}
    end
  end

  defp secure_archive(path) do
    case File.chmod(path, 0o600) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Error: failed to secure support bundle: #{:file.format_error(reason)}"}
    end
  end

  defp move_archive(temp_archive_path, archive_path) do
    if File.exists?(archive_path) do
      {:error, "Error: support bundle already exists: #{archive_path}"}
    else
      case File.rename(temp_archive_path, archive_path) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, "Error: failed to move support bundle: #{:file.format_error(reason)}"}
      end
    end
  end

  defp record_audit(runtime, event) do
    case runtime.audit_support_bundle.(event) do
      :ok -> %{status: "recorded"}
      :skipped -> %{status: "skipped", reason: "controller_repo_unavailable"}
      {:error, reason} -> %{status: "failed", reason: inspect(reason)}
      other -> %{status: "unknown", reason: inspect(other)}
    end
  rescue
    _exception in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      %{status: "skipped", reason: "audit unavailable"}

    exception ->
      %{status: "failed", reason: exception_type(exception)}
  catch
    kind, reason ->
      %{status: "failed", reason: inspect({kind, reason})}
  end

  defp render_success(
         %{archive_path: archive_path, audit: audit, generated_at: generated_at},
         %{json?: true}
       ) do
    Jason.encode!(%{
      archive_path: archive_path,
      audit: audit,
      generated_at: generated_at,
      bundle_format: "orchard.support_bundle.v1"
    })
  end

  defp render_success(%{archive_path: archive_path, audit: audit}, %{json?: false}) do
    """
    Created support bundle: #{archive_path}
    Audit: #{audit_line(audit)}
    Contents: manifest.json, diagnostics/, redacted config/, bounded redacted logs/
    """
    |> String.trim()
  end

  defp audit_line(%{status: "recorded"}), do: "recorded"
  defp audit_line(%{status: "skipped", reason: reason}), do: "skipped (#{reason})"
  defp audit_line(%{status: status, reason: reason}), do: "#{status} (#{reason})"
  defp audit_line(%{status: status}), do: status

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(%Date{} = value), do: Date.to_iso8601(value)
  defp json_safe(%Time{} = value), do: Time.to_iso8601(value)

  defp json_safe(value) when is_map(value) do
    value
    |> maybe_from_struct()
    |> Enum.reject(fn {key, _value} -> key == :__meta__ or key == "__meta__" end)
    |> Map.new(fn {key, nested} -> {json_key(key), json_safe(nested)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(nil), do: nil
  defp json_safe(true), do: true
  defp json_safe(false), do: false
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp maybe_from_struct(%{__struct__: _module} = value), do: Map.from_struct(value)
  defp maybe_from_struct(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: to_string(key)

  defp field(value, key) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, field_value} -> field_value
      :error -> Map.get(value, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil

  defp timestamp_for_path(%DateTime{} = now) do
    now
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z]/, "")
  end

  defp install_role_marker(support_root),
    do: Path.join([support_root, "support", ".install-role"])

  defp default_create_opts(runtime) do
    %{
      json?: false,
      max_log_bytes: @default_max_log_bytes,
      output_dir: nil,
      support_root: runtime.support_root.()
    }
  end

  defp default_runtime do
    %{
      archive: &archive_stage/2,
      audit_support_bundle: &Orchard.Governance.audit_support_bundle_generated/1,
      cmd: &System.cmd/3,
      file_regular?: &File.regular?/1,
      list_nodes: &Orchard.Nodes.list_nodes/0,
      list_recent_requests: &Orchard.Requests.list_recent_requests/1,
      nodes_summary: &Orchard.Nodes.summary/0,
      now: fn -> DateTime.utc_now() |> DateTime.truncate(:second) end,
      path_nonce: fn -> System.unique_integer([:positive]) |> Integer.to_string(36) end,
      requests_performance_summary: &Orchard.Requests.performance_summary/0,
      requests_summary: &Orchard.Requests.summary/0,
      status_snapshot: &Status.snapshot/1,
      support_root: fn -> System.get_env("ORCHARD_SUPPORT_ROOT") || @default_support_root end,
      version: fn -> Orchard.version() end
    }
  end

  defp group_usage do
    """
    orchardctl support

    Usage:
      orchardctl support help
      orchardctl support bundle create [options]

    Commands:
      bundle create    Create a local diagnostic support bundle (SPEC.md 11.9, M5).
    """
    |> String.trim()
  end

  defp bundle_usage do
    """
    orchardctl support bundle

    Usage:
      orchardctl support bundle create [options]

    Commands:
      create    Create a local diagnostic support bundle.
    """
    |> String.trim()
  end

  defp create_usage do
    """
    orchardctl support bundle create [options]

    Creates a local support bundle with bounded redacted logs, redacted config,
    service status, node snapshots, and request summaries.

    Options:
      --output DIR           Write the .tar.gz bundle to DIR.
      --support-root PATH    Read Orchard local state from PATH.
      --max-log-bytes BYTES  Include at most BYTES from each log file.
      --json                 Emit machine-readable creation output.
      --help                 Show this help.
    """
    |> String.trim()
  end

  defp readme_text do
    """
    Orchard support bundle

    This bundle was created by orchardctl support bundle create.
    It is intended for diagnostics under the SPEC.md M5 support-bundle contract.

    Redaction policy:
    - config/*.env files are line-redacted for keys that commonly contain secrets.
    - TLS keys, license bundles, model artifacts, and request payload bodies are not collected.
    - logs are bounded tail copies and lines containing common sensitive markers are redacted.
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp usage_error(message, usage), do: {:error, "#{message}\n\n#{usage}", @usage_exit_code}
  defp option?(arg), do: String.starts_with?(arg, "-")
end
