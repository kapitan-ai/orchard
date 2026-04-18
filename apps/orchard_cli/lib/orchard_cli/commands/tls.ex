defmodule OrchardCLI.Commands.TLS do
  @moduledoc """
  CLI handler for `orchardctl tls` commands.

  Supports:
    orchardctl tls init [options]     — Generate local CA + server certificates
    orchardctl tls trust-ca [options] — Trust the CA in macOS System Keychain
  """

  @default_support_root "/Library/Application Support/Orchard"
  @default_ca_days 3650
  @default_server_days 825
  @ca_key_bits 4096
  @server_key_bits 2048

  # ── Public API ──────────────────────────────────────────────────────

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  @doc false
  @spec run([String.t()], map()) :: OrchardCLI.command_result()
  def run(args, runtime) do
    case args do
      ["init" | rest] -> run_init(rest, runtime)
      ["trust-ca" | rest] -> run_trust_ca(rest, runtime)
      ["help"] -> {:ok, group_usage()}
      ["--help"] -> {:ok, group_usage()}
      [] -> {:error, group_usage(), 1}
      _ -> {:error, group_usage(), 1}
    end
  end

  # ── Init Subcommand ─────────────────────────────────────────────────

  defp run_init(args, runtime) do
    with {:ok, opts} <- parse_init_opts(args),
         {:ok, config} <- build_init_config(opts, runtime),
         {:ok, _} <- check_openssl(runtime) do
      locked_execute(config.output_dir, fn -> do_init(config, runtime) end)
    else
      {:help} -> {:ok, init_usage()}
      {:error, _, _} = err -> err
    end
  end

  defp parse_init_opts(args) do
    switches = [
      output_dir: :string,
      common_name: :string,
      host: :keep,
      ip: :keep,
      ca_days: :integer,
      server_days: :integer,
      force: :boolean,
      no_trust: :boolean,
      help: :boolean
    ]

    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        if Keyword.get(parsed, :help, false) do
          {:help}
        else
          {:ok, parsed}
        end

      {_parsed, positional, []} ->
        {:error,
         "Error: unexpected argument(s): #{Enum.join(positional, ", ")}\n\n#{init_usage()}", 1}

      {_parsed, _positional, invalid} ->
        invalid_str = Enum.map_join(invalid, ", ", fn {flag, _} -> flag end)
        {:error, "Error: unknown option(s): #{invalid_str}\n\n#{init_usage()}", 1}
    end
  end

  defp build_init_config(opts, runtime) do
    output_dir = resolve_output_dir(opts)
    hostname = discover_hostname(runtime)
    common_name = Keyword.get(opts, :common_name, hostname)
    extra_hosts = Keyword.get_values(opts, :host)
    extra_ips_raw = Keyword.get_values(opts, :ip)
    server_days = Keyword.get(opts, :server_days, @default_server_days)
    ca_days_opt = Keyword.get(opts, :ca_days)

    with :ok <- validate_common_name(common_name),
         :ok <- validate_hosts(extra_hosts),
         :ok <- validate_ips(extra_ips_raw),
         :ok <- validate_positive(:server_days, server_days),
         :ok <- validate_positive_or_nil(:ca_days, ca_days_opt) do
      extra_ips = Enum.map(extra_ips_raw, &canonicalize_ip/1)
      lan_ips = discover_lan_ips(runtime)
      {san_dns, san_ip} = build_san_lists(hostname, common_name, extra_hosts, lan_ips, extra_ips)

      {:ok,
       %{
         output_dir: output_dir,
         common_name: common_name,
         hostname: hostname,
         san_dns: san_dns,
         san_ip: san_ip,
         ca_days_opt: ca_days_opt,
         server_days: server_days,
         force?: Keyword.get(opts, :force, false),
         no_trust?: Keyword.get(opts, :no_trust, false)
       }}
    end
  end

  defp do_init(config, runtime) do
    state = current_tls_state(config.output_dir)

    with :ok <- check_state_consistency(state, config.force?),
         :ok <- check_ca_days_reuse(state.ca_exists?, config.force?, config.ca_days_opt),
         {:ok, reuse_ca?, ca_days} <-
           ca_generation_plan(state.ca_exists?, config.force?, config.ca_days_opt),
         :ok <-
           check_days_against_ca(
             reuse_ca?,
             state.ca_crt_path,
             ca_days,
             config.server_days,
             runtime
           ),
         :ok <- maybe_remove_existing_trust(config, state, runtime),
         {:ok, summary_data} <- generate_and_publish(config, reuse_ca?, ca_days, runtime) do
      trust_result = maybe_trust_ca(config, summary_data.ca_crt_path, runtime)
      {:ok, format_init_summary(summary_data, trust_result)}
    end
  end

  defp current_tls_state(output_dir) do
    ca_key_path = Path.join(output_dir, "ca.key")
    ca_crt_path = Path.join(output_dir, "ca.crt")
    server_key_path = Path.join(output_dir, "controller.key")
    server_crt_path = Path.join(output_dir, "controller.crt")

    ca_key_exists? = File.regular?(ca_key_path)
    ca_crt_exists? = File.regular?(ca_crt_path)

    %{
      ca_crt_path: ca_crt_path,
      ca_exists?: ca_key_exists? and ca_crt_exists?,
      ca_partial?: ca_key_exists? != ca_crt_exists?,
      server_exists?: File.regular?(server_key_path) or File.regular?(server_crt_path)
    }
  end

  defp check_state_consistency(%{ca_partial?: true}, false) do
    {:error,
     "Error: inconsistent CA state (only one of ca.key/ca.crt exists).\nUse --force to regenerate.",
     1}
  end

  defp check_state_consistency(%{server_exists?: true, ca_exists?: false}, false) do
    {:error,
     "Error: existing server certificate files found without an Orchard CA.\n" <>
       "These may be externally managed. Use --force to overwrite.", 1}
  end

  defp check_state_consistency(%{ca_exists?: true, server_exists?: true}, false) do
    {:error, "Error: certificates already exist. Use --force to regenerate.", 1}
  end

  defp check_state_consistency(_state, _force?), do: :ok

  defp ca_generation_plan(ca_exists?, force?, ca_days_opt) do
    reuse_ca? = ca_exists? and not force?
    ca_days = if reuse_ca?, do: nil, else: ca_days_opt || @default_ca_days
    {:ok, reuse_ca?, ca_days}
  end

  defp maybe_remove_existing_trust(%{no_trust?: true}, _state, _runtime), do: :ok
  defp maybe_remove_existing_trust(%{force?: false}, _state, _runtime), do: :ok
  defp maybe_remove_existing_trust(_config, %{ca_exists?: false}, _runtime), do: :ok

  defp maybe_remove_existing_trust(_config, %{ca_crt_path: ca_crt_path}, runtime) do
    maybe_remove_old_ca(ca_crt_path, runtime)
  end

  defp check_ca_days_reuse(ca_exists?, force?, ca_days_opt) do
    reuse_ca? = ca_exists? and not force?

    if reuse_ca? and ca_days_opt != nil do
      {:error,
       "Error: --ca-days cannot be used when reusing existing CA.\nUse --force to regenerate the CA.",
       1}
    else
      :ok
    end
  end

  # Deliberately validates against the certificate's actual notAfter field rather
  # than the originally-requested CA days — time may have elapsed since the CA
  # was generated, and the cert could have been created with non-default days.
  defp check_days_against_ca(true = _reuse_ca?, ca_crt_path, _ca_days, server_days, runtime) do
    with {:ok, ca_not_after} <- parse_cert_not_after(ca_crt_path) do
      now = runtime.now_utc.()
      intended_expiry = DateTime.add(now, server_days * 86_400, :second)
      ca_expiry = DateTime.from_naive!(ca_not_after, "Etc/UTC")

      if DateTime.compare(intended_expiry, ca_expiry) == :gt do
        ca_remaining = DateTime.diff(ca_expiry, now, :day)

        {:error,
         "Error: server cert validity (#{server_days} days) would exceed CA expiry " <>
           "(#{NaiveDateTime.to_iso8601(ca_not_after)}Z, #{ca_remaining} days remaining).\n" <>
           "Use --force to regenerate a new CA with a longer validity.", 1}
      else
        :ok
      end
    end
  end

  defp check_days_against_ca(false = _reuse_ca?, _ca_crt_path, ca_days, server_days, _runtime) do
    if server_days > ca_days do
      {:error, "Error: --server-days (#{server_days}) exceeds --ca-days (#{ca_days}).", 1}
    else
      :ok
    end
  end

  # ── Trust-CA Subcommand ─────────────────────────────────────────────

  defp run_trust_ca(args, runtime) do
    case parse_trust_ca_opts(args) do
      {:help} ->
        {:ok, trust_ca_usage()}

      {:error, _, _} = err ->
        err

      {:ok, opts} ->
        output_dir = resolve_output_dir(opts)
        locked_execute(output_dir, fn -> do_trust_ca(output_dir, runtime) end)
    end
  end

  defp parse_trust_ca_opts(args) do
    switches = [output_dir: :string, help: :boolean]

    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        if Keyword.get(parsed, :help, false), do: {:help}, else: {:ok, parsed}

      {_parsed, positional, []} ->
        {:error,
         "Error: unexpected argument(s): #{Enum.join(positional, ", ")}\n\n#{trust_ca_usage()}",
         1}

      {_parsed, _positional, invalid} ->
        invalid_str = Enum.map_join(invalid, ", ", fn {flag, _} -> flag end)
        {:error, "Error: unknown option(s): #{invalid_str}\n\n#{trust_ca_usage()}", 1}
    end
  end

  defp do_trust_ca(output_dir, runtime) do
    ca_crt_path = Path.join(output_dir, "ca.crt")
    meta_path = Path.join(output_dir, ".orchard-tls-meta.json")

    with :ok <- check_ca_file(ca_crt_path),
         :ok <- check_metadata_source(meta_path),
         :ok <- check_can_trust(runtime) do
      trust_ca_in_keychain(ca_crt_path, runtime)
      |> format_trust_ca_result(ca_crt_path)
    end
  end

  defp format_trust_ca_result(:ok, ca_crt_path) do
    case compute_fingerprint(ca_crt_path) do
      {:ok, fingerprint} -> {:ok, format_trust_summary(ca_crt_path, fingerprint)}
      {:error, _, _} = err -> err
    end
  end

  defp format_trust_ca_result({:error, message}, _ca_crt_path) do
    {:error, "Error: failed to trust CA certificate.\n#{message}", 1}
  end

  defp check_ca_file(ca_crt_path) do
    if File.regular?(ca_crt_path) do
      :ok
    else
      {:error, "Error: CA certificate not found: #{ca_crt_path}\nRun: orchardctl tls init", 1}
    end
  end

  # Missing metadata is an allowed recovery path (the operator may have
  # manually placed a CA file).  Present-but-corrupt metadata indicates
  # tampering or filesystem corruption and must not silently pass.
  defp check_metadata_source(meta_path) do
    case File.read(meta_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"source" => "generated_local_ca"}} ->
            :ok

          {:ok, _} ->
            {:error, "Error: CA was not generated by Orchard (unsupported source type).", 1}

          {:error, _} ->
            {:error, "Error: metadata file is corrupt: #{meta_path}", 1}
        end

      {:error, :enoent} ->
        # Missing metadata is acceptable — allow trust for recovery
        :ok

      {:error, reason} ->
        {:error, "Error: cannot read metadata file #{meta_path}: #{inspect(reason)}", 1}
    end
  end

  defp check_can_trust(runtime) do
    {os_family, _} = runtime.os_type.()

    cond do
      os_family != :unix ->
        {:error, "Error: CA trust is only supported on macOS.", 1}

      not macos?(runtime) ->
        {:error, "Error: CA trust is only supported on macOS.", 1}

      runtime.uid.() != 0 ->
        {:error,
         "Error: root privileges required to trust CA.\nRun: sudo orchardctl tls trust-ca", 1}

      true ->
        :ok
    end
  end

  # ── SAN Discovery ───────────────────────────────────────────────────

  defp discover_hostname(runtime) do
    case runtime.hostname.() do
      {:ok, hostname} -> to_string(hostname)
      _ -> "localhost"
    end
  end

  defp discover_lan_ips(runtime) do
    case runtime.ifaddrs.() do
      {:ok, ifaddrs} -> Enum.flat_map(ifaddrs, &interface_lan_ips/1)
      _ -> []
    end
  end

  defp interface_lan_ips({_name, opts}) do
    if active_non_loopback_interface?(Keyword.get(opts, :flags, [])) do
      opts
      |> Keyword.get_values(:addr)
      |> Enum.filter(&ipv4_addr?/1)
      |> Enum.reject(&excluded_lan_ip?/1)
      |> Enum.map(&ip_to_string/1)
    else
      []
    end
  end

  defp active_non_loopback_interface?(flags), do: :up in flags and :loopback not in flags
  defp ipv4_addr?({_, _, _, _}), do: true
  defp ipv4_addr?(_), do: false
  defp excluded_lan_ip?({0, 0, 0, 0}), do: true
  defp excluded_lan_ip?({127, _, _, _}), do: true
  defp excluded_lan_ip?(_), do: false
  defp ip_to_string(ip), do: ip |> :inet.ntoa() |> to_string()

  defp build_san_lists(hostname, common_name, extra_hosts, lan_ips, extra_ips) do
    dns_list =
      (["localhost", hostname, common_name] ++ extra_hosts)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    ip_list =
      (["127.0.0.1"] ++ lan_ips ++ extra_ips)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    {dns_list, ip_list}
  end

  # ── Certificate Generation ─────────────────────────────────────────

  defp generate_and_publish(config, reuse_ca?, ca_days, runtime) do
    %{
      output_dir: output_dir,
      common_name: common_name,
      hostname: hostname,
      san_dns: san_dns,
      san_ip: san_ip,
      server_days: server_days
    } = config

    staging_dir = create_staging_dir(output_dir)

    try do
      ca_key = Path.join(staging_dir, "ca.key")
      ca_crt = Path.join(staging_dir, "ca.crt")

      if reuse_ca? do
        File.cp!(Path.join(output_dir, "ca.key"), ca_key)
        File.cp!(Path.join(output_dir, "ca.crt"), ca_crt)
      else
        case generate_ca(staging_dir, ca_days, runtime) do
          :ok -> :ok
          {:error, _, _} = err -> throw(err)
        end
      end

      :ok = generate_server_cert(staging_dir, common_name, san_dns, san_ip, server_days, runtime)

      case verify_chain(staging_dir, runtime) do
        :ok -> :ok
        {:error, _, _} = err -> throw(err)
      end

      with {:ok, ca_fingerprint} <- compute_fingerprint(ca_crt),
           {:ok, server_fingerprint} <-
             compute_fingerprint(Path.join(staging_dir, "controller.crt")),
           {:ok, ca_not_after} <- parse_cert_not_after(ca_crt),
           {:ok, server_not_after} <-
             parse_cert_not_after(Path.join(staging_dir, "controller.crt")) do
        now = runtime.now_utc.()

        metadata = %{
          "source" => "generated_local_ca",
          "ca_fingerprint_sha256" => ca_fingerprint,
          "server_fingerprint_sha256" => server_fingerprint,
          "ca_not_after" => format_iso8601(ca_not_after),
          "server_not_after" => format_iso8601(server_not_after),
          "generated_at" => DateTime.to_iso8601(now),
          "hostname" => hostname,
          "san_dns" => san_dns,
          "san_ip" => san_ip
        }

        meta_path = Path.join(staging_dir, ".orchard-tls-meta.json")
        File.write!(meta_path, Jason.encode!(metadata, pretty: true))

        File.chmod!(Path.join(staging_dir, "ca.key"), 0o600)
        File.chmod!(Path.join(staging_dir, "ca.crt"), 0o644)
        File.chmod!(Path.join(staging_dir, "controller.key"), 0o600)
        File.chmod!(Path.join(staging_dir, "controller.crt"), 0o644)
        File.chmod!(meta_path, 0o644)

        files = ["ca.key", "ca.crt", "controller.key", "controller.crt", ".orchard-tls-meta.json"]

        for file <- files do
          src = Path.join(staging_dir, file)
          dst = Path.join(output_dir, file)
          File.rename!(src, dst)
        end

        {:ok,
         %{
           output_dir: output_dir,
           ca_crt_path: Path.join(output_dir, "ca.crt"),
           ca_fingerprint: ca_fingerprint,
           server_fingerprint: server_fingerprint,
           ca_not_after: ca_not_after,
           server_not_after: server_not_after,
           common_name: common_name,
           san_dns: san_dns,
           san_ip: san_ip,
           reused_ca?: reuse_ca?
         }}
      else
        {:error, _, _} = err -> throw(err)
      end
    catch
      {:error, _, _} = err -> err
    after
      cleanup_staging(staging_dir)
    end
  end

  defp generate_ca(staging_dir, ca_days, runtime) do
    ca_key = Path.join(staging_dir, "ca.key")
    ca_crt = Path.join(staging_dir, "ca.crt")
    ca_cnf = Path.join(staging_dir, "ca.cnf")

    # Write CA config
    File.write!(ca_cnf, """
    [req]
    distinguished_name = dn
    prompt = no
    x509_extensions = v3_ca

    [dn]
    CN = Orchard Local CA

    [v3_ca]
    basicConstraints = critical,CA:TRUE
    keyUsage = critical,keyCertSign,cRLSign
    subjectKeyIdentifier = hash
    """)

    # Generate CA private key
    case runtime.cmd.("openssl", ["genrsa", "-out", ca_key, to_string(@ca_key_bits)],
           cd: staging_dir
         ) do
      {:ok, _} ->
        :ok

      {:error, _status, output} ->
        throw({:error, "Error: failed to generate CA private key.\n#{String.trim(output)}", 1})
    end

    # Generate self-signed CA cert
    case runtime.cmd.(
           "openssl",
           [
             "req",
             "-new",
             "-x509",
             "-key",
             ca_key,
             "-out",
             ca_crt,
             "-days",
             to_string(ca_days),
             "-config",
             ca_cnf
           ],
           cd: staging_dir
         ) do
      {:ok, _} ->
        :ok

      {:error, _status, output} ->
        throw({:error, "Error: failed to generate CA certificate.\n#{String.trim(output)}", 1})
    end
  end

  defp generate_server_cert(staging_dir, common_name, san_dns, san_ip, server_days, runtime) do
    server_key = Path.join(staging_dir, "controller.key")
    server_csr = Path.join(staging_dir, "controller.csr")
    server_crt = Path.join(staging_dir, "controller.crt")
    ca_key = Path.join(staging_dir, "ca.key")
    ca_crt = Path.join(staging_dir, "ca.crt")
    ext_cnf = Path.join(staging_dir, "server_ext.cnf")

    # Write server extensions config with SAN
    san_entries =
      (san_dns |> Enum.with_index(1) |> Enum.map(fn {dns, i} -> "DNS.#{i} = #{dns}" end)) ++
        (san_ip |> Enum.with_index(1) |> Enum.map(fn {ip, i} -> "IP.#{i} = #{ip}" end))

    File.write!(ext_cnf, """
    basicConstraints = CA:FALSE
    keyUsage = critical,digitalSignature,keyEncipherment
    extendedKeyUsage = serverAuth
    subjectAltName = @alt_names
    subjectKeyIdentifier = hash
    authorityKeyIdentifier = keyid,issuer

    [alt_names]
    #{Enum.join(san_entries, "\n")}
    """)

    # Generate server private key
    case runtime.cmd.("openssl", ["genrsa", "-out", server_key, to_string(@server_key_bits)],
           cd: staging_dir
         ) do
      {:ok, _} ->
        :ok

      {:error, _status, output} ->
        throw(
          {:error, "Error: failed to generate server private key.\n#{String.trim(output)}", 1}
        )
    end

    # Generate CSR
    case runtime.cmd.(
           "openssl",
           [
             "req",
             "-new",
             "-key",
             server_key,
             "-out",
             server_csr,
             "-subj",
             "/CN=#{common_name}"
           ],
           cd: staging_dir
         ) do
      {:ok, _} ->
        :ok

      {:error, _status, output} ->
        throw(
          {:error,
           "Error: failed to generate certificate signing request.\n#{String.trim(output)}", 1}
        )
    end

    # Generate random serial
    serial_hex = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    # Sign server cert with CA
    case runtime.cmd.(
           "openssl",
           [
             "x509",
             "-req",
             "-in",
             server_csr,
             "-CA",
             ca_crt,
             "-CAkey",
             ca_key,
             "-out",
             server_crt,
             "-days",
             to_string(server_days),
             "-extfile",
             ext_cnf,
             "-set_serial",
             "0x#{serial_hex}"
           ],
           cd: staging_dir
         ) do
      {:ok, _} ->
        :ok

      {:error, _status, output} ->
        throw({:error, "Error: failed to sign server certificate.\n#{String.trim(output)}", 1})
    end
  end

  defp verify_chain(staging_dir, runtime) do
    ca_crt = Path.join(staging_dir, "ca.crt")
    server_crt = Path.join(staging_dir, "controller.crt")

    case runtime.cmd.("openssl", ["verify", "-CAfile", ca_crt, server_crt], cd: staging_dir) do
      {:ok, _} ->
        :ok

      {:error, _status, output} ->
        {:error, "Error: certificate chain verification failed.\n#{String.trim(output)}", 1}
    end
  end

  # ── X.509 Utilities ─────────────────────────────────────────────────

  defp compute_fingerprint(pem_path) do
    case read_certificate_der(pem_path) do
      {:ok, der} -> {:ok, format_fingerprint_hex(:crypto.hash(:sha256, der))}
      {:error, _, _} = err -> err
    end
  end

  defp parse_cert_not_after(pem_path) do
    case read_certificate_der(pem_path) do
      {:ok, der} ->
        otp_cert = :public_key.pkix_decode_cert(der, :otp)

        tbs = elem(otp_cert, 1)
        validity = elem(tbs, 5)
        not_after_raw = elem(validity, 2)
        {:ok, parse_cert_time(not_after_raw)}

      {:error, _, _} = err ->
        err
    end
  end

  defp read_certificate_der(pem_path) do
    pem_path
    |> File.read!()
    |> :public_key.pem_decode()
    |> Enum.find(fn
      {:Certificate, _, :not_encrypted} -> true
      _ -> false
    end)
    |> case do
      {:Certificate, der, :not_encrypted} when is_binary(der) -> {:ok, der}
      _other -> invalid_tls_contents_error(pem_path)
    end
  end

  defp invalid_tls_contents_error(pem_path) do
    {:error,
     "Error: encountered invalid TLS file contents.\nNo certificate PEM block found in #{pem_path}",
     1}
  end

  defp parse_cert_time({:utcTime, time_chars}) do
    time_str = List.to_string(time_chars)

    <<yy::binary-2, mm::binary-2, dd::binary-2, hh::binary-2, min::binary-2, ss::binary-2, "Z">> =
      time_str

    year = String.to_integer(yy)
    year = if year >= 50, do: 1900 + year, else: 2000 + year

    NaiveDateTime.new!(
      year,
      String.to_integer(mm),
      String.to_integer(dd),
      String.to_integer(hh),
      String.to_integer(min),
      String.to_integer(ss)
    )
  end

  defp parse_cert_time({:generalTime, time_chars}) do
    time_str = List.to_string(time_chars)

    <<yyyy::binary-4, mm::binary-2, dd::binary-2, hh::binary-2, min::binary-2, ss::binary-2, "Z">> =
      time_str

    NaiveDateTime.new!(
      String.to_integer(yyyy),
      String.to_integer(mm),
      String.to_integer(dd),
      String.to_integer(hh),
      String.to_integer(min),
      String.to_integer(ss)
    )
  end

  defp format_fingerprint_hex(hash_bytes) do
    hash_bytes
    |> Base.encode16()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
  end

  defp format_iso8601(naive_dt) do
    NaiveDateTime.to_iso8601(naive_dt) <> "Z"
  end

  # ── File Management ─────────────────────────────────────────────────

  # TLS commands must always return command_result — filesystem errors and cert
  # parsing failures (e.g. corrupt PEM) are rescued here rather than crashing
  # the CLI with a stacktrace.  Lock cleanup stays in `after` for all paths.
  defp locked_execute(output_dir, fun) do
    lock_path = Path.join(Path.dirname(output_dir), ".tls.lock")

    # Ensure parent directory exists for the lock
    File.mkdir_p!(Path.dirname(lock_path))

    case File.mkdir(lock_path) do
      :ok ->
        try do
          fun.()
        rescue
          e in File.Error ->
            {:error, "Error: filesystem error during TLS operation.\n#{Exception.message(e)}", 1}

          e in [MatchError, FunctionClauseError] ->
            {:error, "Error: encountered invalid TLS file contents.\n#{Exception.message(e)}", 1}
        after
          File.rmdir(lock_path)
        end

      {:error, :eexist} ->
        {:error,
         "Error: TLS operation already in progress.\n" <>
           "If no other tls command is running, remove the lock directory:\n  #{lock_path}", 1}

      {:error, reason} ->
        {:error, "Error: failed to acquire TLS lock at #{lock_path}: #{inspect(reason)}", 1}
    end
  end

  # Staging dir is created *within* output_dir so that File.rename!/2 is a
  # same-filesystem rename (atomic on POSIX).  Moving the staging dir outside
  # output_dir would break this atomicity guarantee.
  defp create_staging_dir(output_dir) do
    File.mkdir_p!(output_dir)
    File.chmod!(output_dir, 0o750)
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    staging_dir = Path.join(output_dir, ".staging-#{suffix}")
    File.mkdir_p!(staging_dir)
    File.chmod!(staging_dir, 0o700)
    staging_dir
  end

  defp cleanup_staging(staging_dir) do
    File.rm_rf(staging_dir)
  end

  defp resolve_output_dir(opts) do
    case Keyword.get(opts, :output_dir) do
      nil ->
        support_root = System.get_env("ORCHARD_SUPPORT_ROOT") || @default_support_root
        Path.join([support_root, "config", "tls"])

      dir ->
        Path.expand(dir)
    end
  end

  # ── Keychain Trust ──────────────────────────────────────────────────

  defp maybe_trust_ca(config, ca_crt_path, runtime) do
    case trust_ca_strategy(config, runtime) do
      {:skip, reason} ->
        {:skipped, reason}

      :trust ->
        case trust_ca_in_keychain(ca_crt_path, runtime) do
          :ok -> :trusted
          {:error, _} = err -> err
        end
    end
  end

  defp trust_ca_strategy(%{no_trust?: true}, _runtime), do: {:skip, :no_trust_flag}

  defp trust_ca_strategy(_config, runtime) do
    {os_family, _} = runtime.os_type.()

    cond do
      os_family != :unix or not macos?(runtime) -> {:skip, :not_macos}
      runtime.uid.() != 0 -> {:skip, :not_root}
      true -> :trust
    end
  end

  defp maybe_remove_old_ca(ca_crt_path, runtime) do
    {os_family, _} = runtime.os_type.()

    if os_family == :unix and macos?(runtime) and runtime.uid.() == 0 do
      # Best-effort removal — ignore errors
      runtime.cmd.("security", ["remove-trusted-cert", "-d", ca_crt_path], [])
    end

    :ok
  end

  defp trust_ca_in_keychain(ca_crt_path, runtime) do
    # Best-effort remove existing first
    runtime.cmd.("security", ["remove-trusted-cert", "-d", ca_crt_path], [])

    case runtime.cmd.(
           "security",
           [
             "add-trusted-cert",
             "-d",
             "-r",
             "trustRoot",
             "-k",
             "/Library/Keychains/System.keychain",
             ca_crt_path
           ],
           []
         ) do
      {:ok, _} -> :ok
      {:error, _status, output} -> {:error, String.trim(output)}
    end
  end

  defp macos?(runtime) do
    case runtime.os_type.() do
      {:unix, :darwin} -> true
      _ -> false
    end
  end

  # ── Validation Helpers ──────────────────────────────────────────────

  # --common-name is embedded into OpenSSL `-subj "/CN=..."` and added to the
  # SAN DNS list, so it requires stricter validation than bare SAN host entries:
  # '/' is the X.501 distinguished-name field separator, and null bytes can
  # truncate strings in C-based OpenSSL internals.
  defp validate_common_name(cn) do
    trimmed = String.trim(cn)

    cond do
      trimmed == "" ->
        {:error, "Error: --common-name must not be empty.", 1}

      String.contains?(trimmed, [" ", "\t", ",", "\n", "\r"]) ->
        {:error, "Error: --common-name must not contain whitespace or commas: #{inspect(cn)}", 1}

      String.contains?(trimmed, "/") ->
        {:error, "Error: --common-name must not contain '/' (X.501 separator): #{inspect(cn)}", 1}

      String.contains?(trimmed, "\0") ->
        {:error, "Error: --common-name must not contain null bytes: #{inspect(cn)}", 1}

      ip_literal?(trimmed) ->
        {:error, "Error: --common-name must not be an IP address (use --ip instead): #{cn}", 1}

      true ->
        :ok
    end
  end

  defp validate_hosts(hosts) do
    Enum.reduce_while(hosts, :ok, fn host, :ok ->
      trimmed = String.trim(host)

      cond do
        trimmed == "" ->
          {:halt, {:error, "Error: --host value must not be empty.", 1}}

        String.contains?(trimmed, [" ", "\t", ",", "\n", "\r"]) ->
          {:halt,
           {:error, "Error: --host value must not contain whitespace or commas: #{inspect(host)}",
            1}}

        ip_literal?(trimmed) ->
          {:halt,
           {:error, "Error: --host value must not be an IP address (use --ip instead): #{host}",
            1}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_ips(ips) do
    Enum.reduce_while(ips, :ok, fn ip, :ok ->
      case :inet.parse_address(String.to_charlist(ip)) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} -> {:halt, {:error, "Error: invalid IP address for --ip: #{ip}", 1}}
      end
    end)
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive(name, value) do
    {:error,
     "Error: --#{name |> to_string() |> String.replace("_", "-")} must be a positive integer, got: #{value}",
     1}
  end

  defp validate_positive_or_nil(_name, nil), do: :ok
  defp validate_positive_or_nil(name, value), do: validate_positive(name, value)

  defp canonicalize_ip(ip_string) do
    {:ok, ip_tuple} = :inet.parse_address(String.to_charlist(ip_string))
    :inet.ntoa(ip_tuple) |> to_string()
  end

  defp ip_literal?(string) do
    case :inet.parse_address(String.to_charlist(string)) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp check_openssl(runtime) do
    case runtime.cmd.("openssl", ["version"], []) do
      {:ok, _} -> {:ok, :available}
      {:error, _, _} -> {:error, "Error: openssl is required but not found in PATH.", 1}
    end
  end

  # ── Output Formatting ──────────────────────────────────────────────

  defp format_init_summary(data, trust_result) do
    trust_line =
      case trust_result do
        :trusted ->
          "  CA trust:      ✅ Trusted in macOS System Keychain"

        {:skipped, :no_trust_flag} ->
          "  CA trust:      ⚠️  Skipped (--no-trust)\n" <>
            "                 Run: sudo orchardctl tls trust-ca"

        {:skipped, :not_root} ->
          "  CA trust:      ⚠️  Skipped (not running as root)\n" <>
            "                 Run: sudo orchardctl tls trust-ca"

        {:skipped, :not_macos} ->
          "  CA trust:      ⚠️  Skipped (not macOS)"

        {:error, msg} ->
          "  CA trust:      ❌ Failed: #{msg}\n" <>
            "                 Run: sudo orchardctl tls trust-ca"
      end

    ca_label = if data.reused_ca?, do: "(reused existing CA)", else: "(newly generated)"

    """
    ✅ TLS certificates generated successfully

      Output:        #{data.output_dir}

      CA Certificate #{ca_label}:
        Fingerprint: #{data.ca_fingerprint}
        Valid until: #{NaiveDateTime.to_date(data.ca_not_after)}

      Server Certificate:
        Common name: #{data.common_name}
        Fingerprint: #{data.server_fingerprint}
        Valid until: #{NaiveDateTime.to_date(data.server_not_after)}
        DNS SANs:    #{Enum.join(data.san_dns, ", ")}
        IP SANs:     #{Enum.join(data.san_ip, ", ")}

    #{trust_line}

      Next steps:
        1. Restart the controller to use the new certificates
        2. Install the CA on LAN clients via: https://<host>:8443/ca.crt
    """
    |> String.trim()
  end

  defp format_trust_summary(ca_crt_path, fingerprint) do
    """
    ✅ CA certificate trusted in macOS System Keychain

      CA cert:     #{ca_crt_path}
      Fingerprint: #{fingerprint}
      Keychain:    /Library/Keychains/System.keychain

      Note: LAN clients still need the CA installed separately.
      Download via: https://<host>:8443/ca.crt
    """
    |> String.trim()
  end

  # ── Usage Strings ───────────────────────────────────────────────────

  defp group_usage do
    """
    Usage: orchardctl tls <command>

    Commands:
      init       Generate local CA + server certificates
      trust-ca   Trust the CA in macOS System Keychain

    Run 'orchardctl tls <command> --help' for details.
    """
    |> String.trim()
  end

  defp init_usage do
    """
    Usage: orchardctl tls init [options]

    Generate a local CA and CA-signed server certificate for the
    Orchard controller's HTTPS listener.

    Options:
      --output-dir PATH    Output directory (default: <support_root>/config/tls)
      --common-name NAME   Server cert CN (default: detected hostname)
      --host NAME          Extra DNS SAN entry (repeatable)
      --ip ADDRESS         Extra IP SAN entry (repeatable)
      --ca-days N          CA validity in days (default: #{@default_ca_days})
      --server-days N      Server cert validity in days (default: #{@default_server_days})
      --force              Overwrite existing CA + server cert/key
      --no-trust           Skip auto-trust of CA in macOS System Keychain
      --help               Show this help

    Behavior:
      • First run: generates CA + server cert (4 files + metadata)
      • CA exists, no server cert: reuses CA to sign new server cert
      • CA + server exist: refuses without --force
      • --force: regenerates both CA and server cert
    """
    |> String.trim()
  end

  defp trust_ca_usage do
    """
    Usage: orchardctl tls trust-ca [options]

    Trust the Orchard-generated CA certificate in the macOS System
    Keychain. Requires root privileges.

    Options:
      --output-dir PATH   Certificate directory (default: <support_root>/config/tls)
      --help              Show this help
    """
    |> String.trim()
  end

  # ── Default Runtime ─────────────────────────────────────────────────

  defp default_runtime do
    %{
      cmd: &default_cmd/3,
      os_type: fn -> :os.type() end,
      uid: &default_uid/0,
      hostname: fn -> :inet.gethostname() end,
      ifaddrs: fn -> :inet.getifaddrs() end,
      now_utc: fn -> DateTime.utc_now() |> DateTime.truncate(:second) end
    }
  end

  defp default_cmd(executable, args, opts) do
    case System.find_executable(executable) do
      nil ->
        {:error, 127, "#{executable}: command not found"}

      exe_path ->
        cmd_opts =
          opts
          |> Keyword.take([:cd, :env])
          |> Keyword.put(:stderr_to_stdout, true)

        {output, status} = System.cmd(exe_path, args, cmd_opts)

        if status == 0 do
          {:ok, output}
        else
          {:error, status, output}
        end
    end
  end

  # Returns -1 on failure, which is a safe sentinel: check_can_trust/1 only
  # grants trust operations when uid == 0, so -1 correctly falls through to
  # the "root privileges required" error.
  defp default_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.to_integer()
      _ -> -1
    end
  rescue
    _ -> -1
  end
end
