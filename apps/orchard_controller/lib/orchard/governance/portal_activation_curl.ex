defmodule Orchard.Governance.PortalActivationCurl do
  @moduledoc """
  Builds one inert `POST /v1/chat/completions` curl after a portal mint.

  Model selection is fail-closed: if tenant authorization cannot be proven,
  no curl is produced. Untrusted interpolations are POSIX-single-quoted.
  """

  alias Orchard.API.Endpoint
  alias Orchard.API.Transport

  @prompt "Say hello in one sentence."

  @spec select_callable_model(Ecto.UUID.t()) :: String.t() | nil
  def select_callable_model(tenant_id) when is_binary(tenant_id) do
    case visible_models_for_tenant(tenant_id) do
      [] ->
        nil
    end
  end

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

  defp visible_models_for_tenant(_tenant_id) do
    # GET /v1/models is not tenant-scoped yet. Do not treat the full active
    # catalog as authorized for a portal curl.
    []
  end

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
