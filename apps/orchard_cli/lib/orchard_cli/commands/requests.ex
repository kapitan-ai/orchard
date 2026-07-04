defmodule OrchardCLI.Commands.Requests do
  @moduledoc false

  alias Orchard.API.Ops.SchedulerExplanationPresenter
  alias Orchard.Requests

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args) do
    case args do
      ["inspect", "--help"] -> {:ok, inspect_usage()}
      ["inspect", "help"] -> {:ok, inspect_usage()}
      ["help"] -> {:ok, group_usage()}
      ["--help"] -> {:ok, group_usage()}
      [] -> {:error, group_usage(), 1}
      ["inspect" | rest] -> run_inspect(rest)
      _other -> {:error, group_usage(), 1}
    end
  end

  defp run_inspect(args) do
    case parse_inspect_args(args) do
      {:ok, opts} -> inspect_request(opts)
      {:help, usage} -> {:ok, usage}
      {:error, message, code} -> {:error, message, code}
    end
  end

  defp inspect_request(%{request_id: request_id, json?: json?}) do
    with {:ok, request} <- guarded_fetch_request(request_id),
         {:ok, explanation} <- SchedulerExplanationPresenter.show(request) do
      {:ok, render_explanation(explanation, json?)}
    else
      {:error, :scheduler_explanation_not_found} -> explanation_not_found(json?)
      {:error, reason} -> invalid_explanation(reason, json?)
    end
  end

  defp parse_inspect_args(args) do
    case OptionParser.parse(args, strict: [json: :boolean, help: :boolean]) do
      {opts, [request_id], []} ->
        if Keyword.get(opts, :help, false) do
          {:help, inspect_usage()}
        else
          {:ok, %{request_id: request_id, json?: Keyword.get(opts, :json, false)}}
        end

      {_opts, _rest, [{flag, _value} | _unknown]} ->
        {:error, "Unknown option: #{flag}", 2}

      _other ->
        {:error, inspect_usage(), 1}
    end
  end

  defp guarded_fetch_request(request_id) do
    if repo_available?() do
      case Requests.get_request_by_public_id(request_id) do
        nil -> {:error, :scheduler_explanation_not_found}
        request -> {:ok, request}
      end
    else
      {:error, :scheduler_explanation_not_found}
    end
  rescue
    _exception in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      {:error, :scheduler_explanation_not_found}
  end

  defp repo_available? do
    pid = Process.whereis(Orchard.Repo)
    is_pid(pid) and Process.alive?(pid)
  end

  defp render_explanation(explanation, true), do: encode_json(explanation)

  defp render_explanation(explanation, false) do
    Enum.join(
      [
        "Request: #{explanation.request_id}",
        "Selected node: #{explanation.selected_node_id || "-"}",
        "Selection tier: #{explanation.selection_tier || "-"}",
        "Scored candidates:",
        render_candidates(explanation.scored_candidates),
        "Rejected candidates:",
        render_candidates(explanation.rejected_candidates),
        "Skipped candidates:",
        render_candidates(explanation.skipped_candidates)
      ],
      "\n"
    )
  end

  defp render_candidates([]), do: "  none"

  defp render_candidates(candidates) do
    Enum.map_join(candidates, "\n", fn candidate ->
      node_id = candidate.node_id || candidate.target_ref || "-"
      tier = candidate.tier || "-"
      score = if is_nil(candidate.score), do: "-", else: candidate.score
      codes = format_reason_codes(candidate.reason_codes)

      "  #{node_id} tier=#{tier} score=#{score} reason_codes=#{codes}"
    end)
  end

  defp format_reason_codes([]), do: "none"
  defp format_reason_codes(codes), do: Enum.join(codes, ",")

  defp explanation_not_found(json?) do
    message = "Scheduler explanation was not found."

    if json? do
      {:error,
       encode_json(%{
         object: "error",
         code: "scheduler_explanation_not_found",
         message: message
       }), 1}
    else
      {:error, "Error: #{message}", 1}
    end
  end

  defp invalid_explanation(reason, json?) do
    message = "Persisted scheduler explanation is invalid."

    if json? do
      {:error,
       encode_json(%{
         object: "error",
         code: "scheduler_explanation_invalid",
         message: message,
         details: inspect(reason)
       }), 1}
    else
      {:error, "Error: #{message}\nDetails: #{inspect(reason)}", 1}
    end
  end

  defp encode_json(payload), do: Jason.encode!(payload, pretty: true)

  defp group_usage do
    Enum.join(
      [
        "Usage: orchardctl requests <command>",
        "",
        "Commands:",
        "  inspect  Inspect a request scheduler explanation"
      ],
      "\n"
    )
  end

  defp inspect_usage do
    Enum.join(
      [
        "Usage: orchardctl requests inspect <request-id> [--json]",
        "",
        "Shows the persisted scheduler explanation for a request using the shared scheduler explanation contract."
      ],
      "\n"
    )
  end
end
