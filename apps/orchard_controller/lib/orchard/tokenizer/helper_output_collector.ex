defmodule Orchard.Tokenizer.HelperOutputCollector do
  @moduledoc false

  @type collect_result ::
          {:ok, binary(), non_neg_integer()}
          | {:error, :timeout | {:stdout_too_large, pos_integer()}}

  @spec collect(port(), pos_integer(), pos_integer()) :: collect_result()
  def collect(port, timeout_ms, max_stdout_bytes)
      when is_port(port) and is_integer(timeout_ms) and timeout_ms > 0 and
             is_integer(max_stdout_bytes) and max_stdout_bytes > 0 do
    collect_output(port, [], 0, monotonic_deadline_ms(timeout_ms), max_stdout_bytes)
  end

  defp monotonic_deadline_ms(timeout_ms) do
    System.monotonic_time(:millisecond) + timeout_ms
  end

  defp collect_output(port, chunks, bytes_so_far, deadline_ms, max_stdout_bytes) do
    receive do
      {^port, {:data, data}} ->
        collect_output_chunk(port, chunks, bytes_so_far, data, deadline_ms, max_stdout_bytes)

      {^port, {:exit_status, exit_status}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), exit_status}
    after
      remaining_timeout_ms(deadline_ms) ->
        close_helper_port(port)
        {:error, :timeout}
    end
  end

  defp collect_output_chunk(port, chunks, bytes_so_far, data, deadline_ms, max_stdout_bytes) do
    new_size = bytes_so_far + byte_size(data)

    if new_size > max_stdout_bytes do
      close_helper_port(port)
      {:error, {:stdout_too_large, max_stdout_bytes}}
    else
      collect_output(port, [data | chunks], new_size, deadline_ms, max_stdout_bytes)
    end
  end

  defp close_helper_port(port) do
    close_port(port)
    drain_port_messages(port, 100)
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    _error in [ArgumentError] -> :ok
  end

  defp drain_port_messages(port, timeout_ms) do
    receive do
      {^port, _message} -> drain_port_messages(port, 0)
    after
      timeout_ms -> :ok
    end
  end

  defp remaining_timeout_ms(deadline_ms) do
    max(deadline_ms - System.monotonic_time(:millisecond), 0)
  end
end
