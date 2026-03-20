defmodule OrchardCLI.Commands.GovernanceHelpers do
  @moduledoc false

  @spec format_changeset_errors(Ecto.Changeset.t()) :: [String.t()]
  def format_changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message -> "#{field} #{message}" end)
    end)
    |> Enum.sort()
  end

  defp translate_error({message, opts}) do
    Regex.replace(~r/%{(\w+)}/, message, fn _match, key ->
      opts
      |> Keyword.get(String.to_existing_atom(key), key)
      |> to_string()
    end)
  end
end
