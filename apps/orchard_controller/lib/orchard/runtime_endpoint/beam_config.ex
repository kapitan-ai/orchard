defmodule Orchard.RuntimeEndpoint.BeamConfig do
  @moduledoc """
  Guardrail validation for future first-party BEAM Runtime Endpoint transport.
  """

  defstruct enabled: false,
            node_name: nil,
            cookie_file: nil,
            listen_host: nil,
            admitted_services: [],
            allowed_cidrs: []

  @type t :: %__MODULE__{
          enabled: boolean(),
          node_name: String.t() | nil,
          cookie_file: String.t() | nil,
          listen_host: String.t() | nil,
          admitted_services: [String.t()],
          allowed_cidrs: [String.t()]
        }

  @type error ::
          :beam_distribution_disabled
          | {:invalid_beam_distribution_config, [atom()]}

  @spec config() :: keyword()
  def config do
    :orchard_controller
    |> Application.get_env(:runtime_endpoint, [])
    |> Keyword.get(:beam, [])
  end

  @spec validate(keyword() | map(), atom()) :: {:ok, t()} | {:error, error()}
  def validate(config \\ config(), env \\ runtime_env()) do
    attrs = attrs_map(config)

    if enabled?(attrs) do
      validate_enabled_attrs(attrs, env)
    else
      {:ok, %__MODULE__{enabled: false}}
    end
  end

  @spec validate_enabled(keyword() | map(), atom()) :: {:ok, t()} | {:error, error()}
  def validate_enabled(config \\ config(), env \\ runtime_env()) do
    attrs = attrs_map(config)

    if enabled?(attrs) do
      validate_enabled_attrs(attrs, env)
    else
      {:error, :beam_distribution_disabled}
    end
  end

  defp validate_enabled_attrs(attrs, _env) do
    errors =
      []
      |> require_non_empty(attrs, :node_name, :missing_node_name)
      |> require_non_empty(attrs, :cookie_file, :missing_cookie_file)
      |> require_restricted_list(attrs, :admitted_services, :missing_admitted_services)
      |> require_restricted_list(attrs, :allowed_cidrs, :missing_allowed_cidrs)
      |> require_list_without_global_cidrs(attrs, :allowed_cidrs)
      |> require_restricted_listen_host(attrs)

    case errors do
      [] -> {:ok, struct_from_attrs(attrs)}
      _ -> {:error, {:invalid_beam_distribution_config, Enum.reverse(errors)}}
    end
  end

  defp struct_from_attrs(attrs) do
    %__MODULE__{
      enabled: true,
      node_name: string_value(attrs, :node_name),
      cookie_file: string_value(attrs, :cookie_file),
      listen_host: string_value(attrs, :listen_host),
      admitted_services: list_value(attrs, :admitted_services),
      allowed_cidrs: list_value(attrs, :allowed_cidrs)
    }
  end

  defp require_non_empty(errors, attrs, key, error) do
    if non_empty_string?(value(attrs, key)), do: errors, else: [error | errors]
  end

  defp require_restricted_list(errors, attrs, key, error) do
    values = list_value(attrs, key)

    if values != [] and Enum.all?(values, &non_empty_string?/1) do
      errors
    else
      [error | errors]
    end
  end

  defp require_list_without_global_cidrs(errors, attrs, key) do
    cidrs = list_value(attrs, key)

    if Enum.any?(cidrs, &(&1 in ["0.0.0.0/0", "::/0"])) do
      [:global_beam_distribution_cidr | errors]
    else
      errors
    end
  end

  defp require_restricted_listen_host(errors, attrs) do
    case value(attrs, :listen_host) do
      host when host in ["0.0.0.0", "::"] -> [:unrestricted_listen_host | errors]
      host when is_binary(host) and host != "" -> errors
      _ -> [:missing_listen_host | errors]
    end
  end

  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(%{} = attrs), do: attrs

  defp enabled?(attrs), do: value(attrs, :enabled) == true

  defp string_value(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp list_value(attrs, key) do
    case value(attrs, key) do
      values when is_list(values) -> values
      nil -> []
      value -> [value]
    end
  end

  defp value(attrs, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, string_key) -> Map.fetch!(attrs, string_key)
      true -> nil
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp runtime_env do
    if Code.ensure_loaded?(Mix), do: Mix.env(), else: :prod
  end
end
