defmodule Orchard.API.InferenceAccepts do
  @moduledoc false

  import Plug.Conn

  alias Orchard.API.ErrorHelpers
  alias Plug.Conn.Utils

  @json "application/json"
  @event_stream "text/event-stream"

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if acceptable?(conn) do
      put_private(conn, :phoenix_format, "json")
    else
      conn
      |> ErrorHelpers.send_error(
        :not_acceptable,
        "No acceptable response media type was requested",
        "invalid_request_error",
        code: "not_acceptable"
      )
      |> halt()
    end
  end

  defp acceptable?(conn) do
    accepted_types = if streaming?(conn), do: [@json, @event_stream], else: [@json]

    case get_req_header(conn, "accept") do
      [] -> true
      headers -> Enum.any?(headers, &header_accepts?(&1, accepted_types))
    end
  end

  defp streaming?(%Plug.Conn{body_params: %{"stream" => true}}), do: true
  defp streaming?(_conn), do: false

  defp header_accepts?(header, accepted_types) do
    header
    |> Utils.list()
    |> Enum.any?(&media_range_accepts?(&1, accepted_types))
  end

  defp media_range_accepts?(media_range, accepted_types) do
    case Utils.media_type(media_range) do
      {:ok, type, subtype, params} ->
        positive_quality?(params) and
          Enum.any?(accepted_types, &matches_media_range?(&1, type, subtype))

      :error ->
        false
    end
  end

  defp positive_quality?(%{"q" => quality}) do
    case Float.parse(quality) do
      {value, _rest} -> value > 0
      :error -> true
    end
  end

  defp positive_quality?(_params), do: true

  defp matches_media_range?(media_type, "*", "*"), do: media_type in [@json, @event_stream]

  defp matches_media_range?(media_type, type, "*") do
    String.starts_with?(media_type, type <> "/")
  end

  defp matches_media_range?(media_type, type, subtype), do: media_type == type <> "/" <> subtype
end
