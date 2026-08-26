defmodule Orchard.Node.WorkerProcessLifecycle do
  @moduledoc """
  OS-level primitives for managing worker subprocesses.

  These helpers intentionally avoid BEAM abstractions: they operate directly on
  Unix PIDs so cleanup can continue even when the process that opened the port
  has already exited.

  A PID alone is not proof of custody once the BEAM has relinquished the port:
  the kernel is free to recycle it for an unrelated process. `process_identity/1`
  captures an owner/start-time snapshot at launch, and the `*_owned_*` helpers
  refuse to signal a PID whose snapshot no longer matches.

  Custody refusal has two distinct reasons and neither one signals.
  `:identity_mismatch` means the PID is live but belongs to something else — the
  security-relevant case, logged as a warning. `:identity_unavailable` covers
  both a missing launch snapshot, warned because it leaves an owned child
  unsignallable, and a target that has already exited, the ordinary outcome of a
  shutdown race, logged at debug.
  """

  require Logger

  @poll_interval_ms 25

  @type signal_result :: :ok | {:error, :signal_failed}
  @type custody_refusal :: :identity_mismatch | :identity_unavailable
  @type owned_signal_result :: signal_result() | {:error, custody_refusal()}
  @type custody_identity :: String.t()

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

  @doc """
  Captures the owner uid and process start time of `os_pid`.

  The snapshot deliberately excludes argv: the dev worker wrapper `exec`s the
  venv entrypoint, so argv changes under a stable PID. uid and start time do
  survive `exec`, and a recycled PID cannot reproduce them because reusing a PID
  requires wrapping the whole PID space — far longer than the one-second
  resolution of `lstart`.
  """
  @spec process_identity(non_neg_integer() | nil) ::
          {:ok, custody_identity()} | {:error, :identity_unavailable}
  def process_identity(os_pid) when is_integer(os_pid) and os_pid > 0 do
    args = ["-o", "uid=", "-o", "lstart=", "-p", Integer.to_string(os_pid)]

    case System.cmd("ps", args, stderr_to_stdout: true) do
      {output, 0} -> parse_process_identity(output)
      {_output, _exit_status} -> {:error, :identity_unavailable}
    end
  end

  def process_identity(_), do: {:error, :identity_unavailable}

  @doc """
  Sends `signal` to `os_pid` only while it still matches `identity`.

  A missing identity fails closed because a numeric PID is not custody proof
  after the BEAM Port has closed.
  """
  @spec signal_owned_process(non_neg_integer(), custody_identity() | nil, String.t()) ::
          owned_signal_result()
  def signal_owned_process(os_pid, identity, signal) do
    case confirm_custody(os_pid, identity) do
      :ok -> send_signal(os_pid, signal)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Kills the process tree rooted at `os_pid` only while it still matches `identity`.
  """
  @spec kill_owned_process_tree(non_neg_integer() | nil, custody_identity() | nil) ::
          owned_signal_result()
  def kill_owned_process_tree(os_pid, identity) do
    case confirm_custody(os_pid, identity) do
      :ok -> kill_process_tree(os_pid)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reports whether a `*_owned_*` result was refused for custody reasons.

  Callers use this instead of matching a single reason so a new refusal reason
  can never silently re-arm signalling on an unproven PID.
  """
  @spec custody_refused?(term()) :: boolean()
  def custody_refused?({:error, reason})
      when reason in [:identity_mismatch, :identity_unavailable],
      do: true

  def custody_refused?(_result), do: false

  @doc """
  Waits for `os_pid` to exit by `term_deadline`, then escalates to a
  custody-gated tree kill confirmed by `kill_deadline`.

  Both arguments are absolute `System.monotonic_time(:millisecond)` values, so a
  caller's shutdown budget is spent once across both phases rather than once per
  phase.
  """
  @spec escalate_owned_exit(
          non_neg_integer(),
          custody_identity() | nil,
          integer(),
          integer()
        ) :: :ok | {:error, :timeout} | {:error, custody_refusal()}
  def escalate_owned_exit(os_pid, identity, term_deadline, kill_deadline) do
    case await_exit_until(os_pid, term_deadline) do
      :ok ->
        :ok

      {:error, :timeout} ->
        kill_result = kill_owned_process_tree(os_pid, identity)

        if custody_refused?(kill_result) do
          kill_result
        else
          await_exit_until(os_pid, kill_deadline)
        end
    end
  end

  @doc """
  Removes a worker-owned Unix socket path.

  The reaper must be able to drop the socket even when the worker died without
  running its own adapter unload, so a missing file is success.
  """
  @spec remove_owned_socket(Path.t() | nil) :: :ok | {:error, {:socket_cleanup_failed, term()}}
  def remove_owned_socket(nil), do: :ok

  def remove_owned_socket(socket_path) when is_binary(socket_path) do
    case File.rm(socket_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:socket_cleanup_failed, reason}}
    end
  end

  @doc """
  Polls until `os_pid` has exited or `timeout_ms` elapses.
  """
  @spec await_exit(non_neg_integer(), non_neg_integer()) :: :ok | {:error, :timeout}
  def await_exit(os_pid, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    await_exit_until(os_pid, System.monotonic_time(:millisecond) + timeout_ms)
  end

  @doc """
  Polls until `os_pid` has exited or the absolute monotonic `deadline` passes.
  """
  @spec await_exit_until(non_neg_integer(), integer()) :: :ok | {:error, :timeout}
  def await_exit_until(os_pid, deadline) when is_integer(deadline) do
    cond do
      not os_process_alive?(os_pid) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(@poll_interval_ms)
        await_exit_until(os_pid, deadline)
    end
  end

  defp confirm_custody(os_pid, nil) do
    Logger.warning("worker custody identity unavailable os_pid=#{os_pid}")
    {:error, :identity_unavailable}
  end

  defp confirm_custody(os_pid, identity) when is_binary(identity) do
    case process_identity(os_pid) do
      {:ok, ^identity} ->
        :ok

      {:error, :identity_unavailable} ->
        Logger.debug("worker custody target already exited os_pid=#{os_pid}")
        {:error, :identity_unavailable}

      {:ok, _other_identity} ->
        Logger.warning("worker custody identity mismatch os_pid=#{os_pid}")
        {:error, :identity_mismatch}
    end
  end

  defp parse_process_identity(output) do
    case output |> String.trim() |> String.replace(~r/\s+/, " ") do
      "" -> {:error, :identity_unavailable}
      identity -> {:ok, identity}
    end
  end

  defp signal_name("-TERM"), do: "TERM"
  defp signal_name("-KILL"), do: "KILL"
  defp signal_name(_signal), do: "unknown"
end
