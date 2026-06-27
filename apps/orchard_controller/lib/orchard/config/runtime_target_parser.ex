defmodule Orchard.Config.RuntimeTargetParser do
  @moduledoc """
  Pure parser for the gRPC compatibility `ORCHARD_RUNTIME_CLIENT_TARGETS`
  environment variable.

  Extracted from `config/runtime.exs` to enable direct unit testing
  of malformed input rejection.

  Format: comma-separated `host:port` pairs.
  BEAM Runtime Endpoint node names belong to `ORCHARD_RUNTIME_ENDPOINT_TARGETS`
  and are intentionally rejected here.
  Example: `"127.0.0.1:50071,100.86.198.38:50061"`
  """

  @doc """
  Parse a comma-separated host:port string into a list of target keyword lists.

  Returns `[]` for `nil` or blank input.
  Raises `RuntimeError` on malformed segments.

  ## Examples

      iex> parse_csv!("127.0.0.1:50071,10.0.0.2:50061", "ORCHARD_RUNTIME_CLIENT_TARGETS")
      [[host: "127.0.0.1", port: 50071], [host: "10.0.0.2", port: 50061]]

      iex> parse_csv!(nil, "ORCHARD_RUNTIME_CLIENT_TARGETS")
      []
  """
  @spec parse_csv!(String.t() | nil, String.t()) :: [[host: String.t(), port: pos_integer()]]
  def parse_csv!(nil, _env_name), do: []
  def parse_csv!("", _env_name), do: []

  def parse_csv!(value, env_name) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_segment!(&1, env_name))
  end

  defp parse_segment!(segment, env_name) do
    case String.split(segment, ":") do
      [host, port_str] when host != "" ->
        case Integer.parse(port_str) do
          {port, ""} when port in 1..65_535 ->
            [host: host, port: port]

          _ ->
            raise "environment variable #{env_name} has invalid port in segment #{inspect(segment)}"
        end

      _ ->
        raise "environment variable #{env_name} has invalid host:port segment #{inspect(segment)}"
    end
  end
end
