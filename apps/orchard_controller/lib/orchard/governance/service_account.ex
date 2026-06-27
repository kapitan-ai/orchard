defmodule Orchard.Governance.ServiceAccount do
  @moduledoc """
  Ecto schema for non-interactive service-account principals.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.{ApiKey, RoleBinding, Tenant}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @plaintext_keys ~w(
    api_key
    api_token
    one_time_secret
    plaintext_secret
    plaintext_token
    raw_csv
    secret
    token
  )

  @type t :: %__MODULE__{}

  schema "service_accounts" do
    field(:name, :string)
    field(:owner_contact, :string)
    field(:owner_name, :string)
    field(:team, :string)
    field(:external_ref, :string)
    field(:description, :string)
    field(:purpose, :string)
    field(:metadata, :map, default: %{})
    field(:disabled_at, :utc_datetime_usec)

    belongs_to(:tenant, Tenant)
    has_many(:api_keys, ApiKey)
    has_many(:role_bindings, RoleBinding, foreign_key: :principal_id)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(service_account, attrs) do
    attrs = normalize_attrs(attrs)

    service_account
    |> cast(attrs, [
      :tenant_id,
      :name,
      :owner_contact,
      :owner_name,
      :team,
      :external_ref,
      :description,
      :purpose,
      :metadata,
      :disabled_at
    ])
    |> validate_required([:tenant_id, :name, :owner_contact])
    |> validate_no_plaintext_attrs(attrs)
    |> validate_no_plaintext_metadata()
    |> unique_constraint(:name, name: :service_accounts_tenant_id_name_index)
    |> unique_constraint(:external_ref, name: :idx_service_accounts_tenant_external_ref)
    |> check_constraint(:name, name: :service_accounts_name_not_blank)
    |> check_constraint(:owner_contact, name: :service_accounts_owner_contact_not_blank)
    |> foreign_key_constraint(:tenant_id)
  end

  @spec disabled?(t()) :: boolean()
  def disabled?(%__MODULE__{disabled_at: %DateTime{}}), do: true
  def disabled?(%__MODULE__{}), do: false

  defp validate_no_plaintext_attrs(changeset, attrs) do
    secret_keys =
      attrs
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.filter(&plaintext_key?/1)

    case secret_keys do
      [] ->
        changeset

      keys ->
        add_error(
          changeset,
          :base,
          "must not include plaintext token fields: #{Enum.join(keys, ", ")}"
        )
    end
  end

  defp validate_no_plaintext_metadata(changeset) do
    metadata = get_field(changeset, :metadata) || %{}

    if contains_plaintext_key?(metadata) do
      add_error(changeset, :metadata, "must not include plaintext token fields")
    else
      changeset
    end
  end

  defp contains_plaintext_key?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      plaintext_key?(to_string(key)) or contains_plaintext_key?(value)
    end)
  end

  defp contains_plaintext_key?(values) when is_list(values),
    do: Enum.any?(values, &contains_plaintext_key?/1)

  defp contains_plaintext_key?(_value), do: false

  defp plaintext_key?(key) do
    key
    |> String.downcase()
    |> then(&Enum.member?(@plaintext_keys, &1))
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put_new(acc, Atom.to_string(key), value)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp normalize_attrs(attrs) when is_list(attrs), do: normalize_attrs(Enum.into(attrs, %{}))
  defp normalize_attrs(_attrs), do: %{}
end
