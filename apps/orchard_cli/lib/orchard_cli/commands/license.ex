defmodule OrchardCLI.Commands.License do
  @moduledoc """
  CLI handler for `orchardctl license` commands.

  Supports:
    orchardctl license activate --key-stdin|--key-file PATH|<key> [--support-root PATH]
    orchardctl license status [--support-root PATH]
    orchardctl license create --policy-id POLICY_ID --name NAME [options]
    orchardctl license help
  """

  alias Orchard.Licensing
  alias Orchard.NodeIdentityFile

  @default_keygen_api_base_url "https://api.keygen.sh"
  @activation_required_validation_codes [
    "NO_MACHINES",
    "NO_MACHINE",
    "FINGERPRINT_SCOPE_MISMATCH"
  ]
  @json_api_content_type "application/vnd.api+json"
  @keygen_admin_token_env "ORCHARD_KEYGEN_ADMIN_TOKEN"
  @cli_fingerprint_states [:valid, :expired, :not_yet_valid, :fingerprint_mismatch]

  @type request_spec :: %{
          method: :get | :post,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: map() | nil
        }

  @type request_result ::
          {:ok, %{status: pos_integer(), body: map() | binary() | nil}} | {:error, term()}

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  # credo:disable-for-lines:3 ExSlop.Check.Readability.DocFalseOnPublicFunction
  @doc false
  @spec run([String.t()], map()) :: OrchardCLI.command_result()
  def run(args, runtime) do
    case args do
      ["activate" | rest] -> run_activate(rest, runtime)
      ["status" | rest] -> run_status(rest, runtime)
      ["create" | rest] -> run_create(rest, runtime)
      ["help"] -> {:ok, group_usage()}
      ["--help"] -> {:ok, group_usage()}
      [] -> {:error, group_usage(), 1}
      _ -> {:error, group_usage(), 1}
    end
  end

  defp run_activate(args, runtime) do
    case parse_activate_opts(args) do
      {:help} ->
        {:ok, activate_usage()}

      {:error, _, _} = error ->
        error

      {:ok, opts, key_source} ->
        case license_key_from_source(key_source, runtime) do
          {:ok, license_key} -> do_activate(opts, license_key, runtime)
          {:error, message} -> {:error, "Error: #{message}", 1}
        end
    end
  end

  defp run_status(args, runtime) do
    case parse_status_opts(args) do
      {:help} ->
        {:ok, status_usage()}

      {:error, _, _} = error ->
        error

      {:ok, opts} ->
        do_status(opts, runtime)
    end
  end

  defp run_create(args, runtime) do
    case parse_create_opts(args) do
      {:help} ->
        {:ok, create_usage()}

      {:error, _, _} = error ->
        error

      {:ok, opts} ->
        do_create(opts, runtime)
    end
  end

  defp parse_activate_opts(args) do
    switches = [support_root: :string, key_stdin: :boolean, key_file: :string, help: :boolean]

    case OptionParser.parse(args, strict: switches) do
      {parsed, positional, []} ->
        validate_activate_key_source(parsed, positional)

      {_parsed, _positional, invalid} ->
        invalid_str = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
        {:error, "Error: unknown option(s): #{invalid_str}\n\n#{activate_usage()}", 1}
    end
  end

  defp validate_activate_key_source(parsed, positional) do
    if Keyword.get(parsed, :help, false) do
      {:help}
    else
      parsed
      |> activate_key_sources(positional)
      |> validate_activate_key_source_count(parsed)
    end
  end

  defp validate_activate_key_source_count([source], parsed), do: {:ok, parsed, source}

  defp validate_activate_key_source_count([], _parsed),
    do: {:error, "Error: missing license key source\n\n#{activate_usage()}", 1}

  defp validate_activate_key_source_count(_sources, _parsed),
    do: {:error, "Error: expected exactly one license key source\n\n#{activate_usage()}", 1}

  defp activate_key_sources(parsed, positional) do
    positional_sources = Enum.map(positional, &{:argv, &1})

    []
    |> maybe_add_key_source(Keyword.get(parsed, :key_stdin, false), :stdin)
    |> maybe_add_key_source(non_empty_string(Keyword.get(parsed, :key_file)), :file)
    |> Enum.concat(positional_sources)
  end

  defp maybe_add_key_source(sources, false, _kind), do: sources
  defp maybe_add_key_source(sources, nil, _kind), do: sources
  defp maybe_add_key_source(sources, true, :stdin), do: [:stdin | sources]
  defp maybe_add_key_source(sources, path, :file), do: [{:file, path} | sources]

  defp parse_status_opts(args) do
    switches = [support_root: :string, json: :boolean, help: :boolean]

    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        if Keyword.get(parsed, :help, false), do: {:help}, else: {:ok, parsed}

      {_parsed, positional, []} ->
        {:error,
         "Error: unexpected argument(s): #{Enum.join(positional, ", ")}\n\n#{status_usage()}", 1}

      {_parsed, _positional, invalid} ->
        invalid_str = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
        {:error, "Error: unknown option(s): #{invalid_str}\n\n#{status_usage()}", 1}
    end
  end

  defp parse_create_opts(args) do
    switches = [
      policy_id: :string,
      name: :string,
      max_machines: :integer,
      expires_at: :string,
      tracking_program: :string,
      tracking_reference: :string,
      dry_run: :boolean,
      help: :boolean
    ]

    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        validate_create_opts(parsed)

      {_parsed, positional, []} ->
        {:error,
         "Error: unexpected argument(s): #{Enum.join(positional, ", ")}\n\n#{create_usage()}", 1}

      {_parsed, _positional, invalid} ->
        invalid_str = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
        {:error, "Error: unknown option(s): #{invalid_str}\n\n#{create_usage()}", 1}
    end
  end

  defp validate_create_opts(opts) do
    cond do
      Keyword.get(opts, :help, false) ->
        {:help}

      is_nil(non_empty_string(Keyword.get(opts, :policy_id))) ->
        {:error, "Error: missing required option: --policy-id\n\n#{create_usage()}", 1}

      is_nil(non_empty_string(Keyword.get(opts, :name))) ->
        {:error, "Error: missing required option: --name\n\n#{create_usage()}", 1}

      not valid_create_max_machines?(Keyword.get(opts, :max_machines)) ->
        {:error, "Error: --max-machines must be a positive integer\n\n#{create_usage()}", 1}

      not valid_create_expires_at?(Keyword.get(opts, :expires_at)) ->
        {:error, "Error: --expires-at must be ISO8601\n\n#{create_usage()}", 1}

      true ->
        {:ok, opts}
    end
  end

  defp valid_create_max_machines?(nil), do: true
  defp valid_create_max_machines?(value), do: is_integer(value) and value > 0

  defp valid_create_expires_at?(nil), do: true

  defp valid_create_expires_at?(value) when is_binary(value) do
    match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(value))
  end

  defp valid_create_expires_at?(_value), do: false

  defp do_activate(opts, license_key, runtime) do
    licensing_paths = resolve_licensing_paths(opts, runtime)

    with {:ok, config} <- activation_config(licensing_paths, runtime),
         {:ok, node_id, _source} <- ensure_node_identity(runtime, config.node_identity_path),
         {:ok, license_id} <- validate_key(runtime, config, license_key, node_id),
         {:ok, machine_id} <- ensure_machine(runtime, config, license_key, license_id, node_id),
         {:ok, license_certificate} <-
           checkout_license_certificate(runtime, config, license_key, license_id),
         {:ok, machine_certificate} <-
           checkout_machine_certificate(runtime, config, license_key, machine_id),
         {:ok, status} <- install_pair(runtime, config, license_certificate, machine_certificate) do
      {:ok, activation_success_message(status, node_id)}
    else
      {:error, {_kind, message}} -> activation_error(message, license_key)
    end
  end

  defp activation_error(message, license_key),
    do: {:error, "Error: #{redact_token(message, license_key)}", 1}

  defp do_status(opts, runtime) do
    config = status_config(resolve_licensing_paths(opts, runtime), runtime)

    status =
      licensing_impl(runtime).inspect_local(
        bundle_path: config.bundle_path,
        node_identity_path: config.node_identity_path,
        keygen_public_key: config.keygen_public_key
      )

    {:ok, render_status(status, opts)}
  end

  defp do_create(opts, runtime) do
    payload = create_license_payload(opts)

    if Keyword.get(opts, :dry_run, false) do
      {:ok, Jason.encode!(payload, pretty: true)}
    else
      create_license_live(payload, runtime)
    end
  end

  defp activation_config(licensing_paths, runtime) do
    shared = shared_licensing_config(runtime)

    config = %{
      bundle_path: non_empty_string(licensing_paths.bundle_path),
      node_identity_path: non_empty_string(licensing_paths.node_identity_path),
      keygen_api_base_url:
        non_empty_string(shared[:keygen_api_base_url]) || @default_keygen_api_base_url,
      keygen_account_id: non_empty_string(shared[:keygen_account_id]),
      keygen_public_key: non_empty_string(shared[:keygen_public_key])
    }

    cond do
      is_nil(config.bundle_path) ->
        {:error, {:config, "Licensing bundle path is not configured."}}

      is_nil(config.node_identity_path) ->
        {:error, {:config, "Node identity path is not configured."}}

      is_nil(config.keygen_account_id) ->
        {:error, {:config, "Keygen account ID is not configured."}}

      is_nil(config.keygen_public_key) ->
        {:error, {:config, "Keygen public key is not configured."}}

      true ->
        {:ok, config}
    end
  end

  defp status_config(licensing_paths, runtime) do
    shared = shared_licensing_config(runtime)

    %{
      bundle_path: non_empty_string(licensing_paths.bundle_path),
      node_identity_path: non_empty_string(licensing_paths.node_identity_path),
      keygen_public_key: non_empty_string(shared[:keygen_public_key])
    }
  end

  defp create_config(runtime) do
    shared = shared_licensing_config(runtime)

    config = %{
      keygen_api_base_url:
        non_empty_string(shared[:keygen_api_base_url]) || @default_keygen_api_base_url,
      keygen_account_id: non_empty_string(shared[:keygen_account_id])
    }

    if is_nil(config.keygen_account_id) do
      {:error, {:create, "Keygen account ID is not configured."}}
    else
      {:ok, config}
    end
  end

  defp license_key_from_source({:argv, license_key}, _runtime),
    do: normalize_license_key(license_key)

  defp license_key_from_source(:stdin, runtime) do
    runtime
    |> read_stdin_impl()
    |> normalize_license_key()
  end

  defp license_key_from_source({:file, path}, runtime) do
    with {:ok, stat} <- key_file_stat(path),
         :ok <- require_regular_key_file(path, stat),
         :ok <- require_private_key_file_mode(path, stat),
         :ok <- after_key_file_stat_impl(runtime).(path, stat),
         {:ok, io_device} <- open_key_file(path),
         {:ok, contents} <- read_validated_key_file(path, stat, io_device) do
      normalize_license_key(contents)
    else
      {:error, {:file_error, message}} -> {:error, message}
      {:error, reason} -> {:error, "Cannot read license key file #{path}: #{inspect(reason)}."}
    end
  end

  defp normalize_license_key(value) do
    case non_empty_string(value) do
      nil -> {:error, "License key source was empty."}
      license_key -> {:ok, license_key}
    end
  end

  defp key_file_stat(path) do
    case File.lstat(path) do
      {:ok, stat} ->
        {:ok, stat}

      {:error, reason} ->
        {:error, {:file_error, "Cannot stat license key file #{path}: #{inspect(reason)}."}}
    end
  end

  defp require_regular_key_file(_path, %{type: :regular}), do: :ok

  defp require_regular_key_file(
         _path,
         {:file_info, _size, :regular, _access, _atime, _mtime, _ctime, _mode, _links,
          _major_device, _minor_device, _inode, _uid, _gid}
       ),
       do: :ok

  defp require_regular_key_file(path, _stat),
    do: {:error, {:file_error, "License key file #{path} must be a regular file."}}

  defp require_private_key_file_mode(path, %{mode: mode}) do
    require_private_key_file_mode_value(path, mode)
  end

  defp require_private_key_file_mode(
         path,
         {:file_info, _size, _type, _access, _atime, _mtime, _ctime, mode, _links, _major_device,
          _minor_device, _inode, _uid, _gid}
       ) do
    require_private_key_file_mode_value(path, mode)
  end

  defp require_private_key_file_mode_value(path, mode) do
    if Bitwise.band(mode, 0o777) == 0o600 do
      :ok
    else
      {:error, {:file_error, "License key file #{path} must have 0600 permissions."}}
    end
  end

  defp open_key_file(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, io_device} ->
        {:ok, io_device}

      {:error, reason} ->
        {:error, {:file_error, "Cannot open license key file #{path}: #{inspect(reason)}."}}
    end
  end

  defp read_validated_key_file(path, stat, io_device) do
    try do
      with {:ok, opened_stat} <- opened_key_file_stat(path, io_device),
           :ok <- require_same_opened_key_file(path, stat, opened_stat),
           :ok <- require_regular_key_file(path, opened_stat),
           :ok <- require_private_key_file_mode(path, opened_stat),
           {:ok, contents} <- read_opened_key_file(path, opened_stat, io_device) do
        {:ok, contents}
      end
    after
      :file.close(io_device)
    end
  end

  defp opened_key_file_stat(path, io_device) do
    case :file.read_file_info(io_device) do
      {:ok, stat} ->
        {:ok, stat}

      {:error, reason} ->
        {:error,
         {:file_error, "Cannot inspect opened license key file #{path}: #{inspect(reason)}."}}
    end
  end

  defp require_same_opened_key_file(path, expected, opened) do
    if opened_key_file_identity(expected) == opened_key_file_identity(opened) do
      :ok
    else
      {:error,
       {:file_error,
        "License key file #{path} changed while it was being opened; refusing to read it."}}
    end
  end

  defp opened_key_file_identity(%{
         major_device: major_device,
         minor_device: minor_device,
         inode: inode
       }) do
    {major_device, minor_device, inode}
  end

  defp opened_key_file_identity(
         {:file_info, _size, _type, _access, _atime, _mtime, _ctime, _mode, _links, major_device,
          minor_device, inode, _uid, _gid}
       ) do
    {major_device, minor_device, inode}
  end

  defp read_opened_key_file(path, opened_stat, io_device) do
    case :file.read(io_device, opened_key_file_size(opened_stat)) do
      {:ok, contents} ->
        {:ok, contents}

      :eof ->
        {:ok, ""}

      {:error, reason} ->
        {:error, {:file_error, "Cannot read license key file #{path}: #{inspect(reason)}."}}
    end
  end

  defp opened_key_file_size(
         {:file_info, size, _type, _access, _atime, _mtime, _ctime, _mode, _links, _major_device,
          _minor_device, _inode, _uid, _gid}
       ),
       do: size

  defp create_license_live(payload, runtime) do
    with {:ok, config} <- create_config(runtime),
         {:ok, admin_token} <- admin_token(runtime),
         result <- create_license_with_token(payload, runtime, config, admin_token) do
      case result do
        {:ok, message} ->
          {:ok, message}

        {:error, {:create, message}} ->
          {:error, "Error: #{redact_token(message, admin_token)}", 1}
      end
    else
      {:error, {:create, message}} -> {:error, "Error: #{message}", 1}
    end
  end

  defp create_license_with_token(payload, runtime, config, admin_token) do
    with {:ok, body} <- post_create_license(runtime, config, admin_token, payload),
         {:ok, summary} <- extract_created_license_summary(body, payload) do
      {:ok, render_created_license(summary)}
    end
  end

  defp post_create_license(runtime, config, admin_token, payload) do
    request = %{
      method: :post,
      url: keygen_url(config, ["licenses"]),
      headers: admin_auth_headers(admin_token),
      body: payload
    }

    with {:ok, response} <- perform_request(runtime, request, :create, "license creation"),
         :ok <- ensure_success_status(response, "license creation", :create),
         {:ok, body} <- decode_json_body(response.body, "license creation", :create) do
      {:ok, body}
    else
      {:error, {:create, _message}} = error -> error
    end
  end

  defp ensure_node_identity(runtime, path) do
    case node_identity_impl(runtime).ensure(path) do
      {:ok, node_id, source} ->
        {:ok, node_id, source}

      {:error, {:invalid_uuid, value}} ->
        {:error, {:identity, "Local node identity is invalid: #{inspect(value)}."}}

      {:error, {:read_failed, reason}} ->
        {:error, {:identity, "Cannot read node identity file #{path}: #{inspect(reason)}."}}

      {:error, {:write_failed, reason}} ->
        {:error, {:identity, "Cannot persist node identity file #{path}: #{inspect(reason)}."}}
    end
  end

  defp validate_key(runtime, config, license_key, fingerprint) do
    body = %{
      "meta" => %{
        "key" => license_key,
        "scope" => %{
          "fingerprint" => fingerprint
        }
      }
    }

    request = %{
      method: :post,
      url: keygen_url(config, ["licenses", "actions", "validate-key"]),
      headers: json_api_headers(),
      body: body
    }

    with {:ok, response} <- perform_request(runtime, request, :validation, "license validation"),
         :ok <- ensure_success_status(response, "license validation", :validation),
         {:ok, body} <- decode_json_body(response.body, "license validation", :validation),
         {:ok, license_id} <- extract_license_id(body) do
      {:ok, license_id}
    else
      {:error, {:validation, _message}} = error -> error
    end
  end

  defp ensure_machine(runtime, config, license_key, license_id, fingerprint) do
    case lookup_existing_machine_id(runtime, config, license_key, fingerprint) do
      {:ok, nil} ->
        activate_machine(runtime, config, license_key, license_id, fingerprint)

      {:ok, machine_id} ->
        {:ok, machine_id}

      {:error, {:activation, _message}} = error ->
        error
    end
  end

  defp activate_machine(runtime, config, license_key, license_id, fingerprint) do
    body = %{
      "data" => %{
        "type" => "machines",
        "attributes" => %{
          "fingerprint" => fingerprint,
          "platform" => "macOS",
          "name" => System.get_env("HOSTNAME") || "Orchard node"
        },
        "relationships" => %{
          "license" => %{
            "data" => %{"type" => "licenses", "id" => license_id}
          }
        }
      }
    }

    request = %{
      method: :post,
      url: keygen_url(config, ["machines"]),
      headers: license_auth_headers(license_key),
      body: body
    }

    with {:ok, response} <-
           perform_request(runtime, request, :activation, "machine activation"),
         :ok <- ensure_success_status(response, "machine activation", :activation),
         {:ok, body} <- decode_json_body(response.body, "machine activation", :activation),
         {:ok, machine_id} <- extract_machine_id(body, "machine activation") do
      {:ok, machine_id}
    else
      {:error, {:activation, _message}} = error -> error
    end
  end

  defp checkout_license_certificate(runtime, config, license_key, license_id) do
    request = %{
      method: :post,
      url: keygen_url(config, ["licenses", license_id, "actions", "check-out"]),
      headers: license_auth_headers(license_key),
      body: nil
    }

    checkout_certificate(runtime, request, "license", :checkout)
  end

  defp checkout_machine_certificate(runtime, config, license_key, machine_id) do
    request = %{
      method: :post,
      url: keygen_url(config, ["machines", machine_id, "actions", "check-out"]),
      headers: license_auth_headers(license_key),
      body: nil
    }

    checkout_certificate(runtime, request, "machine", :checkout)
  end

  defp checkout_certificate(runtime, request, kind, error_kind) do
    action = "#{kind} checkout"

    with {:ok, response} <- perform_request(runtime, request, error_kind, action),
         :ok <- ensure_success_status(response, action, error_kind),
         {:ok, body} <- decode_json_body(response.body, action, error_kind),
         {:ok, certificate} <- extract_certificate(body, kind, error_kind) do
      {:ok, certificate}
    else
      {:error, {^error_kind, _message}} = error -> error
    end
  end

  defp install_pair(runtime, config, license_certificate, machine_certificate) do
    bundle = %{
      license_certificate: license_certificate,
      machine_certificate: machine_certificate
    }

    case licensing_impl(runtime).install_pair(bundle,
           bundle_path: config.bundle_path,
           node_identity_path: config.node_identity_path,
           keygen_public_key: config.keygen_public_key
         ) do
      {:ok, status} ->
        {:ok, status}

      {:error, {:write_failed, reason}} ->
        {:error,
         {:install, "Cannot persist licensing bundle #{config.bundle_path}: #{inspect(reason)}."}}

      {:error, %Licensing{} = status} ->
        {:error, {:install, status.message}}
    end
  end

  defp lookup_existing_machine_id(runtime, config, license_key, fingerprint) do
    do_lookup_existing_machine_id(
      runtime,
      machines_list_request(config, license_key),
      license_key,
      fingerprint,
      %{}
    )
  end

  defp do_lookup_existing_machine_id(
         runtime,
         %{url: url} = request,
         license_key,
         fingerprint,
         seen_urls
       ) do
    with {:ok, seen_urls} <- track_machine_lookup_url(seen_urls, url),
         {:ok, response} <- perform_request(runtime, request, :activation, "machine lookup"),
         :ok <- ensure_success_status(response, "machine lookup", :activation),
         {:ok, body} <- decode_json_body(response.body, "machine lookup", :activation) do
      continue_machine_lookup(body, runtime, license_key, fingerprint, seen_urls)
    end
  end

  defp continue_machine_lookup(body, runtime, license_key, fingerprint, seen_urls) do
    with {:ok, machine_id} <- existing_machine_id(body, fingerprint),
         {:ok, next_url} <- next_machine_page_url(body) do
      finish_machine_lookup(machine_id, next_url, runtime, license_key, fingerprint, seen_urls)
    end
  end

  defp finish_machine_lookup(
         machine_id,
         _next_url,
         _runtime,
         _license_key,
         _fingerprint,
         _seen_urls
       )
       when is_binary(machine_id) and machine_id != "" do
    {:ok, machine_id}
  end

  defp finish_machine_lookup(_machine_id, next_url, runtime, license_key, fingerprint, seen_urls)
       when is_binary(next_url) and next_url != "" do
    do_lookup_existing_machine_id(
      runtime,
      machine_page_request(next_url, license_key),
      license_key,
      fingerprint,
      seen_urls
    )
  end

  defp finish_machine_lookup(
         _machine_id,
         _next_url,
         _runtime,
         _license_key,
         _fingerprint,
         _seen_urls
       ) do
    {:ok, nil}
  end

  defp track_machine_lookup_url(seen_urls, url) do
    if Map.has_key?(seen_urls, url) do
      {:error, {:activation, "Malformed response from machine lookup."}}
    else
      {:ok, Map.put(seen_urls, url, true)}
    end
  end

  defp machines_list_request(config, license_key) do
    machine_page_request(keygen_url(config, ["machines"]) <> "?limit=100", license_key)
  end

  defp machine_page_request(url, license_key) do
    %{
      method: :get,
      url: url,
      headers: license_auth_headers(license_key),
      body: nil
    }
  end

  defp existing_machine_id(%{"data" => machines}, fingerprint) when is_list(machines) do
    machine_id =
      Enum.find_value(machines, fn
        %{"id" => machine_id, "attributes" => %{"fingerprint" => ^fingerprint}}
        when is_binary(machine_id) and machine_id != "" ->
          machine_id

        _other ->
          nil
      end)

    {:ok, machine_id}
  end

  defp existing_machine_id(_body, _fingerprint) do
    {:error, {:activation, "Malformed response from machine lookup."}}
  end

  defp next_machine_page_url(%{"links" => %{"next" => next_url}})
       when is_binary(next_url) and next_url != "" do
    {:ok, next_url}
  end

  defp next_machine_page_url(%{"links" => %{"next" => nil}}), do: {:ok, nil}
  defp next_machine_page_url(%{"links" => links}) when is_map(links), do: {:ok, nil}
  defp next_machine_page_url(%{}), do: {:ok, nil}

  defp extract_license_id(%{"meta" => %{"valid" => true}, "data" => %{"id" => license_id}})
       when is_binary(license_id) and license_id != "" do
    {:ok, license_id}
  end

  defp extract_license_id(%{
         "meta" => %{"valid" => false, "code" => code},
         "data" => %{"id" => license_id}
       })
       when code in @activation_required_validation_codes and is_binary(license_id) and
              license_id != "" do
    {:ok, license_id}
  end

  defp extract_license_id(%{"meta" => %{"valid" => false, "code" => code}})
       when code in @activation_required_validation_codes do
    {:error, {:validation, "Malformed response from license validation."}}
  end

  defp extract_license_id(%{"meta" => %{"valid" => false, "detail" => detail}})
       when is_binary(detail) and detail != "" do
    {:error, {:validation, detail}}
  end

  defp extract_license_id(_body) do
    {:error, {:validation, "Malformed response from license validation."}}
  end

  defp extract_machine_id(%{"data" => %{"id" => machine_id}}, _action)
       when is_binary(machine_id) and machine_id != "" do
    {:ok, machine_id}
  end

  defp extract_machine_id(_body, action) do
    {:error, {:activation, "Malformed #{action} response."}}
  end

  defp extract_certificate(
         %{"data" => %{"attributes" => %{"certificate" => certificate}}},
         _kind,
         _error_kind
       )
       when is_binary(certificate) and certificate != "" do
    {:ok, certificate}
  end

  defp extract_certificate(%{"data" => %{"attributes" => _attributes}}, kind, error_kind) do
    {:error, {error_kind, "Malformed #{kind} checkout response: certificate is missing."}}
  end

  defp extract_certificate(_body, kind, error_kind) do
    {:error, {error_kind, "Malformed #{kind} checkout response."}}
  end

  defp perform_request(runtime, %{} = request, error_kind, action) do
    case request_impl(runtime).(request) do
      {:ok, %{status: status} = response} when is_integer(status) ->
        {:ok, %{status: status, body: Map.get(response, :body)}}

      {:error, reason} ->
        {:error, {error_kind, "#{String.capitalize(action)} request failed: #{inspect(reason)}."}}

      other ->
        {:error,
         {error_kind, "Unexpected HTTP client response during #{action}: #{inspect(other)}."}}
    end
  end

  defp ensure_success_status(%{status: status}, _action, _error_kind) when status in 200..299,
    do: :ok

  defp ensure_success_status(%{status: status, body: body}, action, error_kind) do
    {:error, {error_kind, format_provider_error(action, status, body)}}
  end

  defp decode_json_body(body, _action, _error_kind) when is_map(body), do: {:ok, body}

  defp decode_json_body(body, action, error_kind) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _other} ->
        {:error, {error_kind, "Malformed #{action} response."}}

      {:error, _reason} ->
        {:error, {error_kind, "Malformed #{action} response."}}
    end
  end

  defp decode_json_body(_body, action, error_kind) do
    {:error, {error_kind, "Malformed #{action} response."}}
  end

  defp format_provider_error(action, status, %{"errors" => [first | _rest]}) when is_map(first) do
    detail = non_empty_string(first["detail"]) || non_empty_string(first["title"])
    code = non_empty_string(first["code"])
    suffix = if code, do: " (#{code})", else: ""
    summary = detail || "request failed"
    "#{String.capitalize(action)} failed with HTTP #{status}: #{summary}#{suffix}."
  end

  defp format_provider_error(action, status, %{"meta" => %{"detail" => detail}})
       when is_binary(detail) and detail != "" do
    "#{String.capitalize(action)} failed with HTTP #{status}: #{detail}."
  end

  defp format_provider_error(action, status, _body) do
    "#{String.capitalize(action)} failed with HTTP #{status}."
  end

  defp create_license_payload(opts) do
    attributes =
      %{"name" => non_empty_string(Keyword.fetch!(opts, :name))}
      |> maybe_put_create_attribute("maxMachines", Keyword.get(opts, :max_machines))
      |> maybe_put_create_attribute("expiry", non_empty_string(Keyword.get(opts, :expires_at)))
      |> maybe_put_create_metadata(opts)

    %{
      "data" => %{
        "type" => "licenses",
        "attributes" => attributes,
        "relationships" => %{
          "policy" => %{
            "data" => %{
              "type" => "policies",
              "id" => non_empty_string(Keyword.fetch!(opts, :policy_id))
            }
          }
        }
      }
    }
  end

  defp maybe_put_create_attribute(attributes, _key, nil), do: attributes
  defp maybe_put_create_attribute(attributes, key, value), do: Map.put(attributes, key, value)

  defp maybe_put_create_metadata(attributes, opts) do
    tracking =
      %{}
      |> maybe_put_tracking_field(
        "program",
        normalize_create_tracking(Keyword.get(opts, :tracking_program))
      )
      |> maybe_put_tracking_field(
        "reference",
        normalize_create_tracking(Keyword.get(opts, :tracking_reference))
      )

    if map_size(tracking) == 0 do
      attributes
    else
      Map.put(attributes, "metadata", %{"orchard_tracking" => tracking})
    end
  end

  defp maybe_put_tracking_field(tracking, _key, nil), do: tracking
  defp maybe_put_tracking_field(tracking, key, value), do: Map.put(tracking, key, value)

  defp normalize_create_tracking(nil), do: nil

  defp normalize_create_tracking(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_create_tracking(_value), do: nil

  defp admin_token(runtime) do
    case non_empty_string(admin_token_impl(runtime).(@keygen_admin_token_env)) do
      nil ->
        {:error,
         {:create,
          "ORCHARD_KEYGEN_ADMIN_TOKEN is required for live license creation. Use --dry-run to preview the request payload."}}

      token ->
        {:ok, token}
    end
  end

  defp redact_token(message, token) when is_binary(message) and is_binary(token) do
    String.replace(message, token, "[REDACTED]")
  end

  defp redact_token(message, _token), do: message

  defp extract_created_license_summary(%{"data" => %{"id" => id, "attributes" => attrs}}, payload)
       when is_binary(id) and is_map(attrs) do
    {:ok,
     %{
       id: id,
       key: non_empty_string(attrs["key"]),
       tracking: get_in(payload, ["data", "attributes", "metadata", "orchard_tracking"])
     }}
  end

  defp extract_created_license_summary(_body, _payload) do
    {:error, {:create, "Malformed license creation response."}}
  end

  defp render_created_license(summary) do
    ([
       "License created",
       "  License ID: #{summary.id}",
       maybe_line("  License key: ", summary.key)
     ] ++ created_tracking_lines(summary.tracking))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp created_tracking_lines(nil), do: []

  defp created_tracking_lines(tracking) when is_map(tracking) do
    [
      maybe_tracking_line("Program", format_tracking_program(tracking["program"])),
      maybe_tracking_line("Reference", tracking["reference"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp created_tracking_lines(_tracking), do: []

  defp activation_success_message(%Licensing{} = status, node_id) do
    ([
       "License activated",
       "  Node fingerprint: #{node_id}",
       "  Bundle path: #{status.bundle_path}",
       "  License state: #{status.state}",
       maybe_line("  License ID: ", status.license_id),
       maybe_line("  Machine ID: ", status.machine_id),
       maybe_line("  Expires at: ", iso8601(status.expires_at))
     ] ++ maybe_tracking_lines(status.metadata))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp render_status(%Licensing{} = status, opts) do
    if Keyword.get(opts, :json, false) do
      render_status_json(status)
    else
      render_local_status(status)
    end
  end

  defp render_status_json(%Licensing{} = status) do
    status
    |> status_json_payload()
    |> Jason.encode!(pretty: true)
  end

  defp status_json_payload(%Licensing{} = status) do
    health = Licensing.health_summary(status)

    %{}
    |> maybe_put_json_field(:state, health[:status])
    |> maybe_put_json_field(:reason, health[:reason])
    |> maybe_put_json_field(:message, health[:message])
    |> maybe_put_json_field(:bundle_path, status.bundle_path)
    |> maybe_put_status_json_fingerprints(status)
    |> maybe_put_json_field(:license_id, health[:license_id])
    |> maybe_put_json_field(:machine_id, health[:machine_id])
    |> maybe_put_json_field(:licensee, health[:licensee])
    |> maybe_put_json_field(:max_machines, health[:max_machines])
    |> maybe_put_json_field(:expires_at, health[:expires_at])
    |> maybe_put_json_field(:tracking, status_json_tracking(health[:tracking]))
  end

  defp status_json_tracking(metadata) when is_map(metadata) do
    tracking =
      %{}
      |> maybe_put_json_field(:program, tracking_value(metadata, :program))
      |> maybe_put_json_field(:reference, tracking_value(metadata, :reference))

    if map_size(tracking) == 0, do: nil, else: tracking
  end

  defp status_json_tracking(_metadata), do: nil

  defp maybe_put_json_field(payload, _key, nil), do: payload

  defp maybe_put_json_field(payload, key, value) when is_binary(value) do
    case non_empty_string(value) do
      nil -> payload
      trimmed -> Map.put(payload, key, trimmed)
    end
  end

  defp maybe_put_json_field(payload, key, value), do: Map.put(payload, key, value)

  defp render_local_status(%Licensing{} = status) do
    health = Licensing.health_summary(status)

    ([
       "License status: #{status.state}",
       "  Message: #{health[:message]}",
       "  Bundle path: #{status.bundle_path}"
       | fingerprint_lines(status)
     ] ++
       [
         maybe_line("  License ID: ", health[:license_id]),
         maybe_line("  Machine ID: ", health[:machine_id]),
         maybe_line("  Licensee: ", health[:licensee]),
         maybe_line(
           "  Max machines: ",
           health[:max_machines] && Integer.to_string(health[:max_machines])
         ),
         maybe_line("  Expires at: ", health[:expires_at])
       ] ++ maybe_tracking_lines(health[:tracking]))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp maybe_put_status_json_fingerprints(payload, %Licensing{state: state} = status)
       when state in @cli_fingerprint_states do
    payload
    |> maybe_put_json_field(:fingerprint, status.fingerprint)
    |> maybe_put_json_field(:local_node_fingerprint, status.local_node_fingerprint)
  end

  defp maybe_put_status_json_fingerprints(payload, %Licensing{}), do: payload

  defp fingerprint_lines(%Licensing{state: state}) when state not in @cli_fingerprint_states,
    do: []

  defp fingerprint_lines(%Licensing{fingerprint: nil}), do: []

  defp fingerprint_lines(%Licensing{
         fingerprint: fingerprint,
         local_node_fingerprint: fingerprint
       })
       when is_binary(fingerprint) do
    ["  Machine certificate fingerprint: #{fingerprint}"]
  end

  defp fingerprint_lines(%Licensing{
         fingerprint: fingerprint,
         local_node_fingerprint: local_fingerprint
       })
       when is_binary(fingerprint) and is_binary(local_fingerprint) do
    [
      "  Local node fingerprint: #{local_fingerprint}",
      "  Machine certificate fingerprint: #{fingerprint}"
    ]
  end

  defp fingerprint_lines(%Licensing{fingerprint: fingerprint}) when is_binary(fingerprint) do
    ["  Machine certificate fingerprint: #{fingerprint}"]
  end

  defp keygen_url(config, segments) do
    base = String.trim_trailing(config.keygen_api_base_url, "/")
    account_id = URI.encode(config.keygen_account_id)
    path = Enum.map_join(segments, "/", &URI.encode/1)
    base <> "/v1/accounts/" <> account_id <> "/" <> path
  end

  defp json_api_headers do
    [
      {"accept", @json_api_content_type},
      {"content-type", @json_api_content_type}
    ]
  end

  defp license_auth_headers(license_key) do
    [{"authorization", "License #{license_key}"} | json_api_headers()]
  end

  defp admin_auth_headers(admin_token) do
    [{"authorization", "Bearer #{admin_token}"} | json_api_headers()]
  end

  defp licensing_impl(runtime), do: Map.get(runtime, :licensing_impl, Licensing)
  defp node_identity_impl(runtime), do: Map.get(runtime, :node_identity_impl, NodeIdentityFile)
  defp admin_token_impl(runtime), do: Map.get(runtime, :admin_token, &System.get_env/1)

  defp shared_config_impl(runtime),
    do:
      Map.get(runtime, :shared_config, fn ->
        Application.get_env(:orchard_shared, :licensing, [])
      end)

  defp shared_licensing_config(runtime), do: shared_config_impl(runtime).()
  defp request_impl(runtime), do: Map.get(runtime, :request, &default_request/1)
  defp read_stdin_impl(runtime), do: Map.get(runtime, :read_stdin, &default_read_stdin/0).()

  defp after_key_file_stat_impl(runtime),
    do: Map.get(runtime, :after_key_file_stat, fn _path, _stat -> :ok end)

  defp default_read_stdin do
    case IO.read(:stdio, :line) do
      data when is_binary(data) -> data
      data when is_list(data) -> IO.iodata_to_binary(data)
      :eof -> ""
    end
  end

  defp resolve_licensing_paths(opts, runtime) do
    case support_root_override(opts) do
      nil ->
        shared = shared_licensing_config(runtime)

        %{
          bundle_path: shared[:bundle_path],
          node_identity_path: shared[:node_identity_path]
        }

      support_root ->
        %{
          bundle_path: bundle_path(support_root),
          node_identity_path: node_identity_path(support_root)
        }
    end
  end

  defp support_root_override(opts) do
    non_empty_string(Keyword.get(opts, :support_root)) ||
      non_empty_string(System.get_env("ORCHARD_SUPPORT_ROOT"))
  end

  defp bundle_path(support_root),
    do: Path.join([support_root, "config", "licensing", "current.json"])

  defp node_identity_path(support_root), do: Path.join([support_root, "data", "node-id"])

  defp default_request(%{method: method, url: url, headers: headers, body: body}) do
    req_opts =
      [
        url: url,
        method: method,
        headers: headers,
        retry: false,
        redirect: false
      ]
      |> maybe_put_body(body)

    case OrchardCLI.HTTP.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_body(opts, body) when is_map(body),
    do: Keyword.put(opts, :body, Jason.encode!(body))

  defp maybe_put_body(opts, _body), do: opts

  defp maybe_line(_label, nil), do: nil
  defp maybe_line(label, value), do: label <> value

  defp maybe_tracking_lines(nil), do: []

  defp maybe_tracking_lines(metadata) when is_map(metadata) do
    [
      maybe_tracking_line("Program", format_tracking_program(tracking_value(metadata, :program))),
      maybe_tracking_line("Reference", tracking_value(metadata, :reference))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_tracking_lines(_metadata), do: []

  defp maybe_tracking_line(_label, nil), do: nil
  defp maybe_tracking_line(label, value), do: "  Tracking #{label}: #{value}"

  defp tracking_value(metadata, key),
    do: Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))

  defp format_tracking_program("aieh"), do: "AIEH"
  defp format_tracking_program("100e"), do: "100E"
  defp format_tracking_program("sip"), do: "SIP"
  defp format_tracking_program(program), do: program

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp non_empty_string(nil), do: nil

  defp non_empty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_string(_value), do: nil

  defp default_runtime do
    %{
      request: &default_request/1,
      licensing_impl: Licensing,
      node_identity_impl: NodeIdentityFile,
      shared_config: fn -> Application.get_env(:orchard_shared, :licensing, []) end
    }
  end

  defp group_usage do
    """
    Usage: orchardctl license <activate|status|create|help>

    Manage Orchard's local dual-certificate license bundle.

    Commands:
      activate --key-stdin|--key-file PATH
        Activate a license and install the local bundle
      status [--support-root PATH]
        Inspect the local license bundle offline
      create --policy-id ID --name NAME     Internal/admin: create a Keygen license
      help                                  Show this help
    """
    |> String.trim()
  end

  defp activate_usage do
    """
    Usage: orchardctl license activate (--key-stdin|--key-file PATH|<key>) [--support-root PATH]

    Activate a license using a customer-safe Keygen flow, check out the Orchard
    license + machine certificates, validate them offline, and atomically install
    the local bundle at <support_root>/config/licensing/current.json.

    Prefer --key-stdin or --key-file for operator and release-gate activation so
    license keys do not appear in process arguments. Legacy/debug only:
    `orchardctl license activate <key>`.

    Options:
      --key-stdin           Read the activation key from standard input
      --key-file PATH       Read the activation key from a regular file with 0600 permissions
      --support-root PATH   Support root directory
                            (default precedence: --support-root, then
                             $ORCHARD_SUPPORT_ROOT, else current environment licensing config)
    """
    |> String.trim()
  end

  defp status_usage do
    """
    Usage: orchardctl license status [--support-root PATH] [--json]

    Inspect the local Orchard license bundle offline without contacting the
    controller and without generating a node identity as a side effect.

    Options:
      --support-root PATH   Support root directory
                            (default precedence: --support-root, then
                             $ORCHARD_SUPPORT_ROOT, else current environment licensing config)
      --json                Print a stable support/Jamf automation JSON payload
    """
    |> String.trim()
  end

  defp create_usage do
    """
    Usage: orchardctl license create --policy-id POLICY_ID --name NAME [options]

    Internal/admin command for creating Keygen licenses. Live mode requires
    ORCHARD_KEYGEN_ADMIN_TOKEN. The admin token is read from the environment
    only; it is never persisted or printed.

    Options:
      --policy-id POLICY_ID          Keygen policy ID
      --name NAME                    License name
      --max-machines N               Optional maximum machines
      --expires-at ISO8601           Optional expiry timestamp
      --tracking-program VALUE       Optional tracking program (aieh, 100e, sip)
      --tracking-reference VALUE     Optional tracking reference
      --dry-run                      Print the JSON:API payload without network access
    """
    |> String.trim()
  end
end
