defmodule OrchardCLI.Commands.ApiClients do
  @moduledoc """
  CLI handler for API Client provisioning commands.
  """

  alias Orchard.Governance
  alias Orchard.Governance.ApiClientProvisioning

  @output_headers ~w(
    organization
    api_client
    external_ref
    key_name
    api_token_id
    api_token_prefix
    api_token
    expires_at
  )

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args) do
    case args do
      ["bulk-provision" | rest] -> run_bulk_provision(rest)
      ["help"] -> {:ok, group_usage()}
      ["--help"] -> {:ok, group_usage()}
      [] -> {:error, group_usage(), 1}
      _ -> {:error, group_usage(), 1}
    end
  end

  defp run_bulk_provision(args) do
    case parse_bulk_opts(args) do
      {:help} ->
        {:ok, bulk_usage()}

      {:error, _, _} = error ->
        error

      {:ok, opts} ->
        with {:ok, mode} <- validate_mode(opts),
             {:ok, input_path} <- fetch_required_path(opts, :file, "--file"),
             {:ok, output_path} <- validate_output_option(mode, opts),
             {:ok, csv} <- read_csv(input_path),
             :ok <- maybe_preflight_output(output_path),
             {:ok, rows} <- parse_csv(csv.contents),
             {:ok, message} <- execute_bulk(mode, rows, csv, output_path, opts) do
          {:ok, message}
        else
          {:error, _, _} = error -> error
        end
    end
  end

  defp parse_bulk_opts(args) do
    switches = [
      dry_run: :boolean,
      apply: :boolean,
      file: :string,
      output: :string,
      rotation: :boolean,
      json: :boolean,
      help: :boolean
    ]

    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        if Keyword.get(parsed, :help, false), do: {:help}, else: {:ok, parsed}

      {_parsed, positional, []} ->
        {:error,
         "Error: unexpected argument(s): #{Enum.join(positional, ", ")}\n\n#{bulk_usage()}", 1}

      {_parsed, _positional, invalid} ->
        invalid_str = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
        {:error, "Error: unknown option(s): #{invalid_str}\n\n#{bulk_usage()}", 1}
    end
  end

  defp validate_mode(opts) do
    case {Keyword.get(opts, :dry_run, false), Keyword.get(opts, :apply, false)} do
      {true, false} ->
        {:ok, :dry_run}

      {false, true} ->
        {:ok, :apply}

      {false, false} ->
        {:error, "Error: choose exactly one of --dry-run or --apply.\n\n#{bulk_usage()}", 1}

      {true, true} ->
        {:error, "Error: choose exactly one of --dry-run or --apply.\n\n#{bulk_usage()}", 1}
    end
  end

  defp fetch_required_path(opts, key, switch) do
    case Keyword.get(opts, key) do
      nil -> {:error, "Error: missing required option: #{switch}\n\n#{bulk_usage()}", 1}
      path -> {:ok, Path.expand(path)}
    end
  end

  defp validate_output_option(:apply, opts), do: fetch_required_path(opts, :output, "--output")

  defp validate_output_option(:dry_run, opts) do
    case Keyword.get(opts, :output) do
      nil -> {:ok, nil}
      path -> {:ok, Path.expand(path)}
    end
  end

  defp read_csv(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, %{path: path, contents: contents, sha256: sha256(contents)}}

      {:error, reason} ->
        {:error, "Error: unable to read CSV file #{path}: #{:file.format_error(reason)}", 1}
    end
  end

  defp maybe_preflight_output(nil), do: :ok

  defp maybe_preflight_output(path) do
    cond do
      File.exists?(path) ->
        {:error, "Error: output path already exists: #{path}", 1}

      not File.dir?(Path.dirname(path)) ->
        {:error, "Error: output parent directory does not exist: #{Path.dirname(path)}", 1}

      true ->
        :ok
    end
  end

  defp parse_csv(contents) do
    rows = NimbleCSV.RFC4180.parse_string(contents, skip_headers: false)

    case rows do
      [] ->
        {:error, "Error: CSV must include a header row.", 1}

      [headers | data_rows] ->
        headers = Enum.map(headers, &String.trim/1)

        with :ok <- validate_unique_headers(headers),
             :ok <- validate_required_headers(headers) do
          rows_to_maps(headers, data_rows)
        end
    end
  rescue
    error in NimbleCSV.ParseError ->
      {:error, "Error: invalid CSV: #{Exception.message(error)}", 1}
  end

  defp validate_unique_headers(headers) do
    duplicates =
      headers
      |> Enum.frequencies()
      |> Enum.filter(fn {_header, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    case duplicates do
      [] -> :ok
      duplicates -> {:error, "Error: duplicate CSV header(s): #{Enum.join(duplicates, ", ")}", 1}
    end
  end

  defp validate_required_headers(headers) do
    missing =
      ApiClientProvisioning.allowed_fields() |> Enum.take(4) |> Enum.reject(&(&1 in headers))

    case missing do
      [] -> :ok
      missing -> {:error, "Error: missing required CSV field(s): #{Enum.join(missing, ", ")}", 1}
    end
  end

  defp rows_to_maps(headers, data_rows) do
    data_rows
    |> Enum.with_index(2)
    |> Enum.reduce_while({:ok, []}, fn {row, row_number}, {:ok, acc} ->
      if length(row) == length(headers) do
        {:cont, {:ok, [headers |> Enum.zip(row) |> Map.new() | acc]}}
      else
        {:halt,
         {:error,
          "Error: row #{row_number} has #{length(row)} field(s), expected #{length(headers)}.", 1}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, message, exit_code} -> {:error, message, exit_code}
    end
  end

  defp execute_bulk(:dry_run, rows, csv, _output_path, opts) do
    case Governance.bulk_validate_api_clients(rows, provisioning_opts(csv, opts)) do
      {:ok, plan} -> {:ok, render_dry_run(plan, Keyword.get(opts, :json, false))}
      {:error, errors} -> {:error, format_validation_errors(errors), 1}
    end
  end

  defp execute_bulk(:apply, rows, csv, output_path, opts) do
    case Governance.bulk_apply_api_clients(rows, provisioning_opts(csv, opts)) do
      {:ok, result} ->
        case write_output(output_path, result.output_rows) do
          :ok ->
            {:ok, render_apply_success(result, output_path, Keyword.get(opts, :json, false))}

          {:error, reason} ->
            Governance.mark_provisioning_batch_output_failed(result.batch.id, %{
              "reason" => reason,
              "api_token_prefixes" => Enum.map(result.output_rows, & &1.api_token_prefix)
            })

            {:error,
             "Error: Apply succeeded but One-time Secret Output failed for batch #{result.batch.id}: #{reason}\nRotate or revoke these API Token prefixes: #{Enum.map_join(result.output_rows, ", ", & &1.api_token_prefix)}",
             1}
        end

      {:error, errors} when is_list(errors) ->
        {:error, format_validation_errors(errors), 1}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, "Error: Apply failed: #{inspect(changeset.errors)}", 1}

      {:error, reason} ->
        {:error, "Error: Apply failed: #{inspect(reason)}", 1}
    end
  end

  defp provisioning_opts(csv, opts) do
    [
      rotation: Keyword.get(opts, :rotation, false),
      input_sha256: csv.sha256,
      actor_type: "operator"
    ]
  end

  defp write_output(path, output_rows) do
    tmp_path =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive])}"
      )

    with :ok <- write_tmp_output(tmp_path, output_rows),
         :ok <- File.rename(tmp_path, path),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, :file.format_error(reason) |> to_string()}
    end
  end

  defp write_tmp_output(tmp_path, output_rows) do
    csv =
      [@output_headers]
      |> Kernel.++(Enum.map(output_rows, &output_values/1))
      |> NimbleCSV.RFC4180.dump_to_iodata()

    with {:ok, file} <- File.open(tmp_path, [:write, :exclusive, :binary]),
         :ok <- File.chmod(tmp_path, 0o600),
         :ok <- IO.binwrite(file, csv),
         :ok <- File.close(file) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp output_values(row) do
    Enum.map(@output_headers, fn header ->
      row |> Map.fetch!(String.to_existing_atom(header)) |> to_string_or_empty()
    end)
  end

  defp render_dry_run(plan, true) do
    Jason.encode!(%{
      mode: "dry_run",
      organization: plan.tenant.slug,
      row_count: length(plan.rows),
      rotation: plan.rotation?,
      counts: plan.counts
    })
  end

  defp render_dry_run(plan, false) do
    Enum.join(
      [
        "Dry run passed",
        "  Organization: #{plan.tenant.slug}",
        "  Rows: #{length(plan.rows)}",
        "  API Clients to create: #{plan.counts.api_clients_created_count}",
        "  API Clients to update: #{plan.counts.api_clients_updated_count}",
        "  API Tokens to create: #{plan.counts.api_tokens_created_count}",
        "  Rotation mode: #{if(plan.rotation?, do: "enabled", else: "disabled")}"
      ],
      "\n"
    )
  end

  defp render_apply_success(result, output_path, true) do
    Jason.encode!(%{
      mode: "apply",
      batch_id: result.batch.id,
      output_path: output_path,
      row_count: result.batch.row_count,
      api_clients_created_count: result.batch.api_clients_created_count,
      api_clients_updated_count: result.batch.api_clients_updated_count,
      api_tokens_created_count: result.batch.api_tokens_created_count,
      api_tokens_rotated_count: result.batch.api_tokens_rotated_count
    })
  end

  defp render_apply_success(result, output_path, false) do
    Enum.join(
      [
        "Apply complete",
        "  Provisioning Batch ID: #{result.batch.id}",
        "  One-time Secret Output: #{output_path}",
        "  Rows: #{result.batch.row_count}",
        "  API Clients created: #{result.batch.api_clients_created_count}",
        "  API Clients updated: #{result.batch.api_clients_updated_count}",
        "  API Tokens created: #{result.batch.api_tokens_created_count}",
        "  API Tokens rotated: #{result.batch.api_tokens_rotated_count}"
      ],
      "\n"
    )
  end

  defp format_validation_errors(errors) do
    lines =
      Enum.map(errors, fn %{row: row, field: field, message: message} ->
        location =
          [if(row, do: "row #{row}"), field]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")

        if location == "", do: "  - #{message}", else: "  - #{location}: #{message}"
      end)

    Enum.join(["Error: bulk provisioning validation failed:"] ++ lines, "\n")
  end

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(value), do: to_string(value)

  defp sha256(contents) do
    :sha256
    |> :crypto.hash(contents)
    |> Base.encode16(case: :lower)
  end

  defp group_usage do
    Enum.join(
      [
        "Usage: orchardctl api-clients <command>",
        "",
        "Commands:",
        "  bulk-provision  Validate or apply API Client provisioning from CSV"
      ],
      "\n"
    )
  end

  defp bulk_usage do
    Enum.join(
      [
        "Usage: orchardctl api-clients bulk-provision (--dry-run | --apply) --file <csv> [--output <csv>] [--rotation] [--json]",
        "",
        "Required CSV fields:",
        "  organization, api_client, owner_contact, key_name",
        "",
        "Optional CSV fields:",
        "  team, owner_name, external_ref, description, purpose, expires_at, metadata_json",
        "",
        "Options:",
        "  --dry-run       Validate input without mutating state or generating API Tokens",
        "  --apply         Commit all rows as one batch and write One-time Secret Output",
        "  --file <csv>    Input CSV path",
        "  --output <csv>  Output CSV path for One-time Secret Output; required with --apply",
        "  --rotation      Explicitly replace existing active API Tokens with the same name",
        "  --json          Emit machine-readable summary",
        "  --help          Show this help message"
      ],
      "\n"
    )
  end
end
