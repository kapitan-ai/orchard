defmodule Orchard.Governance.ApiKey do
  @moduledoc """
  Ecto schema for tenant-direct and service-account-owned API Token metadata.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.{AuditLog, PortalUser, ServiceAccount, Tenant}

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

  schema "api_keys" do
    field(:name, :string)
    field(:token_prefix, :string)
    field(:secret_hash, :string)
    field(:issuance_surface, :string, default: "governance")
    field(:expires_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    belongs_to(:tenant, Tenant)
    belongs_to(:service_account, ServiceAccount)
    belongs_to(:portal_user, PortalUser)
    has_many(:audit_logs, AuditLog)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(api_key, attrs) do
    attrs = normalize_attrs(attrs)

    api_key
    |> cast(attrs, [
      :tenant_id,
      :service_account_id,
      :portal_user_id,
      :name,
      :token_prefix,
      :secret_hash,
      :issuance_surface,
      :expires_at,
      :last_used_at,
      :revoked_at
    ])
    |> validate_required([:name, :token_prefix, :secret_hash])
    |> validate_inclusion(:issuance_surface, ["governance", "developer_portal"])
    |> validate_owner()
    |> validate_no_plaintext_attrs(attrs)
    |> unique_constraint(:token_prefix)
    |> exclusion_constraint(:name,
      name: :api_keys_service_account_active_name_no_overlap,
      message: "has already been taken"
    )
    |> check_constraint(:tenant_id, name: :api_keys_exactly_one_owner)
    |> check_constraint(:issuance_surface, name: :api_keys_issuance_surface_closed)
    |> check_constraint(:issuance_surface, name: :api_keys_developer_portal_tenant_direct)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:service_account_id)
    |> foreign_key_constraint(:portal_user_id)
  end

  @spec tenant_direct_changeset(struct(), map()) :: Ecto.Changeset.t()
  def tenant_direct_changeset(api_key, attrs) do
    api_key
    |> changeset(attrs)
    |> validate_required([:tenant_id])
  end

  @spec service_account_owned_changeset(struct(), map()) :: Ecto.Changeset.t()
  def service_account_owned_changeset(api_key, attrs) do
    api_key
    |> changeset(attrs)
    |> validate_required([:service_account_id])
  end

  @spec revoke_changeset(t(), map()) :: Ecto.Changeset.t()
  def revoke_changeset(api_key, attrs) do
    cast(api_key, attrs, [:revoked_at])
  end

  @spec revoked?(t()) :: boolean()
  def revoked?(%__MODULE__{revoked_at: %DateTime{}}), do: true
  def revoked?(%__MODULE__{}), do: false

  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    DateTime.compare(expires_at, now) != :gt
  end

  @spec active_for_auth?(t(), DateTime.t()) :: boolean()
  def active_for_auth?(%__MODULE__{} = api_key, %DateTime{} = now) do
    not revoked?(api_key) and not expired?(api_key, now)
  end

  @spec status(t(), DateTime.t()) :: :active | :expired | :revoked
  def status(%__MODULE__{} = api_key, %DateTime{} = now) do
    cond do
      revoked?(api_key) -> :revoked
      expired?(api_key, now) -> :expired
      true -> :active
    end
  end

  defp validate_owner(changeset) do
    tenant_id = get_field(changeset, :tenant_id)
    service_account_id = get_field(changeset, :service_account_id)

    case {tenant_id, service_account_id} do
      {nil, nil} ->
        add_error(changeset, :tenant_id, "or service_account_id must be present")

      {nil, _service_account_id} ->
        changeset

      {_tenant_id, nil} ->
        changeset

      {_tenant_id, _service_account_id} ->
        add_error(changeset, :service_account_id, "cannot be set with tenant_id")
    end
  end

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
