defmodule OrchardConsole.TimeHelpers do
  @moduledoc false

  @spec elapsed_ms(DateTime.t() | nil, DateTime.t() | nil) :: non_neg_integer() | nil
  def elapsed_ms(nil, _end_at), do: nil
  def elapsed_ms(_start_at, nil), do: nil

  def elapsed_ms(%DateTime{} = start_at, %DateTime{} = end_at) do
    ms = DateTime.diff(end_at, start_at, :millisecond)
    if ms >= 0, do: ms, else: nil
  end

  @spec format_duration(non_neg_integer() | nil) :: String.t()
  def format_duration(nil), do: "—"
  def format_duration(ms) when ms < 1000, do: "#{ms} ms"

  def format_duration(ms) do
    seconds = ms / 1000
    :erlang.float_to_binary(seconds, decimals: 1) <> " s"
  end
end
