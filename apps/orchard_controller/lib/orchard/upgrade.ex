defmodule Orchard.Upgrade do
  @moduledoc """
  Controller-side upgrade preflight planning.

  `plan/1` evaluates the SPEC 13.7 safety checks used before manual package
  replacement. It is read-only and returns JSON-encodable data for CLI and
  operator tooling.
  """

  alias Orchard.BuildInfo
  alias Orchard.Nodes
  alias Orchard.Release
  alias Orchard.Requests

  @check_order [
    :backup_manifest,
    :database_reachable,
    :database_lockable,
    :migrations_current,
    :request_activity,
    :draining_nodes,
    :decommissioning_nodes,
    :node_agent_versions
  ]

  @status_counts ["ok", "warning", "blocked", "config_error", "unreachable"]

  @type plan_option ::
          {:backup_manifest_path, Path.t()}
          | {:queue_tolerance, non_neg_integer()}
          | {:release_impl, module()}
          | {:requests_impl, module()}
          | {:nodes_impl, module()}
          | {:controller_version, String.t()}

  @type check :: %{
          id: String.t(),
          status: String.t(),
          summary: String.t(),
          detail: String.t(),
          remediation: String.t() | nil,
          data: map()
        }

  @type plan :: %{
          status: String.t(),
          exit_code: 0 | 1 | 2 | 3,
          checked_at: String.t(),
          controller: map(),
          policy: map(),
          summary: map(),
          checks: [check()]
        }

  @spec plan([plan_option()]) :: plan()
  def plan(opts \\ []) do
    context = build_context(opts)
    checks = Enum.map(@check_order, &run_check(&1, context))
    status = aggregate_status(checks)

    %{
      status: status,
      exit_code: exit_code(status),
      checked_at: checked_at(),
      controller: controller_info(context),
      policy: policy_info(context),
      summary: summarize_checks(checks),
      checks: checks
    }
  end

  defp build_context(opts) do
    configured = upgrade_preflight_config()
    release_impl = Keyword.get(opts, :release_impl, Release)

    %{
      backup_manifest_path:
        Keyword.get(opts, :backup_manifest_path, default_backup_manifest_path(configured)),
      queue_tolerance: Keyword.get(opts, :queue_tolerance, default_queue_tolerance(configured)),
      release_impl: release_impl,
      postgres_reachable: postgres_reachable(release_impl),
      requests_impl: Keyword.get(opts, :requests_impl, Requests),
      nodes_impl: Keyword.get(opts, :nodes_impl, Nodes),
      controller_version: Keyword.get(opts, :controller_version, Orchard.version())
    }
  end

  defp postgres_reachable(release_impl) do
    cond do
      not db_checks_enabled?(:database_reachable) -> {:error, :database_checks_disabled}
      not start_repo?() -> {:error, :repo_not_started}
      true -> {:ok, release_impl.postgres_reachable?()}
    end
  rescue
    error -> {:error, error}
  end

  defp run_check(:backup_manifest, context), do: backup_manifest_check(context)
  defp run_check(:database_reachable, context), do: database_reachable_check(context)
  defp run_check(:database_lockable, context), do: database_lockable_check(context)
  defp run_check(:migrations_current, context), do: migrations_current_check(context)
  defp run_check(:request_activity, context), do: request_activity_check(context)
  defp run_check(:draining_nodes, context), do: node_state_check(context, :draining)
  defp run_check(:decommissioning_nodes, context), do: node_state_check(context, :decommissioning)
  defp run_check(:node_agent_versions, context), do: node_agent_versions_check(context)

  defp backup_manifest_check(%{backup_manifest_path: path}) when is_binary(path) and path != "" do
    case File.read(path) do
      {:ok, body} ->
        validate_backup_manifest_json(path, body)

      {:error, :enoent} ->
        check(
          :backup_manifest,
          "blocked",
          "Backup manifest is missing.",
          "No backup manifest exists at #{path}.",
          "Create a backup manifest before planning the upgrade.",
          %{path: path}
        )

      {:error, reason} ->
        check(
          :backup_manifest,
          "config_error",
          "Backup manifest is not readable.",
          "Could not read #{path}: #{format_reason(reason)}.",
          "Fix the backup manifest path or file permissions.",
          %{path: path, reason: format_reason(reason)}
        )
    end
  end

  defp backup_manifest_check(%{backup_manifest_path: path}) do
    check(
      :backup_manifest,
      "config_error",
      "Backup manifest path is invalid.",
      "Expected a non-empty backup manifest path, got #{inspect(path)}.",
      "Configure a valid backup manifest path.",
      %{path: json_value(path)}
    )
  end

  defp validate_backup_manifest_json(path, body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} ->
        validate_backup_manifest_shape(path, body, decoded)

      {:ok, _decoded} ->
        backup_manifest_shape_error(path, "manifest JSON must be an object")

      {:error, error} ->
        check(
          :backup_manifest,
          "config_error",
          "Backup manifest is malformed.",
          "Backup manifest at #{path} is not valid JSON: #{Exception.message(error)}.",
          "Regenerate the backup manifest with valid JSON.",
          %{path: path, reason: Exception.message(error)}
        )
    end
  end

  defp validate_backup_manifest_shape(path, body, decoded) do
    if Map.has_key?(decoded, "schema_version") and Map.has_key?(decoded, "created_at") do
      check(
        :backup_manifest,
        "ok",
        "Backup manifest exists.",
        "Backup manifest at #{path} has the required manifest fields.",
        nil,
        %{path: path, size_bytes: byte_size(body)}
      )
    else
      backup_manifest_shape_error(
        path,
        "manifest JSON must include schema_version and created_at"
      )
    end
  end

  defp backup_manifest_shape_error(path, reason) do
    check(
      :backup_manifest,
      "config_error",
      "Backup manifest shape is invalid.",
      "Backup manifest at #{path} is not a valid upgrade manifest: #{reason}.",
      "Regenerate the backup manifest with the required fields.",
      %{path: path, reason: reason}
    )
  end

  defp database_reachable_check(%{postgres_reachable: {:error, :database_checks_disabled}}) do
    check_db_config_error("Database checks are disabled.", ":enable_db_checks is false.")
  end

  defp database_reachable_check(%{postgres_reachable: {:error, :repo_not_started}}) do
    check_db_config_error("Repo startup is disabled.", ":start_repo is false.")
  end

  defp database_reachable_check(%{postgres_reachable: {:error, reason}}) do
    check(
      :database_reachable,
      "unreachable",
      "Postgres reachability check failed.",
      "The reachability probe failed: #{format_reason(reason)}.",
      "Verify controller database configuration and Postgres availability.",
      %{reason: format_reason(reason)}
    )
  end

  defp database_reachable_check(%{postgres_reachable: {:ok, true}}) do
    check(
      :database_reachable,
      "ok",
      "Postgres is reachable.",
      "The controller can connect to Postgres.",
      nil
    )
  end

  defp database_reachable_check(%{postgres_reachable: {:ok, false}}) do
    check(
      :database_reachable,
      "unreachable",
      "Postgres is unreachable.",
      "The controller could not connect to Postgres.",
      "Start Postgres and verify controller database configuration."
    )
  end

  defp check_db_config_error(summary, detail) do
    check(
      :database_reachable,
      "config_error",
      summary,
      detail,
      "Enable controller DB checks and Repo startup before running upgrade preflight."
    )
  end

  defp database_lockable_check(context) do
    case context.release_impl.migration_lockable?() do
      {:ok, :locked} ->
        check(
          :database_lockable,
          "ok",
          "Migration advisory lock is available.",
          "The migration advisory lock can be acquired and released.",
          nil,
          %{lock_key: Release.migration_advisory_lock_key()}
        )

      {:error, :locked_by_other} ->
        check(
          :database_lockable,
          "blocked",
          "Migration advisory lock is held by another process.",
          "Another process currently holds the upgrade/migration advisory lock.",
          "Wait for migrations or upgrade work to finish, then retry.",
          %{lock_key: Release.migration_advisory_lock_key()}
        )

      {:error, reason} when reason in [:database_checks_disabled, :repo_not_started] ->
        check(
          :database_lockable,
          "config_error",
          "Migration lock check is not configured.",
          "The lock probe cannot run because #{format_reason(reason)}.",
          "Enable controller DB checks and Repo startup before running upgrade preflight.",
          %{reason: format_reason(reason)}
        )

      {:error, reason} ->
        check(
          :database_lockable,
          "unreachable",
          "Migration advisory lock check failed.",
          "The lock probe failed: #{format_reason(reason)}.",
          "Verify Postgres availability and retry.",
          %{reason: format_reason(reason)}
        )
    end
  rescue
    error ->
      check(
        :database_lockable,
        "unreachable",
        "Migration advisory lock check failed.",
        "The lock probe raised: #{format_reason(error)}.",
        "Verify Postgres availability and retry.",
        %{reason: format_reason(error)}
      )
  end

  defp migrations_current_check(%{postgres_reachable: {:error, reason}})
       when reason in [:database_checks_disabled, :repo_not_started] do
    check(
      :migrations_current,
      "config_error",
      "Migration status check is not configured.",
      "Migration status requires enabled DB checks and Repo startup.",
      "Enable controller DB checks and Repo startup before running upgrade preflight.",
      %{reason: format_reason(reason)}
    )
  end

  defp migrations_current_check(%{postgres_reachable: {:error, reason}}) do
    check(
      :migrations_current,
      "unreachable",
      "Database migration status check failed.",
      "The migration status probe failed: #{format_reason(reason)}.",
      "Verify Postgres availability and retry.",
      %{reason: format_reason(reason)}
    )
  end

  defp migrations_current_check(context) do
    evaluate_migration_status(context.release_impl, elem(context.postgres_reachable, 1))
  rescue
    error ->
      check(
        :migrations_current,
        "unreachable",
        "Database migration status check failed.",
        "The migration status probe failed: #{format_reason(error)}.",
        "Verify Postgres availability and retry.",
        %{reason: format_reason(error)}
      )
  end

  defp evaluate_migration_status(release_impl, true) do
    case migration_status(release_impl) do
      {:ok, :current} ->
        check(
          :migrations_current,
          "ok",
          "Database migrations are current.",
          "All configured controller migrations are up.",
          nil
        )

      {:ok, :pending} ->
        check(
          :migrations_current,
          "blocked",
          "Database migrations are pending.",
          "Postgres is reachable, but one or more migrations are not current.",
          "Run controller migrations before upgrading."
        )

      {:error, reason} ->
        check(
          :migrations_current,
          "unreachable",
          "Database migration status check failed.",
          "The migration status probe failed: #{format_reason(reason)}.",
          "Verify Postgres availability and retry.",
          %{reason: format_reason(reason)}
        )
    end
  end

  defp evaluate_migration_status(_release_impl, false) do
    check(
      :migrations_current,
      "unreachable",
      "Database migration status is unavailable.",
      "Postgres is unreachable, so migration status cannot be verified.",
      "Restore Postgres connectivity and retry."
    )
  end

  defp migration_status(release_impl) do
    if function_exported?(release_impl, :migration_status, 0) do
      release_impl.migration_status()
    else
      legacy_migration_status(release_impl.migrations_current?())
    end
  end

  defp legacy_migration_status(true), do: {:ok, :current}
  defp legacy_migration_status(false), do: {:ok, :pending}

  defp request_activity_check(%{queue_tolerance: tolerance} = context) do
    cond do
      not valid_queue_tolerance?(tolerance) ->
        check(
          :request_activity,
          "config_error",
          "Queue tolerance is invalid.",
          "Expected queue_tolerance to be an integer >= 0, got #{inspect(tolerance)}.",
          "Configure ORCHARD_UPGRADE_QUEUE_TOLERANCE as a non-negative integer.",
          %{queue_tolerance: json_value(tolerance)}
        )

      not db_checks_enabled?(:request_activity) ->
        request_activity_config_error("Request activity requires :enable_db_checks to be true.")

      not start_repo?() ->
        request_activity_config_error("Request activity requires :start_repo to be true.")

      true ->
        evaluate_request_summary(context.requests_impl.summary(), tolerance)
    end
  rescue
    error -> request_activity_unreachable(error)
  end

  defp evaluate_request_summary({:error, reason}, _tolerance),
    do: request_activity_unreachable(reason)

  defp evaluate_request_summary(summary, tolerance) when is_map(summary) do
    evaluate_request_activity(summary, tolerance)
  end

  defp evaluate_request_summary(summary, _tolerance) do
    request_activity_unreachable({:unexpected_request_summary, summary})
  end

  defp request_activity_config_error(detail) do
    check(
      :request_activity,
      "config_error",
      "Request activity check is not configured.",
      detail,
      "Enable controller DB checks and Repo startup before running upgrade preflight."
    )
  end

  defp request_activity_unreachable(reason) do
    check(
      :request_activity,
      "unreachable",
      "Request activity check failed.",
      "Request summary could not be loaded: #{format_reason(reason)}.",
      "Verify Postgres availability and retry.",
      %{reason: format_reason(reason)}
    )
  end

  defp evaluate_request_activity(summary, tolerance) do
    queued = get_in(summary, [:by_state, :queued]) || 0
    active = Map.get(summary, :active, 0)
    active_nonqueued = max(active - queued, 0)

    if queued <= tolerance and active_nonqueued == 0 do
      check(
        :request_activity,
        "ok",
        "Request activity is within tolerance.",
        "Queued requests are within tolerance and no non-queued requests are active.",
        nil,
        request_activity_data(queued, active_nonqueued, summary, tolerance)
      )
    else
      check(
        :request_activity,
        "blocked",
        "Requests are still active.",
        "Queued requests or active non-queued requests exceed upgrade tolerance.",
        "Wait for active requests to finish or drain traffic before upgrading.",
        request_activity_data(queued, active_nonqueued, summary, tolerance)
      )
    end
  end

  defp request_activity_data(queued, active_nonqueued, summary, tolerance) do
    %{
      queued: queued,
      active_nonqueued: active_nonqueued,
      active: Map.get(summary, :active, 0),
      total: Map.get(summary, :total, 0),
      queue_tolerance: tolerance
    }
  end

  defp node_state_check(context, state) do
    id = node_state_check_id(state)

    case list_upgrade_nodes(context.nodes_impl) do
      {:ok, nodes} -> evaluate_node_state(nodes, state, id)
      {:error, :config_error} -> node_inventory_config_error(id)
      {:error, reason} -> node_inventory_unreachable(id, reason)
    end
  rescue
    error -> node_inventory_unreachable(node_state_check_id(state), error)
  end

  defp evaluate_node_state(nodes, state, id) do
    matching_nodes = Enum.filter(nodes, &(&1.state == state))

    if matching_nodes == [] do
      check(
        id,
        "ok",
        "No #{state} nodes found.",
        "No nodes are currently in #{state} state.",
        nil,
        %{count: 0, nodes: []}
      )
    else
      check(
        id,
        "blocked",
        "Nodes are #{state}.",
        "One or more nodes are in #{state} state.",
        "Finish node #{state} work before upgrading.",
        %{count: length(matching_nodes), nodes: node_refs(matching_nodes)}
      )
    end
  end

  defp node_state_check_id(:draining), do: :draining_nodes
  defp node_state_check_id(:decommissioning), do: :decommissioning_nodes

  defp node_agent_versions_check(context) do
    case list_upgrade_nodes(context.nodes_impl) do
      {:ok, nodes} -> evaluate_node_agent_versions(nodes, context.controller_version)
      {:error, :config_error} -> node_inventory_config_error(:node_agent_versions)
      {:error, reason} -> node_inventory_unreachable(:node_agent_versions, reason)
    end
  rescue
    error -> node_inventory_unreachable(:node_agent_versions, error)
  end

  defp evaluate_node_agent_versions([], controller_version) do
    check(
      :node_agent_versions,
      "warning",
      "No node agents are registered.",
      "No node agent versions were available to compare against controller #{controller_version}.",
      "Register at least one node agent before production upgrades.",
      %{controller_version: controller_version, nodes: []}
    )
  end

  defp evaluate_node_agent_versions(nodes, controller_version) do
    case Version.parse(controller_version) do
      {:ok, controller_semver} ->
        classify_node_versions(nodes, controller_version, controller_semver)

      :error ->
        blocked_node_agent_versions(
          controller_version,
          [],
          Enum.map(nodes, &version_issue(&1, "controller_version_unparseable")),
          "Controller version is not semver-compatible."
        )
    end
  end

  defp classify_node_versions(nodes, controller_version, controller_semver) do
    classifications = Enum.map(nodes, &classify_node_version(&1, controller_semver))
    compatible = classifications |> Enum.filter(&match?(%{status: "ok"}, &1))
    incompatible = classifications -- compatible

    if incompatible == [] do
      check(
        :node_agent_versions,
        "ok",
        "Node agent versions are compatible.",
        "All registered node agents are at controller minor N or N-1.",
        nil,
        %{
          controller_version: controller_version,
          compatible_nodes: compatible,
          incompatible_nodes: []
        }
      )
    else
      blocked_node_agent_versions(
        controller_version,
        compatible,
        incompatible,
        "One or more node agent versions are incompatible."
      )
    end
  end

  defp blocked_node_agent_versions(controller_version, compatible, incompatible, summary) do
    check(
      :node_agent_versions,
      "blocked",
      summary,
      "Node agents must match the controller major version and be at minor N or N-1.",
      "Upgrade or remove incompatible node agents before upgrading the controller.",
      %{
        controller_version: controller_version,
        compatible_nodes: compatible,
        incompatible_nodes: incompatible
      }
    )
  end

  defp classify_node_version(node, controller_semver) do
    case Version.parse(node.agent_version || "") do
      {:ok, node_semver} ->
        if compatible_version?(controller_semver, node_semver) do
          version_issue(node, nil, "ok")
        else
          version_issue(node, "incompatible")
        end

      :error ->
        version_issue(node, "missing_or_unparseable")
    end
  end

  defp compatible_version?(controller, node) do
    controller.major == node.major and node.minor in compatible_minor_versions(controller.minor)
  end

  defp compatible_minor_versions(0), do: [0]
  defp compatible_minor_versions(minor), do: [minor, minor - 1]

  defp version_issue(node, reason, status \\ "blocked") do
    %{
      id: node.id,
      display_name: node.display_name,
      agent_version: node.agent_version,
      status: status,
      reason: reason
    }
  end

  defp list_upgrade_nodes(nodes_impl) do
    cond do
      not db_checks_enabled?(:node_inventory) ->
        {:error, :config_error}

      not start_repo?() ->
        {:error, :config_error}

      function_exported?(nodes_impl, :list_nodes_for_upgrade!, 0) ->
        nodes_impl.list_nodes_for_upgrade!()
        |> normalize_node_inventory_result()

      true ->
        nodes_impl.list_nodes()
        |> normalize_node_inventory_result()
    end
  rescue
    error -> {:error, error}
  end

  defp normalize_node_inventory_result({:error, reason}), do: {:error, reason}
  defp normalize_node_inventory_result(nodes) when is_list(nodes), do: {:ok, nodes}

  defp normalize_node_inventory_result(result) do
    {:error, {:unexpected_node_inventory, result}}
  end

  defp node_inventory_config_error(id) do
    check(
      id,
      "config_error",
      "Node inventory check is not configured.",
      "Node inventory requires enabled DB checks and Repo startup.",
      "Enable controller DB checks and Repo startup before running upgrade preflight."
    )
  end

  defp node_inventory_unreachable(:node_agent_versions, reason) do
    check(
      :node_agent_versions,
      "unreachable",
      "Node version check failed.",
      "Node inventory could not be loaded: #{format_reason(reason)}.",
      "Verify Postgres availability and retry.",
      %{reason: format_reason(reason)}
    )
  end

  defp node_inventory_unreachable(id, reason) do
    check(
      id,
      "unreachable",
      "Node inventory check failed.",
      "Node inventory could not be loaded: #{format_reason(reason)}.",
      "Verify Postgres availability and retry.",
      %{reason: format_reason(reason)}
    )
  end

  defp node_refs(nodes) do
    Enum.map(nodes, fn node ->
      %{
        id: node.id,
        display_name: node.display_name,
        state: Atom.to_string(node.state)
      }
    end)
  end

  defp aggregate_status(checks) do
    statuses = Enum.map(checks, & &1.status)

    cond do
      "config_error" in statuses -> "config_error"
      "unreachable" in statuses -> "unreachable"
      "blocked" in statuses -> "unsafe"
      true -> "safe"
    end
  end

  defp exit_code("safe"), do: 0
  defp exit_code("unsafe"), do: 1
  defp exit_code("config_error"), do: 2
  defp exit_code("unreachable"), do: 3

  defp summarize_checks(checks) do
    Map.new(@status_counts, fn status ->
      {String.to_atom(status), count_status(checks, status)}
    end)
  end

  defp count_status(checks, status) do
    Enum.count(checks, &(&1.status == status))
  end

  defp controller_info(context) do
    %{
      version: context.controller_version,
      build_ref: BuildInfo.git_sha(),
      build_date: BuildInfo.build_date()
    }
  end

  defp policy_info(context) do
    %{
      backup_manifest_path: json_value(context.backup_manifest_path),
      queue_tolerance: json_value(context.queue_tolerance)
    }
  end

  defp check(id, status, summary, detail, remediation, data \\ %{}) do
    %{
      id: Atom.to_string(id),
      status: status,
      summary: summary,
      detail: detail,
      remediation: remediation,
      data: data
    }
  end

  defp checked_at do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp default_backup_manifest_path(configured) do
    Keyword.get_lazy(configured, :backup_manifest_path, fn ->
      support_root =
        System.get_env("ORCHARD_SUPPORT_ROOT") || "/Library/Application Support/Orchard"

      Path.join([support_root, "support", "upgrade-backup.json"])
    end)
  end

  defp default_queue_tolerance(configured), do: Keyword.get(configured, :queue_tolerance, 0)

  defp upgrade_preflight_config do
    Application.get_env(:orchard_controller, :upgrade_preflight, [])
  end

  defp valid_queue_tolerance?(value), do: is_integer(value) and value >= 0

  defp db_checks_enabled?(_check_id) do
    Application.get_env(:orchard_controller, :enable_db_checks, true)
  end

  defp start_repo? do
    Application.get_env(:orchard_controller, :start_repo, true)
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(%{__exception__: true} = error), do: Exception.message(error)
  defp format_reason(reason), do: inspect(reason)

  defp json_value(nil), do: nil
  defp json_value(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value), do: inspect(value)
end
