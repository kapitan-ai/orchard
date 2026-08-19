defmodule OrchardCLI.Commands.Models.Reference do
  @moduledoc false

  alias Orchard.Governance
  alias Orchard.Governance.Tenant
  alias Orchard.Models
  alias Orchard.Models.Access
  alias Orchard.Repo

  @spec resolve_tenant(String.t()) :: {:ok, Tenant.t()} | {:error, :tenant_not_found}
  def resolve_tenant(reference) when is_binary(reference) do
    case Ecto.UUID.cast(reference) do
      {:ok, id} -> Governance.get_tenant(id)
      :error -> fetch_tenant_by_slug(reference)
    end
  end

  @spec resolve_model(String.t()) ::
          {:ok, Orchard.Models.Model.t()} | {:error, :invalid_model_identity | :model_not_found}
  def resolve_model(identity) do
    with {:ok, %{model_id: model_id, version: version}} <- parse_model_identity(identity),
         %Orchard.Models.Model{} = model <- Models.get_model_by_identity(model_id, version) do
      {:ok, model}
    else
      nil -> {:error, :model_not_found}
      :error -> {:error, :invalid_model_identity}
    end
  end

  @spec resolve_policy(String.t()) ::
          {:ok, Orchard.Models.RoutingPolicy.t()} | {:error, :routing_policy_not_found}
  def resolve_policy(reference), do: Access.get_routing_policy(reference)

  @spec parse_model_identity(String.t()) ::
          {:ok, %{model_id: String.t(), version: String.t()}} | :error
  def parse_model_identity(identity) when is_binary(identity) and identity != "" do
    case :binary.matches(identity, "@") do
      [] ->
        :error

      matches ->
        split_model_identity(identity, List.last(matches))
    end
  end

  def parse_model_identity(_identity), do: :error

  defp split_model_identity(identity, {position, _length}) do
    model_id = binary_part(identity, 0, position)
    version = binary_part(identity, position + 1, byte_size(identity) - position - 1)

    if model_id == "" or version == "",
      do: :error,
      else: {:ok, %{model_id: model_id, version: version}}
  end

  defp fetch_tenant_by_slug(slug) do
    case Repo.get_by(Tenant, slug: slug) do
      %Tenant{} = tenant -> {:ok, tenant}
      nil -> {:error, :tenant_not_found}
    end
  end
end
