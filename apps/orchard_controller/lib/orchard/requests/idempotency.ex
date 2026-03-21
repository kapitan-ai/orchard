defmodule Orchard.Requests.Idempotency do
  @moduledoc """
  Tenant-scoped idempotency helpers for public inference requests.
  """

  alias Orchard.Requests
  alias Orchard.Requests.Request

  defmodule Context do
    @moduledoc false

    @enforce_keys [:tenant_id, :key, :body_hash]
    defstruct [:tenant_id, :key, :body_hash]

    @type t :: %__MODULE__{
            tenant_id: Ecto.UUID.t(),
            key: String.t(),
            body_hash: binary()
          }
  end

  @type conflict_reason ::
          :request_in_progress
          | :idempotency_mismatch
          | :idempotency_not_replayable

  @type mapping :: %{
          status: atom(),
          type: String.t(),
          code: String.t(),
          message: String.t(),
          param: String.t()
        }

  @spec extract_key(Plug.Conn.t()) :: {:ok, nil | String.t()} | {:error, :invalid_idempotency_key}
  def extract_key(conn) do
    case Plug.Conn.get_req_header(conn, "idempotency-key") do
      [] ->
        {:ok, nil}

      [value] ->
        value
        |> String.trim()
        |> case do
          "" -> {:error, :invalid_idempotency_key}
          key -> {:ok, key}
        end

      _values ->
        {:error, :invalid_idempotency_key}
    end
  end

  @spec build_context(Ecto.UUID.t(), String.t(), map()) ::
          {:ok, Context.t()} | {:error, :invalid_request_shape}
  def build_context(tenant_id, key, params) when is_binary(key) and is_map(params) do
    with {:ok, encoded} <- encode_normalized_json(params) do
      {:ok,
       %Context{
         tenant_id: tenant_id,
         key: key,
         body_hash: :crypto.hash(:sha256, encoded)
       }}
    end
  end

  @spec resolve(Context.t()) ::
          :proceed
          | {:replay, struct()}
          | {:conflict, conflict_reason(), struct()}
  def resolve(%Context{} = context) do
    case Requests.get_request_by_tenant_and_idempotency_key(context.tenant_id, context.key) do
      nil ->
        :proceed

      %Request{body_hash: body_hash} = request when body_hash != context.body_hash ->
        {:conflict, :idempotency_mismatch, request}

      %Request{} = request ->
        classify_matching_request(request)
    end
  end

  @spec conflict_mapping(:invalid_idempotency_key | conflict_reason()) :: mapping()
  def conflict_mapping(:invalid_idempotency_key) do
    %{
      status: :bad_request,
      type: "invalid_request_error",
      code: "invalid_idempotency_key",
      message: "Idempotency-Key must be a single non-empty header value",
      param: "Idempotency-Key"
    }
  end

  def conflict_mapping(:request_in_progress) do
    %{
      status: :conflict,
      type: "conflict_error",
      code: "request_in_progress",
      message: "A request with this Idempotency-Key is already in progress for this tenant",
      param: "Idempotency-Key"
    }
  end

  def conflict_mapping(:idempotency_mismatch) do
    %{
      status: :conflict,
      type: "conflict_error",
      code: "idempotency_mismatch",
      message: "This Idempotency-Key has already been used with a different request body",
      param: "Idempotency-Key"
    }
  end

  def conflict_mapping(:idempotency_not_replayable) do
    %{
      status: :conflict,
      type: "conflict_error",
      code: "idempotency_not_replayable",
      message: "This Idempotency-Key refers to a request that cannot be replayed",
      param: "Idempotency-Key"
    }
  end

  defp encode_normalized_json(value) when is_map(value) do
    if Map.has_key?(value, :__struct__),
      do: {:error, :invalid_request_shape},
      else: encode_object(value)
  end

  defp encode_normalized_json(value) when is_list(value) do
    case encode_list_items(value) do
      {:ok, encoded_items} -> {:ok, "[" <> Enum.join(encoded_items, ",") <> "]"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_normalized_json(value)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_nil(value) do
    {:ok, Jason.encode!(value)}
  end

  defp encode_normalized_json(value) when is_atom(value) do
    {:ok, Jason.encode!(Atom.to_string(value))}
  end

  defp encode_normalized_json(_value), do: {:error, :invalid_request_shape}

  defp normalize_object_entry({key, value}) do
    with {:ok, normalized_key} <- normalize_key(key),
         {:ok, encoded_value} <- encode_normalized_json(value) do
      {:ok, normalized_key, encoded_value}
    end
  end

  defp classify_matching_request(%Request{state: state} = request)
       when state in [
              :received,
              :validated,
              :admitted,
              :queued,
              :scheduled,
              :dispatching,
              :running,
              :streaming
            ] do
    {:conflict, :request_in_progress, request}
  end

  defp classify_matching_request(
         %Request{state: :completed, stream: false, response_payload: response_payload} = request
       )
       when is_map(response_payload) do
    {:replay, request}
  end

  defp classify_matching_request(%Request{} = request) do
    {:conflict, :idempotency_not_replayable, request}
  end

  defp encode_object(value) do
    case encode_object_entries(value) do
      {:ok, encoded_pairs} ->
        {:ok, "{" <> Enum.join(encoded_pairs, ",") <> "}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode_object_entries(value) do
    value
    |> Enum.reduce_while([], fn entry, acc ->
      case normalize_object_entry(entry) do
        {:ok, key, encoded_value} -> {:cont, [{key, encoded_value} | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> format_object_entries()
  end

  defp format_object_entries({:error, reason}), do: {:error, reason}

  defp format_object_entries(encoded_pairs) do
    encoded_pairs =
      encoded_pairs
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, encoded_value} -> Jason.encode!(key) <> ":" <> encoded_value end)

    {:ok, encoded_pairs}
  end

  defp encode_list_items(value) do
    value
    |> Enum.reduce_while([], fn item, acc ->
      case encode_normalized_json(item) do
        {:ok, encoded} -> {:cont, [encoded | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_encoded_items()
  end

  defp reverse_encoded_items({:error, reason}), do: {:error, reason}
  defp reverse_encoded_items(encoded_items), do: {:ok, Enum.reverse(encoded_items)}

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, :invalid_request_shape}
end
