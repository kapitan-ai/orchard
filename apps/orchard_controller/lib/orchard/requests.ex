defmodule Orchard.Requests do
  @moduledoc """
  Persistence context for durable request rows and lifecycle events.
  """

  import Ecto.Query

  alias Orchard.Repo
  alias Orchard.Requests.{Request, RequestEvent}

  @spec create_request(map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def create_request(attrs) do
    %Request{}
    |> Request.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec get_request!(Ecto.UUID.t()) :: struct()
  def get_request!(id), do: Repo.get!(Request, id)

  @spec get_request_by_public_id(String.t()) :: struct() | nil
  def get_request_by_public_id(public_id) do
    Repo.get_by(Request, public_id: public_id)
  end

  @spec list_request_events(struct() | Ecto.UUID.t()) :: [struct()]
  def list_request_events(%Request{id: request_id}), do: list_request_events(request_id)

  def list_request_events(request_id) do
    RequestEvent
    |> where([event], event.request_id == ^request_id)
    |> order_by([event], asc: event.seq)
    |> Repo.all()
  end

  @spec append_request_event(struct() | Ecto.UUID.t(), map()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | :request_not_found}
  def append_request_event(%Request{id: request_id}, attrs),
    do: append_request_event(request_id, attrs)

  def append_request_event(request_id, attrs) do
    Repo.transaction(fn ->
      case lock_request(request_id) do
        {:ok, _request} ->
          attrs =
            attrs
            |> normalize_request_event_attrs()
            |> Map.put("request_id", request_id)
            |> Map.put("seq", next_request_event_seq(request_id))

          %RequestEvent{}
          |> RequestEvent.changeset(attrs)
          |> Repo.insert()

        {:error, :request_not_found} ->
          Repo.rollback(:request_not_found)
      end
    end)
    |> unwrap_transaction_result()
  end

  @spec mark_terminal(struct(), map()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | :already_terminal | :request_not_found}
  def mark_terminal(%Request{id: request_id}, attrs) do
    Repo.transaction(fn ->
      case lock_request(request_id) do
        {:ok, current_request} ->
          apply_terminal_update(current_request, attrs)

        {:error, :request_not_found} ->
          Repo.rollback(:request_not_found)
      end
    end)
    |> unwrap_transaction_result()
  end

  defp apply_terminal_update(%Request{} = request, attrs) do
    if request.state in Request.terminal_states() do
      Repo.rollback(:already_terminal)
    else
      request
      |> Request.terminal_changeset(attrs)
      |> Repo.update()
    end
  end

  defp lock_request(request_id) do
    request =
      Request
      |> where([request], request.id == ^request_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case request do
      nil -> {:error, :request_not_found}
      request -> {:ok, request}
    end
  end

  defp normalize_request_event_attrs(attrs) do
    attrs
    |> Map.new()
    |> Map.new(fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp next_request_event_seq(request_id) do
    RequestEvent
    |> where([event], event.request_id == ^request_id)
    |> select([event], max(event.seq))
    |> Repo.one()
    |> case do
      nil -> 1
      seq -> seq + 1
    end
  end

  defp unwrap_transaction_result({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_transaction_result({:ok, {:error, changeset}}), do: {:error, changeset}
  defp unwrap_transaction_result({:error, :request_not_found}), do: {:error, :request_not_found}
  defp unwrap_transaction_result({:error, :already_terminal}), do: {:error, :already_terminal}
end
