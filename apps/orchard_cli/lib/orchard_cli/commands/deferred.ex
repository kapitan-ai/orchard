defmodule OrchardCLI.Commands.Deferred do
  @moduledoc false

  @type deferred_command :: %{
          required(:path) => [String.t()],
          required(:usage) => String.t(),
          required(:summary) => String.t(),
          required(:status) => String.t(),
          optional(:guidance) => [String.t()]
        }

  @type group_spec :: %{
          required(:name) => String.t(),
          required(:commands) => [deferred_command()]
        }

  @spec run([String.t()], group_spec()) :: OrchardCLI.command_result()
  def run(args, spec) do
    case args do
      [] ->
        {:error, group_usage(spec), 1}

      ["help"] ->
        {:ok, group_usage(spec)}

      ["--help"] ->
        {:ok, group_usage(spec)}

      _ ->
        dispatch(args, spec)
    end
  end

  @spec group_usage(group_spec()) :: String.t()
  def group_usage(%{name: name, commands: commands}) do
    command_lines =
      Enum.map(commands, fn command ->
        "  #{group_command_label(command)}  #{command.summary}"
      end)

    Enum.join(
      [
        "Usage: orchardctl #{name} <command>",
        "",
        "Commands:",
        Enum.join(command_lines, "\n")
      ],
      "\n"
    )
  end

  defp dispatch(args, %{commands: commands} = spec) do
    case match_command(args, commands) do
      {:help, command} -> {:ok, command_usage(command)}
      {:deferred, command} -> {:error, deferred_message(command), 1}
      :unknown -> {:error, group_usage(spec), 1}
    end
  end

  defp match_command(args, commands) do
    Enum.find_value(commands, :unknown, fn command ->
      path = command.path

      cond do
        args in [path ++ ["help"], path ++ ["--help"]] -> {:help, command}
        starts_with?(args, path) -> {:deferred, command}
        true -> false
      end
    end)
  end

  defp starts_with?(args, path), do: Enum.take(args, length(path)) == path

  defp command_usage(command) do
    [
      command.usage,
      "",
      command.summary,
      "",
      "Status:",
      "  #{command.status}",
      guidance(command)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp deferred_message(command) do
    [
      "Error: #{command_label(command)} is not implemented in this build.",
      "",
      command_usage(command)
    ]
    |> Enum.join("\n")
  end

  defp guidance(%{guidance: guidance}) when is_list(guidance) and guidance != [] do
    [
      "",
      "Current supported path:"
      | Enum.map(guidance, &"  - #{&1}")
    ]
    |> Enum.join("\n")
  end

  defp guidance(_command), do: ""

  defp group_command_label(%{path: path}), do: Enum.join(path, " ")

  defp command_label(%{usage: "orchardctl " <> command}), do: command
end
