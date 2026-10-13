defmodule OrchardCLI.Commands.NodeAdmission do
  @moduledoc false

  alias Orchard.NodeAdmissionPreauthorizations
  alias OrchardCLI.RepoRuntime

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(["mode", "set", mode | args]) do
    with {:ok, mode} <- parse_mode(mode),
         {:ok, opts} <- parse_mutation_args(args) do
      RepoRuntime.run(fn -> change_mode(mode, opts) end)
    end
  end

  def run(["preauthorization", "revoke", id | args]) do
    with {:ok, id} <- cast_uuid(id),
         {:ok, opts} <- parse_mutation_args(args) do
      RepoRuntime.run(fn -> revoke(id, opts) end)
    end
  end

  def run(["--help"]), do: {:ok, usage()}
  def run(["help"]), do: {:ok, usage()}
  def run(_args), do: {:error, usage(), 1}

  defp parse_mode("manual"), do: {:ok, :manual}
  defp parse_mode("enrollment-preauthorized"), do: {:ok, :enrollment_preauthorized}
  defp parse_mode(_mode), do: {:error, "Error: invalid admission mode.\n\n#{usage()}", 1}

  defp parse_mutation_args(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [reason: :string, confirm_digest: :string, json: :boolean]
      )

    reason = Keyword.get(options, :reason)

    if positional == [] and invalid == [] and present?(reason) do
      {:ok,
       %{
         reason: String.trim(reason),
         confirm_digest: Keyword.get(options, :confirm_digest),
         json?: Keyword.get(options, :json, false)
       }}
    else
      {:error, "Error: --reason is required.\n\n#{usage()}", 1}
    end
  end

  defp change_mode(mode, opts) do
    attrs = actor_attrs(opts.reason)

    with {:ok, preview} <- NodeAdmissionPreauthorizations.preview_mode_change(mode, attrs),
         :ok <- require_confirmation(preview, opts),
         {:ok, changed} <-
           NodeAdmissionPreauthorizations.change_mode(mode, attrs,
             confirmation_digest: preview.digest
           ) do
      render_success(
        %{
          "action" => "node_admission.mode_changed",
          "mode" => Atom.to_string(changed.mode),
          "version" => changed.version
        },
        opts
      )
    else
      {:error, message, code} -> {:error, message, code}
      {:error, reason} -> command_error(reason, opts)
    end
  end

  defp revoke(id, opts) do
    attrs = actor_attrs(opts.reason)

    with {:ok, preview} <- NodeAdmissionPreauthorizations.preview_revocation(id, attrs),
         :ok <- require_confirmation(preview, opts),
         {:ok, revoked} <-
           NodeAdmissionPreauthorizations.revoke(id, attrs, confirmation_digest: preview.digest) do
      render_success(
        %{
          "action" => "node_admission.preauthorization_revoked",
          "preauthorization_id" => revoked.id,
          "state" => Atom.to_string(revoked.state)
        },
        opts
      )
    else
      {:error, message, code} -> {:error, message, code}
      {:error, reason} -> command_error(reason, opts)
    end
  end

  defp actor_attrs(reason) do
    %{actor_type: "operator", actor_id: "local-orchardctl", reason: reason}
  end

  defp require_confirmation(preview, %{confirm_digest: digest}) when digest == preview.digest,
    do: :ok

  defp require_confirmation(preview, %{json?: true}) do
    {:error,
     Jason.encode!(%{
       "error" => "confirmation_required",
       "preview_digest" => preview.digest
     }), 2}
  end

  defp require_confirmation(preview, _opts) do
    {:error,
     "Mutation requires confirmation of the exact preview.\n" <>
       "Preview digest: #{preview.digest}\n" <>
       "Repeat with --confirm-digest #{preview.digest}.", 2}
  end

  defp render_success(payload, %{json?: true}), do: {:ok, Jason.encode!(payload)}

  defp render_success(payload, _opts) do
    lines =
      payload
      |> Enum.sort()
      |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{value}" end)

    {:ok, lines}
  end

  defp command_error(reason, %{json?: true}) do
    {:error, Jason.encode!(%{"error" => stable_reason(reason)}), 1}
  end

  defp command_error(reason, _opts) do
    {:error, "Error: #{stable_reason(reason)}.", 1}
  end

  defp stable_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp stable_reason(_reason), do: "node_admission_mutation_failed"

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "Error: invalid preauthorization ID.\n\n#{usage()}", 1}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp usage do
    "Usage:\n" <>
      "  orchardctl nodes admission mode set <manual|enrollment-preauthorized> --reason REASON [--confirm-digest DIGEST] [--json]\n" <>
      "  orchardctl nodes admission preauthorization revoke ID --reason REASON [--confirm-digest DIGEST] [--json]"
  end
end
