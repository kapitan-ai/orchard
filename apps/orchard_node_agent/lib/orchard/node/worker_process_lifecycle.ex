defmodule Orchard.Node.WorkerProcessLifecycle do
  @moduledoc """
  OS-level primitives for managing worker subprocesses.

  These helpers intentionally avoid BEAM abstractions: they operate directly on
  Unix PIDs so cleanup can continue even when the process that opened the port
  has already exited.
  """

  require Logger

  @type signal_result :: :ok | {:error, :signal_failed}

  @spec os_process_alive?(non_neg_integer()) :: boolean()
  def os_process_alive?(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      {_, _} -> false
    end
  end

  def os_process_alive?(_), do: false

  @spec send_signal(non_neg_integer(), String.t()) :: signal_result()
  def send_signal(os_pid, signal) when is_integer(os_pid) and os_pid > 0 do
    case System.cmd("kill", [signal, Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {_output, exit_status} ->
        Logger.warning(
          "worker signal failed os_pid=#{os_pid} signal=#{signal_name(signal)} " <>
            "exit_status=#{exit_status}"
        )

        {:error, :signal_failed}
    end
  end

  def send_signal(_, _), do: {:error, :signal_failed}

  @spec kill_process_tree(non_neg_integer() | nil) :: signal_result()
  def kill_process_tree(os_pid) when is_integer(os_pid) and os_pid > 0 do
    {children_output, _} =
      System.cmd("pgrep", ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true)

    children_output
    |> String.trim()
    |> String.split("\n", trim: true)
    |> Enum.each(fn child_pid ->
      case Integer.parse(child_pid) do
        {child_pid_int, _} when child_pid_int > 0 ->
          _ = kill_process_tree(child_pid_int)

        _other ->
          :ok
      end
    end)

    send_signal(os_pid, "-KILL")
  end

  def kill_process_tree(_), do: {:error, :signal_failed}

  defp signal_name("-TERM"), do: "TERM"
  defp signal_name("-KILL"), do: "KILL"
  defp signal_name(_signal), do: "unknown"
end
