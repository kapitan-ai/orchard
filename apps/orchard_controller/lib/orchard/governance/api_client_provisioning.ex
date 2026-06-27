defmodule Orchard.Governance.ApiClientProvisioning do
  @moduledoc """
  Validation and apply orchestration for bulk API Client provisioning.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Orchard.Governance

  alias Orchard.Governance.{
    ApiKey,
    AuditLog,
    ProvisioningBatch,
    SecretField,
    ServiceAccount,
    Tenant
  }

  alias Orchard.Repo

  @required_fields ~w(organization api_client owner_contact key_name)
  @optional_fields ~w(team owner_name external_ref description purpose expires_at metadata_json)
  @allowed_fields @required_fields ++ @optional_fields

  @type validation_error :: %{
          row: pos_integer() | nil,
          field: String.t() | nil,
          message: String.t()
        }
  @type plan :: %{
          tenant: Tenant.t(),
          rows: [map()],
          counts: map(),
          rotation?: boolean(),
          input_sha256: String.t() | nil
        }

  @spec allowed_fields() :: [String.t()]
  def allowed_fields, do: @allowed_fields

  @spec validate([map()], keyword()) :: {:ok, plan()} | {:error, [validation_error()]}
  def validate(rows, opts \\ []) when is_list(rows) do
    rotation? = Keyword.get(opts, :rotation, false)
    input_sha256 = Keyword.get(opts, :input_sha256)

    with :ok <- validate_non_empty(rows),
         :ok <- validate_headers(rows),
         {:ok, normalized_rows} <- normalize_rows(rows),
         :ok <- validate_same_organization(normalized_rows),
         {:ok, tenant} <- fetch_tenant_by_slug(normalized_rows),
         :ok <- validate_duplicate_rows(normalized_rows),
         {:ok, planned_rows} <- plan_rows(tenant, normalized_rows, rotation?) do
      {:ok,
       %{
         tenant: tenant,
         rows: planned_rows,
         counts: count_plan(planned_rows, rotation?),
         rotation?: rotation?,
         input_sha256: input_sha256
       }}
    end
  end

  @spec apply([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def apply(rows, opts \\ []) when is_list(rows) do
    with {:ok, plan} <- validate(rows, opts) do
      apply_plan(plan, opts)
    end
  end

  @spec mark_output_failed(Ecto.UUID.t(), map()) ::
          {:ok, ProvisioningBatch.t()} | {:error, Changeset.t() | :provisioning_batch_not_found}
  def mark_output_failed(batch_id, error_summary) do
    with {:ok, batch_id} <- normalize_batch_id(batch_id),
         {:ok, batch} <- fetch_provisioning_batch(batch_id) do
      output_failed_transaction(batch, error_summary)
    else
      :error -> {:error, :provisioning_batch_not_found}
      {:error, :provisioning_batch_not_found} -> {:error, :provisioning_batch_not_found}
    end
  end

  defp validate_non_empty([]),
    do: {:error, [error(nil, nil, "CSV must contain at least one data row.")]}

  defp validate_non_empty(_rows), do: :ok

  defp validate_headers(rows) do
    rows
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.reduce([], fn header, errors ->
      cond do
        header not in @allowed_fields ->
          [error(nil, header, "Unknown CSV field #{header}.") | errors]

        SecretField.secret_field?(header) ->
          [
            error(nil, header, "CSV input must not include plaintext token or secret fields.")
            | errors
          ]

        true ->
          errors
      end
    end)
    |> case do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp normalize_rows(rows) do
    rows
    |> Enum.with_index(2)
    |> Enum.reduce_while({:ok, []}, fn {row, row_number}, {:ok, normalized} ->
      case normalize_row(row, row_number) do
        {:ok, row} -> {:cont, {:ok, [row | normalized]}}
        {:error, errors} -> {:halt, {:error, errors}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, errors} -> {:error, errors}
    end
  end

  defp normalize_row(row, row_number) do
    row = normalize_keys(row)

    errors =
      @required_fields
      |> Enum.filter(&blank?(Map.get(row, &1)))
      |> Enum.map(&error(row_number, &1, "is required."))

    with [] <- errors,
         {:ok, expires_at} <- parse_expires_at(row_number, Map.get(row, "expires_at")),
         {:ok, metadata} <- parse_metadata(row_number, Map.get(row, "metadata_json")) do
      {:ok,
       %{
         row_number: row_number,
         organization: required_string(row["organization"]),
         api_client: required_string(row["api_client"]),
         owner_contact: required_string(row["owner_contact"]),
         key_name: required_string(row["key_name"]),
         team: optional_string(row["team"]),
         owner_name: optional_string(row["owner_name"]),
         external_ref: optional_string(row["external_ref"]),
         description: optional_string(row["description"]),
         purpose: optional_string(row["purpose"]),
         expires_at: expires_at,
         metadata: metadata
       }}
    else
      [_ | _] = errors -> {:error, errors}
      {:error, errors} -> {:error, errors}
    end
  end

  defp validate_same_organization(rows) do
    case rows |> Enum.map(& &1.organization) |> Enum.uniq() do
      [_organization] ->
        :ok

      _organizations ->
        {:error, [error(nil, "organization", "All rows must target the same Organization.")]}
    end
  end

  defp fetch_tenant_by_slug([%{organization: slug} | _rows]) do
    case Repo.get_by(Tenant, slug: slug) do
      %Tenant{} = tenant -> {:ok, tenant}
      nil -> {:error, [error(nil, "organization", "Unknown Organization slug #{slug}.")]}
    end
  end

  defp validate_duplicate_rows(rows) do
    duplicates =
      rows
      |> Enum.group_by(fn row -> {row_identity(row), row.key_name} end)
      |> Enum.filter(fn {_key, grouped_rows} -> length(grouped_rows) > 1 end)
      |> Enum.flat_map(fn {{identity, key_name}, grouped_rows} ->
        Enum.map(grouped_rows, fn row ->
          error(
            row.row_number,
            "key_name",
            "Duplicate API Client/token pair #{identity}/#{key_name} in this file."
          )
        end)
      end)

    case duplicates do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp plan_rows(tenant, rows, rotation?) do
    rows
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn row, {:ok, planned_rows, seen_identities} ->
      case plan_row(tenant, row, rotation?, seen_identities) do
        {:ok, planned_row} ->
          seen_identities = MapSet.put(seen_identities, row_identity(row))
          {:cont, {:ok, [planned_row | planned_rows], seen_identities}}

        {:error, errors} ->
          {:halt, {:error, errors}}
      end
    end)
    |> case do
      {:ok, planned_rows, _seen_identities} -> {:ok, Enum.reverse(planned_rows)}
      {:error, errors} -> {:error, errors}
    end
  end

  defp plan_row(tenant, row, rotation?, seen_identities) do
    api_client = find_existing_api_client(tenant.id, row)

    cond do
      match?(%ServiceAccount{disabled_at: %DateTime{}}, api_client) ->
        {:error, [error(row.row_number, "api_client", "API Client is disabled.")]}

      duplicate_active_token?(api_client, row.key_name) and not rotation? ->
        {:error,
         [
           error(
             row.row_number,
             "key_name",
             "Active API Token name already exists. Use Key Rotation mode to replace it."
           )
         ]}

      true ->
        {:ok,
         row
         |> Map.put(:existing_api_client_id, existing_api_client_id(api_client))
         |> Map.put(:api_client_action, api_client_action(api_client, row, seen_identities))
         |> Map.put(:token_action, if(rotation?, do: :rotated, else: :created))}
    end
  end

  defp apply_plan(plan, opts) do
    Repo.transaction(fn ->
      with {:ok, batch} <- insert_batch(plan, opts),
           {:ok, _audit_log} <- insert_batch_audit_log(batch, "provisioning_batch.started", %{}),
           {:ok, result} <- apply_rows(plan, batch, opts),
           result = order_output_rows(result),
           {:ok, batch} <- complete_batch(batch, plan, result),
           {:ok, _audit_log} <-
             insert_batch_audit_log(batch, "provisioning_batch.applied", batch_counts(batch)) do
        {:ok, Map.put(result, :batch, batch)}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:ok, result}} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_batch(plan, opts) do
    now = utc_now()

    %ProvisioningBatch{}
    |> ProvisioningBatch.changeset(%{
      tenant_id: plan.tenant.id,
      actor_type: Keyword.get(opts, :actor_type, "operator"),
      actor_id: Keyword.get(opts, :actor_id),
      status: :applying,
      row_count: length(plan.rows),
      input_sha256: plan.input_sha256,
      started_at: now
    })
    |> Repo.insert()
  end

  defp apply_rows(plan, batch, opts) do
    Enum.reduce_while(plan.rows, {:ok, empty_apply_result()}, fn row, {:ok, result} ->
      case apply_row(plan.tenant, row, batch, opts) do
        {:ok, output_row, row_result} ->
          {:cont, {:ok, merge_apply_result(result, output_row, row_result)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_row(tenant, row, batch, opts) do
    audit_opts = Keyword.merge(opts, provisioning_batch_id: batch.id)

    with {:ok, api_client} <-
           Governance.upsert_api_client(tenant, api_client_attrs(row), audit_opts),
         {:ok, _role_binding} <-
           Governance.ensure_inference_client_access(api_client, tenant, audit_opts),
         {:ok, token_result} <- create_or_rotate_token(api_client, row, audit_opts) do
      {:ok, output_row(tenant, api_client, row, token_result),
       row_apply_result(row, token_result)}
    end
  end

  defp create_or_rotate_token(api_client, %{token_action: :rotated} = row, opts) do
    Governance.rotate_api_client_api_token(api_client, token_attrs(row), opts)
  end

  defp create_or_rotate_token(api_client, row, opts) do
    Governance.create_api_client_api_token(api_client, token_attrs(row), opts)
  end

  defp complete_batch(batch, plan, result) do
    batch
    |> ProvisioningBatch.changeset(%{
      status: :applied,
      row_count: length(plan.rows),
      api_clients_created_count: result.api_clients_created_count,
      api_clients_updated_count: result.api_clients_updated_count,
      api_tokens_created_count: result.api_tokens_created_count,
      api_tokens_rotated_count: result.api_tokens_rotated_count,
      api_tokens_revoked_count: result.api_tokens_revoked_count,
      completed_at: utc_now()
    })
    |> Repo.update()
  end

  defp output_failed_batch(batch, error_summary) do
    batch
    |> ProvisioningBatch.changeset(%{
      status: :output_failed,
      error_summary: sanitize_error_summary(error_summary),
      completed_at: utc_now()
    })
    |> Repo.update()
  end

  defp output_failed_transaction(batch, error_summary) do
    Repo.transaction(fn -> update_output_failed_batch(batch, error_summary) end)
    |> case do
      {:ok, %ProvisioningBatch{} = batch} -> {:ok, batch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_output_failed_batch(batch, error_summary) do
    with {:ok, batch} <- output_failed_batch(batch, error_summary),
         {:ok, _audit_log} <-
           insert_batch_audit_log(batch, "provisioning_batch.output_failed", %{
             "error_summary" => batch.error_summary
           }) do
      batch
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_batch_audit_log(batch, action, payload) do
    %AuditLog{}
    |> AuditLog.changeset(%{
      tenant_id: batch.tenant_id,
      api_key_id: nil,
      actor_type: batch.actor_type,
      actor_id: batch.actor_id,
      action: action,
      target_type: "provisioning_batch",
      target_id: batch.id,
      occurred_at: utc_now(),
      payload:
        %{"row_count" => batch.row_count}
        |> Map.merge(payload)
        |> sanitize_error_summary()
    })
    |> Repo.insert()
  end

  defp count_plan(rows, rotation?) do
    %{
      api_clients_created_count: Enum.count(rows, &(&1.api_client_action == :created)),
      api_clients_updated_count: Enum.count(rows, &(&1.api_client_action == :updated)),
      api_tokens_created_count: length(rows),
      api_tokens_rotated_count: if(rotation?, do: length(rows), else: 0)
    }
  end

  defp empty_apply_result do
    %{
      output_rows: [],
      api_clients_created_count: 0,
      api_clients_updated_count: 0,
      api_tokens_created_count: 0,
      api_tokens_rotated_count: 0,
      api_tokens_revoked_count: 0
    }
  end

  defp merge_apply_result(result, output_row, row_result) do
    result
    |> Map.update!(:output_rows, &[output_row | &1])
    |> increment(:api_clients_created_count, row_result.api_client_created?)
    |> increment(:api_clients_updated_count, row_result.api_client_updated?)
    |> increment(:api_tokens_created_count, true)
    |> increment(:api_tokens_rotated_count, row_result.rotated?)
    |> Map.update!(:api_tokens_revoked_count, &(&1 + row_result.revoked_count))
  end

  defp order_output_rows(result), do: Map.update!(result, :output_rows, &Enum.reverse/1)

  defp row_apply_result(row, token_result) do
    %{
      api_client_created?: row.api_client_action == :created,
      api_client_updated?: row.api_client_action == :updated,
      rotated?: row.token_action == :rotated,
      revoked_count: token_result |> Map.get(:revoked_api_keys, []) |> length()
    }
  end

  defp increment(result, key, true), do: Map.update!(result, key, &(&1 + 1))
  defp increment(result, _key, false), do: result

  defp output_row(tenant, api_client, row, %{api_key: api_key, token: token}) do
    %{
      organization: tenant.slug,
      api_client: api_client.name,
      external_ref: row.external_ref,
      key_name: api_key.name,
      api_token_id: api_key.id,
      api_token_prefix: api_key.token_prefix,
      api_token: token,
      expires_at: maybe_iso8601(api_key.expires_at)
    }
  end

  defp api_client_attrs(row) do
    %{
      name: row.api_client,
      owner_contact: row.owner_contact,
      owner_name: row.owner_name,
      team: row.team,
      external_ref: row.external_ref,
      description: row.description,
      purpose: row.purpose,
      metadata: row.metadata
    }
  end

  defp token_attrs(row), do: %{name: row.key_name, expires_at: row.expires_at}

  defp find_existing_api_client(tenant_id, %{external_ref: external_ref})
       when is_binary(external_ref) do
    Repo.get_by(ServiceAccount, tenant_id: tenant_id, external_ref: external_ref)
  end

  defp find_existing_api_client(tenant_id, %{api_client: name}) do
    Repo.get_by(ServiceAccount, tenant_id: tenant_id, name: name)
  end

  defp duplicate_active_token?(nil, _key_name), do: false

  defp duplicate_active_token?(%ServiceAccount{} = api_client, key_name) do
    ApiKey
    |> where([api_key], api_key.service_account_id == ^api_client.id)
    |> where([api_key], api_key.name == ^key_name)
    |> where([api_key], is_nil(api_key.revoked_at))
    |> Repo.exists?()
  end

  defp existing_api_client_id(nil), do: nil
  defp existing_api_client_id(%ServiceAccount{id: id}), do: id

  defp api_client_action(%ServiceAccount{}, _row, _seen_identities), do: :updated

  defp api_client_action(nil, row, seen_identities) do
    if MapSet.member?(seen_identities, row_identity(row)), do: :updated, else: :created
  end

  defp row_identity(%{external_ref: external_ref}) when is_binary(external_ref),
    do: "external_ref:#{external_ref}"

  defp row_identity(%{api_client: api_client}), do: "api_client:#{api_client}"

  defp parse_expires_at(_row_number, value) when value in [nil, ""], do: {:ok, nil}

  defp parse_expires_at(row_number, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, DateTime.truncate(datetime, :microsecond)}

      {:error, _reason} ->
        {:error, [error(row_number, "expires_at", "must be an ISO8601 datetime.")]}
    end
  end

  defp parse_metadata(_row_number, value) when value in [nil, ""], do: {:ok, %{}}

  defp parse_metadata(row_number, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, metadata} when is_map(metadata) ->
        if SecretField.contains_secret_field?(metadata) do
          {:error,
           [
             error(
               row_number,
               "metadata_json",
               "must not include plaintext token or secret fields."
             )
           ]}
        else
          {:ok, metadata}
        end

      {:ok, _value} ->
        {:error, [error(row_number, "metadata_json", "must be a JSON object.")]}

      {:error, _reason} ->
        {:error, [error(row_number, "metadata_json", "must be valid JSON.")]}
    end
  end

  defp normalize_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp required_string(value), do: value |> to_string() |> String.trim()

  defp optional_string(nil), do: nil

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp batch_counts(batch) do
    %{
      "api_clients_created_count" => batch.api_clients_created_count,
      "api_clients_updated_count" => batch.api_clients_updated_count,
      "api_tokens_created_count" => batch.api_tokens_created_count,
      "api_tokens_rotated_count" => batch.api_tokens_rotated_count,
      "api_tokens_revoked_count" => batch.api_tokens_revoked_count
    }
  end

  defp sanitize_error_summary(summary) when is_map(summary) do
    summary
    |> SecretField.reject_secret_fields()
    |> Map.delete("raw_csv")
    |> Map.delete(:raw_csv)
  end

  defp sanitize_error_summary(_summary), do: %{}

  defp fetch_provisioning_batch(batch_id) do
    case Repo.get(ProvisioningBatch, batch_id) do
      %ProvisioningBatch{} = batch -> {:ok, batch}
      nil -> {:error, :provisioning_batch_not_found}
    end
  end

  defp normalize_batch_id(batch_id), do: Ecto.UUID.cast(batch_id)

  defp maybe_iso8601(nil), do: nil
  defp maybe_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp error(row, field, message), do: %{row: row, field: field, message: message}

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
