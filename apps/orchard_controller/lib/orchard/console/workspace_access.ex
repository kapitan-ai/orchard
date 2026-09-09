defmodule OrchardConsole.WorkspaceAccess do
  @moduledoc "Read-only exact-model grants and scoped operator command handoffs."

  alias Orchard.Models
  alias Orchard.Models.Access

  @type row :: %{
          model: Models.Model.t(),
          grant_state: :enabled | :disabled | :not_granted,
          grant: map() | nil
        }

  @spec list(map(), keyword()) :: {:ok, [row()]} | {:error, term()}
  def list(tenant, opts \\ []) do
    access_reader = Keyword.get(opts, :access_reader, &Access.list_model_access/1)
    model_reader = Keyword.get(opts, :model_reader, &Models.list_models/0)

    with {:ok, grants} <- access_reader.(tenant) do
      by_model = Map.new(grants, &{&1.model_id, &1})

      rows =
        model_reader.()
        |> Enum.sort_by(&{&1.model_id, &1.version, &1.id})
        |> Enum.map(fn model ->
          grant = Map.get(by_model, model.id)
          %{model: model, grant: grant, grant_state: grant_state(grant)}
        end)

      {:ok, rows}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  end

  @spec commands(map(), map(), map() | nil) :: %{grant: String.t(), inspect: String.t()}
  def commands(%{id: tenant_id}, %{model_id: model_id, version: version}, grant \\ nil) do
    exact_model = shell_quote(model_id <> "@" <> version)
    scope = shell_quote(tenant_id)
    policy = policy_option(grant)

    %{
      grant: "orchardctl models access grant " <> exact_model <> " --tenant " <> scope <> policy,
      inspect: "orchardctl models access inspect " <> exact_model <> " --tenant " <> scope
    }
  end

  defp policy_option(%{routing_policy_id: id}) when is_binary(id),
    do: " --routing-policy-id " <> shell_quote(id)

  defp policy_option(_grant), do: ""

  defp grant_state(nil), do: :not_granted
  defp grant_state(%{enabled: true}), do: :enabled
  defp grant_state(_grant), do: :disabled
  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
