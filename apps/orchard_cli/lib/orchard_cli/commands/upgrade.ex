defmodule OrchardCLI.Commands.Upgrade do
  @moduledoc false

  @usage_exit_code 2

  @type runtime :: %{
          optional(:plan) => ([Orchard.Upgrade.plan_option()] -> Orchard.Upgrade.plan()),
          optional(:encode_json) => (map() -> String.t())
        }

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  @spec run([String.t()], runtime()) :: OrchardCLI.command_result()
  def run([], _runtime), do: {:ok, group_usage()}
  def run(["help"], _runtime), do: {:ok, group_usage()}
  def run(["--help"], _runtime), do: {:ok, group_usage()}
  def run(["plan" | rest], runtime), do: run_plan(rest, runtime)

  def run([arg | _rest], _runtime) do
    if option?(arg) do
      usage_error("Unknown option: #{arg}", group_usage())
    else
      usage_error("Unknown upgrade subcommand: #{arg}", group_usage())
    end
  end

  defp run_plan(args, runtime) do
    case parse_plan_args(args, %{json?: false}) do
      {:run, opts} -> execute_plan(opts, runtime)
      :help -> {:ok, plan_usage()}
      {:error, message} -> usage_error(message, plan_usage())
    end
  end

  defp parse_plan_args([], opts), do: {:run, opts}
  defp parse_plan_args(["--json" | rest], opts), do: parse_plan_args(rest, %{opts | json?: true})
  defp parse_plan_args(["--help"], _opts), do: :help
  defp parse_plan_args(["help"], _opts), do: :help

  defp parse_plan_args([arg | _rest], _opts) do
    if option?(arg) do
      {:error, "Unknown option: #{arg}"}
    else
      {:error, "Unexpected argument for upgrade plan: #{arg}"}
    end
  end

  defp execute_plan(%{json?: true}, runtime) do
    plan = runtime.plan.([])
    plan |> runtime.encode_json.() |> result_tuple(exit_code(plan))
  end

  defp execute_plan(%{json?: false}, runtime) do
    plan = runtime.plan.([])
    plan |> render_plan() |> result_tuple(exit_code(plan))
  end

  defp result_tuple(message, 0), do: {:ok, message}
  defp result_tuple(message, exit_code), do: {:error, message, exit_code}

  defp render_plan(plan) do
    sections = [
      render_header(plan),
      render_summary(plan),
      render_checks(field(plan, :checks) || []),
      render_remediations(field(plan, :checks) || [])
    ]

    sections
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp render_header(plan) do
    controller = field(plan, :controller) || %{}
    policy = field(plan, :policy) || %{}

    [
      "orchardctl upgrade plan",
      "Status: #{field(plan, :status)}",
      "Exit code: #{exit_code(plan)}",
      "Checked at: #{field(plan, :checked_at)}",
      "Controller: #{controller_version(controller)}",
      "Backup manifest: #{field(policy, :backup_manifest_path)}",
      "Queue tolerance: #{field(policy, :queue_tolerance)}"
    ]
    |> Enum.join("\n")
  end

  defp controller_version(controller) do
    version = field(controller, :version) || "unknown"

    case field(controller, :build_ref) do
      nil -> version
      "" -> version
      build_ref -> "#{version} (#{build_ref})"
    end
  end

  defp render_summary(plan) do
    summary = field(plan, :summary) || %{}

    [
      "Summary:",
      "  ok: #{summary_count(summary, :ok)}",
      "  warning: #{summary_count(summary, :warning)}",
      "  blocked: #{summary_count(summary, :blocked)}",
      "  config_error: #{summary_count(summary, :config_error)}",
      "  unreachable: #{summary_count(summary, :unreachable)}"
    ]
    |> Enum.join("\n")
  end

  defp render_checks(checks) do
    lines = Enum.flat_map(checks, &render_check/1)
    Enum.join(["Checks:" | lines], "\n")
  end

  defp render_check(check) do
    status = field(check, :status) || "unknown"
    id = field(check, :id) || "unknown"
    summary = field(check, :summary) || ""
    detail = field(check, :detail) || ""

    ["  [#{status}] #{id} - #{summary}", "      #{detail}"]
  end

  defp render_remediations(checks) do
    remediations =
      checks
      |> Enum.map(&field(&1, :remediation))
      |> Enum.filter(&non_empty_string?/1)
      |> Enum.uniq()

    case remediations do
      [] -> nil
      values -> Enum.join(["Remediation:" | Enum.map(values, &"  - #{&1}")], "\n")
    end
  end

  defp usage_error(message, usage), do: {:error, "#{message}\n\n#{usage}", @usage_exit_code}

  defp option?(arg), do: String.starts_with?(arg, "-")

  defp summary_count(summary, key) do
    field(summary, key) || 0
  end

  defp exit_code(plan), do: field(plan, :exit_code)

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp group_usage do
    """
    orchardctl upgrade

    Usage:
      orchardctl upgrade help
      orchardctl upgrade plan [--json]
      orchardctl upgrade plan --help

    Commands:
      plan    Evaluate controller-side upgrade preflight checks.
    """
    |> String.trim()
  end

  defp plan_usage do
    """
    orchardctl upgrade plan [--json]

    Runs the SPEC 13.7 upgrade preflight plan without changing controller state.

    Options:
      --json    Emit the raw Orchard.Upgrade.plan/1 result as JSON.
      --help    Show this help.
    """
    |> String.trim()
  end

  defp default_runtime do
    %{
      plan: &Orchard.Upgrade.plan/1,
      encode_json: &Jason.encode!/1
    }
  end
end
