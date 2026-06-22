defmodule OrchardCLI.Commands.Support do
  @moduledoc false

  alias OrchardCLI.Commands.{LifecycleSupport, Status}

  @default_support_root "/Library/Application Support/Orchard"
  @default_max_log_bytes 1_048_576
  @default_max_log_files 32
  @default_max_total_log_bytes 8_388_608
  @default_max_log_discovery_entries 512
  @usage_exit_code 2

  @config_files ~w(controller.env node-agent.env console.env)
  @preferred_log_files ~w(controller.log node-agent.log console.log)
  @sensitive_key_parts ~w(
    activation authorization bearer cookie credential dsn keyfile password passwd passphrase pem
    secret signature
  )
  @sensitive_key_compounds ~w(
    access_key api_key apikey cacertfile certfile database_url license_certificate
    machine_certificate private_key security_token sentry_dsn x_amz_credential
    x_amz_security_token x_amz_signature x_api_key
  )
  @sensitive_key_compact_fragments ~w(
    accesskey accesstoken apitoken authtoken bearertoken clientsecret idtoken licensekey
    licensesecret licensetoken password passwd passphrase privatekey refreshtoken
    secretkey sessiontoken
  )
  @sensitive_key_compact_aliases ~w(dbpass pgpass pgpassfile)
  @sensitive_token_partners ~w(access api auth bearer id license refresh secret session)
  @sensitive_license_partners ~w(activation key secret token)
  @sensitive_bare_license_keys ~w(license orchard_license)
  @safe_diagnostic_keys ~w(
    completion_tokens input_tokens license_enforcement license_mode orchard_license_enforcement
    orchard_license_mode orchard_tokenizer_executable output_tokens prompt_tokens
    supports_prompt_token_ids token_count tokenizer_executable tokens_per_second total_tokens
    worker_supports_prompt_token_ids
  )
  @sensitive_log_payload_keys ~w(content input input_text message_content messages prompt prompt_text)
  @sensitive_log_literals [
    "postgres://",
    "ecto://",
    "canonical_request",
    "request_payload",
    "response_payload",
    "prompt_token_ids_length_mismatch",
    ~s("messages"),
    ~s("prompt"),
    "prompt="
  ]
  @assignment_key_regex ~r/(?:^|[\s,{;?&#])["']?([A-Za-z_][A-Za-z0-9_.\[\]-]*)["']?\s*(?:=>|:|=)/
  @bearer_value_regex ~r/\bbearer\s+[^\s,;]+/i
  @credential_url_userinfo_regex ~r/\b[a-z][a-z0-9+.-]*:\/\/[^\s\/?#@]*:[^\s\/?#@]*@[^\s\/?#]+/i
  @credential_token_assignment_regex ~r/\b(?:api|access|auth|bearer|id|refresh|session|license)[-_\s]+tokens?\s*(?:=>|:|=)/i
  @license_secret_assignment_regex ~r/\blicense[-_\s]+(?:activation|key|secret|token)\s*(?:=>|:|=)/i
  @secret_block_begin_regex ~r/-----BEGIN (?:[A-Z ]*PRIVATE KEY|LICENSE FILE|MACHINE FILE)-----/i
  @secret_block_end_regex ~r/-----END (?:[A-Z ]*PRIVATE KEY|LICENSE FILE|MACHINE FILE)-----/i
  @secret_block_regex ~r/-----BEGIN (?:[A-Z ]*PRIVATE KEY|LICENSE FILE|MACHINE FILE)-----|\bprivate[-_\s]+key\s*(?:=>|:|=)/i
  @temp_dir_attempts 20
  @archive_finalize_attempts 100

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

    result =
      try do
        ensure_output_dir!(output_dir)

        with_bundle_temp_root(output_dir, basename, runtime, fn temp_root ->
          stage_dir = Path.join(temp_root, "stage")
          archive_dir = Path.join(temp_root, "archive")
          temp_archive_path = Path.join(archive_dir, basename <> ".tar.gz.tmp")

          ensure_private_dir!(stage_dir)
          ensure_private_dir!(archive_dir)
          build_stage!(stage_dir, opts, runtime, now)

          with :ok <- runtime.archive.(stage_dir, temp_archive_path),
               :ok <- secure_archive(temp_archive_path),
               {:ok, archive_path} <- finalize_archive(temp_archive_path, output_dir, basename) do
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
        end)
      rescue
        exception ->
          {:error, "Error: failed to create support bundle: #{Exception.message(exception)}", 1}
      catch
        kind, reason ->
          {:error, "Error: failed to create support bundle: #{inspect({kind, reason})}", 1}
      end

    case result do
      {:ok, bundle} -> {:ok, render_success(bundle, opts)}
      {:error, message, code} -> {:error, message, code}
      {:error, message} -> {:error, message, 1}
    end
  end

  defp build_stage!(stage_dir, opts, runtime, now) do
    write_text!(stage_dir, "README.txt", readme_text())
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
    log_collection = collect_logs!(stage_dir, opts.support_root, opts.max_log_bytes, runtime)

    write_json!(stage_dir, "diagnostics/logs.json", %{
      status: "ok",
      data: log_collection
    })

    write_json!(stage_dir, "manifest.json", manifest(opts, runtime, now, log_collection))
  end

  defp manifest(opts, runtime, now, log_collection) do
    %{
      bundle_format: "orchard.support_bundle.v1",
      command: "orchardctl support bundle create",
      generated_at: DateTime.to_iso8601(now),
      orchard_version: runtime.version.(),
      max_log_bytes: opts.max_log_bytes,
      log_collection: manifest_log_collection(log_collection),
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
        "diagnostics/logs.json",
        "config/*.env redacted when present",
        "logs/** bounded and redacted tail copies when present"
      ]
    }
  end

  defp manifest_log_collection(log_collection) do
    Map.take(log_collection, [
      :bytes_retained,
      :files_available,
      :files_collected,
      :files_skipped,
      :max_log_bytes_per_file,
      :max_log_files,
      :max_total_log_bytes
    ])
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
    config_dir = Path.join(support_root, "config")

    copied =
      if real_directory?(config_dir) do
        collect_config_files!(stage_dir, config_dir)
      else
        0
      end

    if copied == 0 do
      write_text!(stage_dir, "config/README.txt", "No Orchard env config files were found.\n")
    end
  end

  defp config_paths(config_dir) do
    Enum.map(@config_files, fn file -> {Path.join(config_dir, file), file} end)
  end

  defp collect_config_files!(stage_dir, config_dir) do
    config_dir
    |> config_paths()
    |> Enum.reduce(0, fn config_path, count ->
      copy_config_file!(stage_dir, config_path, count)
    end)
  end

  defp copy_config_file!(stage_dir, {source_path, dest_name}, count) do
    case read_regular_file(source_path) do
      {:ok, contents} ->
        write_text!(stage_dir, Path.join("config", dest_name), contents)
        count + 1

      :error ->
        count
    end
  end

  defp redact_env_file(contents) do
    {lines, _state} =
      contents
      |> String.split("\n", trim: false)
      |> Enum.map_reduce(:clear, &redact_env_line/2)

    Enum.join(lines, "\n")
  end

  defp redact_env_line(line, :secret_block) do
    state = if Regex.match?(@secret_block_end_regex, line), do: :clear, else: :secret_block
    {"[redacted]", state}
  end

  defp redact_env_line(line, {:quote, quote}) do
    state = if contains_unescaped_quote?(line, quote), do: :clear, else: {:quote, quote}
    {"[redacted]", state}
  end

  defp redact_env_line(line, :clear) do
    case env_assignment(line) do
      {:assignment, prefix, key, value} ->
        if sensitive_env_key?(key) or sensitive_value?(value) do
          {"#{prefix}#{key}=[redacted]", env_secret_block_state(value)}
        else
          {line, :clear}
        end

      _other ->
        {line, :clear}
    end
  end

  defp env_assignment("#" <> rest) do
    case String.split(rest, "=", parts: 2) do
      [key, value] -> {:assignment, "#", key, value}
      _other -> :none
    end
  end

  defp env_assignment(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> {:assignment, "", key, value}
      _other -> :none
    end
  end

  defp env_secret_block_state(value) do
    if Regex.match?(@secret_block_begin_regex, value) and
         not Regex.match?(@secret_block_end_regex, value) do
      :secret_block
    else
      env_quoted_block_state(value)
    end
  end

  defp env_quoted_block_state(value) do
    value = String.trim_leading(value)

    cond do
      String.starts_with?(value, "\"") ->
        quoted_block_state(value, "\"")

      String.starts_with?(value, "'") ->
        quoted_block_state(value, "'")

      true ->
        :clear
    end
  end

  defp quoted_block_state(value, quote) do
    value
    |> String.slice(1..-1//1)
    |> contains_unescaped_quote?(quote)
    |> then(fn closed? -> if closed?, do: :clear, else: {:quote, quote} end)
  end

  defp contains_unescaped_quote?(value, "\""), do: Regex.match?(~r/(^|[^\\])"/, value)
  defp contains_unescaped_quote?(value, "'"), do: Regex.match?(~r/(^|[^\\])'/, value)

  defp sensitive_env_key?(key) do
    {parts, compact} = key_identity(key)

    cond do
      safe_diagnostic_key?(compact) -> false
      sensitive_key?(parts, compact) -> true
      bare_license_key?(compact) -> true
      sensitive_license_key?(parts) -> true
      true -> false
    end
  end

  defp sensitive_log_key?(key) do
    {parts, compact} = key_identity(key)

    cond do
      safe_diagnostic_key?(compact) -> false
      sensitive_key?(parts, compact) -> true
      bare_license_key?(compact) -> true
      sensitive_license_key?(parts) -> true
      sensitive_log_payload_key?(parts, compact) -> true
      true -> false
    end
  end

  defp sensitive_key?(parts, compact) do
    compact in @sensitive_key_compounds or
      Enum.any?(@sensitive_key_compounds, &String.contains?(compact, &1)) or
      compact in @sensitive_key_compact_aliases or
      Enum.any?(@sensitive_key_compact_fragments, &String.contains?(compact, &1)) or
      Enum.any?(@sensitive_key_parts, &(&1 in parts)) or
      token_secret_key?(parts, compact)
  end

  defp token_secret_key?(parts, compact) do
    compact == "token" or String.ends_with?(compact, "_token") or
      (Enum.any?(parts, &(&1 in ["token", "tokens"])) and
         Enum.any?(@sensitive_token_partners, &(&1 in parts)))
  end

  defp sensitive_license_key?(parts) do
    "license" in parts and Enum.any?(@sensitive_license_partners, &(&1 in parts))
  end

  defp bare_license_key?(compact), do: compact in @sensitive_bare_license_keys

  defp sensitive_log_payload_key?(parts, compact) do
    compact in @sensitive_log_payload_keys or
      sensitive_log_token_id_key?(parts, compact) or
      Enum.any?(["messages", "prompt"], &(&1 in parts)) or
      bracketed_payload_key?(parts) or
      List.last(parts) in ["content", "input"]
  end

  defp bracketed_payload_key?([root | rest]) when root in ["content", "input"] do
    Enum.any?(rest, &numeric_part?/1) or
      Enum.any?(rest, &(&1 in ["content", "input", "message", "text"]))
  end

  defp bracketed_payload_key?(_parts), do: false

  defp sensitive_log_token_id_key?(parts, compact) do
    parts
    |> compact_without_numeric_parts()
    |> then(&[compact, &1])
    |> Enum.uniq()
    |> Enum.any?(&sensitive_log_token_id_compact?/1)
  end

  defp compact_without_numeric_parts(parts) do
    parts
    |> Enum.reject(&numeric_part?/1)
    |> Enum.join("_")
  end

  defp sensitive_log_token_id_compact?(compact) do
    compact in ["input_ids", "token_ids"] or
      String.ends_with?(compact, "_input_ids") or
      String.ends_with?(compact, "_token_ids")
  end

  defp numeric_part?(part), do: String.match?(part, ~r/^\d+$/)

  defp safe_diagnostic_key?(compact), do: compact in @safe_diagnostic_keys

  defp key_identity(key) do
    normalized =
      key
      |> String.trim()
      |> String.trim_leading("#")
      |> String.trim()
      |> Macro.underscore()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    parts = String.split(normalized, "_", trim: true)

    {parts, normalized}
  end

  defp collect_logs!(stage_dir, support_root, max_log_bytes, runtime) do
    logs_root = Path.join(support_root, "logs")
    limits = log_collection_limits(runtime)

    {candidates, discovery_capped?} =
      log_file_candidates(logs_root, limits.max_discovery_entries, runtime)

    {selected, skipped_for_count} = select_log_candidates(candidates, limits.max_files)

    skipped_for_discovery =
      if discovery_capped?, do: [%{path: ".", reason: "discovery_limit"}], else: []

    {copied, bytes_retained, skipped, truncated} =
      collect_selected_logs!(
        stage_dir,
        selected,
        max_log_bytes,
        limits.max_total_bytes,
        Enum.reverse(skipped_for_discovery ++ skipped_for_count)
      )

    if copied == 0 do
      write_text!(stage_dir, "logs/README.txt", "No Orchard log files were found.\n")
    end

    %{
      bytes_retained: bytes_retained,
      discovery_capped: discovery_capped?,
      files_available: length(candidates),
      files_collected: copied,
      files_skipped: length(skipped),
      max_discovery_entries: limits.max_discovery_entries,
      max_log_bytes_per_file: max_log_bytes,
      max_log_files: limits.max_files,
      max_total_log_bytes: limits.max_total_bytes,
      skipped: Enum.reverse(skipped),
      truncated: Enum.reverse(truncated)
    }
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

  defp with_bundle_temp_root(output_dir, basename, runtime, fun) do
    temp_root = create_bundle_temp_root!(output_dir, basename, runtime)

    try do
      fun.(temp_root)
    after
      File.rm_rf(temp_root)
    end
  end

  defp create_bundle_temp_root!(output_dir, basename, runtime) do
    create_bundle_temp_root!(output_dir, basename, runtime, 0)
  end

  defp create_bundle_temp_root!(_output_dir, _basename, _runtime, @temp_dir_attempts) do
    raise "failed to create unique support bundle temporary directory"
  end

  defp create_bundle_temp_root!(output_dir, basename, runtime, attempt) do
    path = private_temp_root_path(output_dir, basename, runtime.path_nonce.())

    case File.mkdir(path) do
      :ok ->
        File.chmod!(path, 0o700)
        path

      {:error, :eexist} ->
        create_bundle_temp_root!(output_dir, basename, runtime, attempt + 1)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "make directory", path: path
    end
  end

  defp private_temp_root_path(output_dir, basename, path_nonce),
    do: Path.join(output_dir, ".#{basename}-#{path_nonce}.tmp")

  defp real_directory?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> true
      _other -> false
    end
  end

  defp log_file_candidates(root, max_discovery_entries, runtime) do
    if real_directory?(root) do
      {preferred, seen, remaining} = preferred_log_candidates(root, max_discovery_entries)
      {candidates, capped?} = find_log_file_candidates(root, seen, remaining, runtime)

      {preferred ++ candidates, capped?}
    else
      {[], false}
    end
  end

  defp preferred_log_candidates(root, max_discovery_entries) do
    @preferred_log_files
    |> Enum.reduce_while(
      {[], MapSet.new(), max_discovery_entries},
      &preferred_log_candidate_reducer(root, &1, &2)
    )
    |> then(fn {candidates, seen, remaining} -> {Enum.reverse(candidates), seen, remaining} end)
  end

  defp preferred_log_candidate_reducer(_root, _rel, {candidates, seen, remaining})
       when remaining <= 0 do
    {:halt, {candidates, seen, remaining}}
  end

  defp preferred_log_candidate_reducer(root, rel, {candidates, seen, remaining}) do
    path = Path.join(root, rel)
    seen = MapSet.put(seen, path)

    case File.lstat(path) do
      {:ok, %{type: :regular} = stat} ->
        {:cont, {[log_file_candidate(root, path, stat) | candidates], seen, remaining - 1}}

      _other ->
        {:cont, {candidates, seen, remaining}}
    end
  end

  defp find_log_file_candidates(root, seen, remaining, runtime) do
    case find_executable(runtime) do
      nil ->
        {[], false}

      executable ->
        port =
          Port.open(
            {:spawn_executable, executable},
            [:binary, :exit_status, args: [root, "-type", "f", "-print0"]]
          )

        collect_find_log_candidates(port, root, seen, max(remaining, 0), [], "")
    end
  end

  defp find_executable(runtime) do
    runtime
    |> Map.get(:find_executable, fn -> System.find_executable("find") end)
    |> then(& &1.())
  end

  defp collect_find_log_candidates(port, root, seen, remaining, candidates, buffer) do
    receive do
      {^port, {:data, data}} ->
        {paths, buffer} = find_output_paths(buffer <> data)

        case reduce_find_log_paths(paths, root, seen, remaining, candidates) do
          {:cont, seen, remaining, candidates} ->
            collect_find_log_candidates(port, root, seen, remaining, candidates, buffer)

          {:halt, candidates} ->
            close_find_port(port)
            {Enum.reverse(candidates), true}
        end

      {^port, {:exit_status, _status}} ->
        {candidates, _seen, _remaining, capped?} =
          reduce_final_find_buffer(buffer, root, seen, remaining, candidates)

        {Enum.reverse(candidates), capped?}
    end
  end

  defp find_output_paths(buffer) do
    parts = :binary.split(buffer, <<0>>, [:global])
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp reduce_final_find_buffer("", _root, seen, remaining, candidates) do
    {candidates, seen, remaining, false}
  end

  defp reduce_final_find_buffer(buffer, root, seen, remaining, candidates) do
    case reduce_find_log_paths([buffer], root, seen, remaining, candidates) do
      {:cont, seen, remaining, candidates} -> {candidates, seen, remaining, false}
      {:halt, candidates} -> {candidates, seen, remaining, true}
    end
  end

  defp reduce_find_log_paths([], _root, seen, remaining, candidates) do
    {:cont, seen, remaining, candidates}
  end

  defp reduce_find_log_paths([path | rest], root, seen, remaining, candidates) do
    cond do
      path == "" ->
        reduce_find_log_paths(rest, root, seen, remaining, candidates)

      MapSet.member?(seen, path) ->
        reduce_find_log_paths(rest, root, seen, remaining, candidates)

      remaining <= 0 ->
        {:halt, candidates}

      true ->
        seen = MapSet.put(seen, path)

        case regular_file_stat(path) do
          {:ok, stat} ->
            candidate = log_file_candidate(root, path, stat)
            reduce_find_log_paths(rest, root, seen, remaining - 1, [candidate | candidates])

          :error ->
            reduce_find_log_paths(rest, root, seen, remaining, candidates)
        end
    end
  end

  defp close_find_port(port) do
    if Port.info(port) != nil do
      Port.close(port)
    end

    :ok
  end

  defp log_file_candidate(root, path, stat) do
    rel = Path.relative_to(path, root)

    %{
      path: path,
      rel: rel,
      mtime_seconds: datetime_to_seconds(stat.mtime),
      preferred_index: preferred_log_index(rel)
    }
  end

  defp datetime_to_seconds(datetime), do: :calendar.datetime_to_gregorian_seconds(datetime)

  defp preferred_log_index(rel) do
    case Enum.find_index(@preferred_log_files, &(&1 == rel or &1 == Path.basename(rel))) do
      nil -> length(@preferred_log_files)
      index -> index
    end
  end

  defp select_log_candidates(candidates, max_files) do
    candidates
    |> Enum.sort_by(&log_candidate_sort_key/1)
    |> Enum.split(max_files)
    |> then(fn {selected, skipped} ->
      {selected, Enum.map(skipped, &log_skip(&1, "file_count_limit"))}
    end)
  end

  defp log_candidate_sort_key(candidate) do
    {candidate.preferred_index, -candidate.mtime_seconds, candidate.rel}
  end

  defp collect_selected_logs!(
         stage_dir,
         selected,
         max_log_bytes,
         max_total_log_bytes,
         skipped_for_count
       ) do
    Enum.reduce(selected, {0, 0, skipped_for_count, []}, fn candidate,
                                                            {copied, bytes_retained, skipped,
                                                             truncated} ->
      case allowed_log_read_bytes(max_log_bytes, bytes_retained, max_total_log_bytes) do
        :skip ->
          {copied, bytes_retained, [log_skip(candidate, "total_log_bytes_limit") | skipped],
           truncated}

        read_bytes ->
          copy_log_candidate!(
            stage_dir,
            candidate,
            read_bytes,
            copied,
            bytes_retained,
            skipped,
            truncated
          )
      end
    end)
  end

  defp allowed_log_read_bytes(0, _bytes_retained, _max_total_log_bytes), do: 0

  defp allowed_log_read_bytes(max_log_bytes, bytes_retained, max_total_log_bytes) do
    remaining = max_total_log_bytes - bytes_retained

    if remaining > 0 do
      min(max_log_bytes, remaining)
    else
      :skip
    end
  end

  defp copy_log_candidate!(
         stage_dir,
         candidate,
         read_bytes,
         copied,
         bytes_retained,
         skipped,
         truncated
       ) do
    dest = Path.join("logs", candidate.rel)

    case tail_file(candidate.path, read_bytes) do
      {:ok, content, info} ->
        write_text!(stage_dir, dest, redact_log_file(content))

        truncated =
          if info.truncated? do
            [log_truncated(candidate, info) | truncated]
          else
            truncated
          end

        {copied + 1, bytes_retained + info.retained_bytes, skipped, truncated}

      :error ->
        {copied, bytes_retained, [log_skip(candidate, "unavailable") | skipped], truncated}
    end
  end

  defp log_skip(candidate, reason), do: %{path: candidate.rel, reason: reason}

  defp log_truncated(candidate, info) do
    %{
      path: candidate.rel,
      original_bytes: info.original_bytes,
      retained_bytes: info.retained_bytes
    }
  end

  defp log_collection_limits(runtime) do
    limits =
      runtime
      |> Map.get(:log_collection_limits, fn -> %{} end)
      |> then(& &1.())

    %{
      max_discovery_entries:
        non_negative_limit(
          Map.get(limits, :max_discovery_entries),
          @default_max_log_discovery_entries
        ),
      max_files: non_negative_limit(Map.get(limits, :max_files), @default_max_log_files),
      max_total_bytes:
        non_negative_limit(Map.get(limits, :max_total_bytes), @default_max_total_log_bytes)
    }
  end

  defp non_negative_limit(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp non_negative_limit(_value, fallback), do: fallback

  defp read_regular_file(path) do
    with {:ok, first_stat} <- regular_file_stat(path),
         {:ok, contents} <- File.read(path),
         {:ok, second_stat} <- regular_file_stat(path),
         true <- same_file?(first_stat, second_stat) do
      {:ok, redact_env_file(contents)}
    else
      _other -> :error
    end
  end

  defp regular_file_stat(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular} = stat} -> {:ok, stat}
      _other -> :error
    end
  end

  defp same_file?(first_stat, second_stat) do
    first_stat.major_device == second_stat.major_device and
      first_stat.minor_device == second_stat.minor_device and
      first_stat.inode == second_stat.inode
  end

  defp tail_file(path, max_bytes) do
    with {:ok, first_stat} <- regular_file_stat(path),
         {:ok, {:ok, content}} <-
           File.open(path, [:read, :binary], fn file ->
             read_tail_content(file, first_stat.size, max_bytes)
           end),
         {:ok, second_stat} <- regular_file_stat(path),
         true <- same_file?(first_stat, second_stat) do
      {:ok, format_tail_content(content, first_stat.size, max_bytes),
       %{
         original_bytes: first_stat.size,
         retained_bytes: min(first_stat.size, max_bytes),
         truncated?: first_stat.size > max_bytes
       }}
    else
      _other -> :error
    end
  end

  defp read_tail_content(_file, _file_size, 0), do: {:ok, ""}

  defp read_tail_content(file, file_size, max_bytes) do
    offset = max(file_size - max_bytes, 0)

    with {:ok, _position} <- :file.position(file, offset) do
      case IO.binread(file, max_bytes) do
        :eof -> {:ok, ""}
        data when is_binary(data) -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp format_tail_content(content, file_size, max_bytes) do
    if file_size > max_bytes do
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
      {lines, _in_secret_block?} =
        content
        |> String.split("\n", trim: false)
        |> redact_log_lines(initial_secret_block_state?(content))

      Enum.join(lines, "\n")
    else
      "[redacted binary log content]\n"
    end
  end

  defp redact_log_lines([line | rest], true) do
    if truncated_log_marker?(line) do
      {redacted, in_secret_block?} = Enum.map_reduce(rest, true, &redact_log_line/2)
      {[line | redacted], in_secret_block?}
    else
      Enum.map_reduce([line | rest], true, &redact_log_line/2)
    end
  end

  defp redact_log_lines(lines, in_secret_block?) do
    Enum.map_reduce(lines, in_secret_block?, &redact_log_line/2)
  end

  defp initial_secret_block_state?(content) do
    case {first_regex_index(@secret_block_begin_regex, content),
          first_regex_index(@secret_block_end_regex, content)} do
      {nil, nil} -> false
      {nil, _end_index} -> true
      {begin_index, end_index} when is_integer(end_index) -> end_index < begin_index
      {_begin_index, nil} -> false
    end
  end

  defp first_regex_index(regex, content) do
    case Regex.run(regex, content, return: :index) do
      [{index, _length} | _rest] -> index
      nil -> nil
    end
  end

  defp truncated_log_marker?(line) do
    String.starts_with?(line, "[truncated to last ") and String.ends_with?(line, " bytes]")
  end

  defp redact_log_line("", false), do: {"", false}

  defp redact_log_line(line, true) do
    {"[redacted log line]", not Regex.match?(@secret_block_end_regex, line)}
  end

  defp redact_log_line(line, false) do
    in_secret_block? =
      Regex.match?(@secret_block_begin_regex, line) and
        not Regex.match?(@secret_block_end_regex, line)

    {redact_log_line(line), in_secret_block?}
  end

  defp redact_log_line(""), do: ""

  defp redact_log_line(line) do
    if redact_log_line?(line), do: "[redacted log line]", else: line
  end

  defp redact_log_line?(line) do
    sensitive_log_literal?(line) or
      Regex.match?(@credential_token_assignment_regex, line) or
      Regex.match?(@license_secret_assignment_regex, line) or
      sensitive_value?(line)
  end

  defp sensitive_log_literal?(line) do
    line
    |> log_line_forms()
    |> Enum.map(&String.downcase/1)
    |> Enum.any?(fn normalized ->
      Enum.any?(@sensitive_log_literals, &String.contains?(normalized, &1))
    end)
  end

  defp sensitive_value?(value) do
    value_secret? =
      value
      |> log_line_forms()
      |> Enum.any?(fn form ->
        Regex.match?(@bearer_value_regex, form) or
          Regex.match?(@credential_url_userinfo_regex, form) or
          Regex.match?(@secret_block_regex, form)
      end)

    value_secret? or sensitive_log_assignment?(value)
  end

  defp sensitive_log_assignment?(line) do
    line
    |> log_line_forms()
    |> Enum.any?(&sensitive_log_assignment_in_form?/1)
  end

  defp sensitive_log_assignment_in_form?(line) do
    line
    |> then(&Regex.scan(@assignment_key_regex, &1, capture: :all_but_first))
    |> Enum.any?(fn [key] -> sensitive_log_key?(key) end)
  end

  defp log_line_forms(line) do
    unescaped = Regex.replace(~r/\\+(["'])/, line, fn _match, quote -> quote end)

    if unescaped == line, do: [line], else: [line, unescaped]
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

  defp finalize_archive(temp_archive_path, output_dir, basename) do
    finalize_archive(temp_archive_path, output_dir, basename, 0)
  end

  defp finalize_archive(_temp_archive_path, _output_dir, _basename, @archive_finalize_attempts) do
    {:error, "Error: failed to move support bundle: no available archive name"}
  end

  defp finalize_archive(temp_archive_path, output_dir, basename, attempt) do
    bundle_name = if attempt == 0, do: basename, else: "#{basename}-#{attempt}"
    archive_path = Path.join(output_dir, bundle_name <> ".tar.gz")

    case File.ln(temp_archive_path, archive_path) do
      :ok ->
        {:ok, archive_path}

      {:error, :eexist} ->
        finalize_archive(temp_archive_path, output_dir, basename, attempt + 1)

      {:error, reason} ->
        {:error, "Error: failed to move support bundle: #{:file.format_error(reason)}"}
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
      find_executable: fn -> System.find_executable("find") end,
      list_nodes: &Orchard.Nodes.list_nodes/0,
      list_recent_requests: &Orchard.Requests.list_recent_requests/1,
      log_collection_limits: fn ->
        %{max_files: @default_max_log_files, max_total_bytes: @default_max_total_log_bytes}
      end,
      nodes_summary: &Orchard.Nodes.summary/0,
      now: fn -> DateTime.utc_now() |> DateTime.truncate(:second) end,
      path_nonce: fn -> :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false) end,
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
      --max-log-bytes BYTES  Include at most BYTES from each collected log file.
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
    - logs are bounded by per-file, file-count, and aggregate tail-copy caps.
    - collected log lines containing common sensitive markers are redacted.
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp usage_error(message, usage), do: {:error, "#{message}\n\n#{usage}", @usage_exit_code}
  defp option?(arg), do: String.starts_with?(arg, "-")
end
