defmodule Orchard.API.ModelsController do
  @moduledoc """
  OpenAI-compatible model listing.

  `GET /v1/models` returns active catalog Models authorized for the
  effective Tenant in OpenAI list format per SPEC.md §7.2.3.
  """

  use Phoenix.Controller, formats: [:json]

  alias Orchard.Models

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    models = Models.list_active_models_for_tenant(conn.assigns.tenant_id)
    data = Enum.map(models, &to_openai_model/1)
    json(conn, %{object: "list", data: data})
  end

  defp to_openai_model(model) do
    %{
      id: model_display_id(model),
      object: "model",
      created: to_unix_seconds(model.inserted_at),
      owned_by: "local"
    }
  end

  defp model_display_id(model) do
    "#{model.model_id}@#{model.version}"
  end

  defp to_unix_seconds(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp to_unix_seconds(_), do: 0
end
