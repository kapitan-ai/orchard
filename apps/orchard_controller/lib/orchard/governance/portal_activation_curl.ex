defmodule Orchard.Governance.PortalActivationCurl do
  @moduledoc """
  Builds one inert `POST /v1/chat/completions` curl after a portal mint.

  Model selection is fail-closed: if tenant authorization cannot be proven,
  no curl is produced. Untrusted interpolations are POSIX-single-quoted.
  """

  alias Orchard.API.Endpoint
  alias Orchard.API.Transport
  alias Orchard.Models

  @prompt "Say hello in one sentence."

  @spec select_callable_model(Ecto.UUID.t(), String.t() | nil) :: String.t() | nil
  def select_callable_model(tenant_id, requested_model \\ nil)

  def select_callable_model(tenant_id, nil) when is_binary(tenant_id) do
    tenant_id
    |> visible_models_for_tenant()
    |> Enum.min_by(&model_sort_key/1, fn -> nil end)
    |> exact_model_identity()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> nil
  end

  def select_callable_model(tenant_id, requested_model)
      when is_binary(tenant_id) and is_binary(requested_model) do
    tenant_id
    |> visible_models_for_tenant()
    |> Enum.find(&(exact_model_identity(&1) == requested_model))
    |> exact_model_identity()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> nil
  end

  def select_callable_model(_tenant_id, _requested_model), do: nil

  @spec build(String.t(), String.t() | nil, String.t() | nil) :: String.t() | nil
  def build(_token, nil, _url), do: nil
  def build(_token, _model_id, nil), do: nil

  def build(token, model_id, url)
      when is_binary(token) and is_binary(model_id) and is_binary(url) do
    with true <- https_url?(url),
         {:ok, body} <- encode_body(model_id) do
      Enum.join(
        [
          "curl -sS -X POST",
          posix_single_quote(completions_url(url)),
          "-H",
          posix_single_quote("Authorization: Bearer " <> token),
          "-H",
          posix_single_quote("Content-Type: application/json"),
          "-d",
          posix_single_quote(body)
        ],
        " "
      )
    else
      _other -> nil
    end
  end

  def build(_token, _model_id, _url), do: nil

  @spec public_base_url() :: String.t() | nil
  def public_base_url do
    if Transport.public_api_https_enabled?() do
      url = Endpoint.url()
      if https_url?(url), do: url, else: nil
    else
      nil
    end
  end

  defp visible_models_for_tenant(tenant_id), do: Models.list_active_models_for_tenant(tenant_id)

  defp model_sort_key(model), do: {model.model_id, model.version, model.id}

  defp exact_model_identity(nil), do: nil
  defp exact_model_identity(model), do: model.model_id <> "@" <> model.version

  defp completions_url(base_url) do
    String.trim_trailing(base_url, "/") <> "/v1/chat/completions"
  end

  defp encode_body(model_id) do
    Jason.encode(%{
      model: model_id,
      messages: [%{role: "user", content: @prompt}]
    })
  end

  defp https_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https"} -> true
      _other -> false
    end
  end

  defp posix_single_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
