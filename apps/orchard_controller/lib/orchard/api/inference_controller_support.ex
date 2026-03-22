defmodule Orchard.API.InferenceControllerSupport do
  @moduledoc false

  import Phoenix.Controller, only: [json: 2]
  import Orchard.API.ErrorHelpers, only: [send_error: 5]

  alias Orchard.Inference.ChatError
  alias Orchard.Requests.Idempotency

  @spec extract_caller_context(Plug.Conn.t()) :: keyword()
  def extract_caller_context(conn) do
    [
      tenant_id: conn.assigns[:tenant_id],
      principal_id: conn.assigns[:principal_id],
      api_key_id: conn.assigns[:api_key_id]
    ]
  end

  @spec build_idempotency_context(Plug.Conn.t(), String.t(), map()) ::
          {:ok, Idempotency.Context.t() | nil}
          | {:error, :invalid_idempotency_key | :invalid_request_shape}
  def build_idempotency_context(conn, tenant_id, params) do
    case Idempotency.extract_key(conn) do
      {:ok, key} -> maybe_build_idempotency_context(tenant_id, key, params)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec resolve_idempotency(Plug.Conn.t(), Idempotency.Context.t() | nil) ::
          {:proceed, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def resolve_idempotency(conn, nil), do: {:proceed, conn}

  def resolve_idempotency(conn, idempotency) do
    case Idempotency.resolve(idempotency) do
      :proceed -> {:proceed, conn}
      {:replay, request} -> {:halt, json(conn, request.response_payload)}
      {:conflict, reason, _request} -> {:halt, send_idempotency_error(conn, reason)}
    end
  end

  @spec send_prepare_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def send_prepare_error(conn, reason) do
    reason
    |> ChatError.from_prepare_reason()
    |> ChatError.api_mapping()
    |> send_chat_error(conn)
  end

  @spec send_execute_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def send_execute_error(conn, reason) do
    reason
    |> ChatError.from_execute_error()
    |> ChatError.api_mapping()
    |> send_chat_error(conn)
  end

  @spec send_idempotency_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def send_idempotency_error(conn, :invalid_idempotency_key) do
    mapping = Idempotency.conflict_mapping(:invalid_idempotency_key)
    send_chat_error(mapping, conn)
  end

  def send_idempotency_error(conn, reason) do
    mapping = Idempotency.conflict_mapping(reason)
    send_chat_error(mapping, conn)
  end

  def sse_error_mapping({:idempotency_conflict, reason}) do
    reason
    |> Idempotency.conflict_mapping()
    |> Map.delete(:status)
  end

  def sse_error_mapping(reason) do
    reason
    |> ChatError.from_execute_error()
    |> ChatError.sse_mapping()
  end

  defp maybe_build_idempotency_context(_tenant_id, nil, _params), do: {:ok, nil}

  defp maybe_build_idempotency_context(tenant_id, key, params) do
    Idempotency.build_context(tenant_id, key, params)
  end

  defp send_chat_error(mapping, conn) do
    send_error(conn, mapping.status, mapping.message, mapping.type,
      param: mapping.param,
      code: mapping.code
    )
  end
end
