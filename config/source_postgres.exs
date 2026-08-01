defmodule Orchard.Config.SourcePostgres do
  @moduledoc false

  @default_port 5432
  @port_pattern ~r/\A[0-9]+\z/

  @spec port!(nil | binary()) :: pos_integer()
  def port!(nil), do: @default_port

  def port!(value) when is_binary(value) do
    if Regex.match?(@port_pattern, value) do
      port = String.to_integer(value)

      if port in 1..65_535 do
        port
      else
        invalid_port!(value)
      end
    else
      invalid_port!(value)
    end
  end

  defp invalid_port!(value) do
    raise "environment variable PGPORT must be an unsigned decimal TCP port in 1..65535, got: #{inspect(value)}"
  end
end
