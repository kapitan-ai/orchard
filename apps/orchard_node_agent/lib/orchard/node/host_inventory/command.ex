defmodule Orchard.Node.HostInventory.Command do
  @moduledoc """
  Bounded read-only probe runner for host inventory providers (`SPEC.md` §4.1).

  Probes run only absolute allowlisted executables. Ambient `PATH` lookup is
  never used, the inherited environment is cleared, and the locale is forced to
  `C` so tool output is parseable. Each probe runs under a verified GNU
  coreutils `timeout` guardian, which places the probe in its own process group
  and owns its TERM and KILL deadline even if the Node Agent process dies.
  Orchard sends no signal itself, so it can never reach an unrelated process.
  """

  import Bitwise

  @type error ::
          :missing_tool
          | :guardian_unavailable
          | :command_timeout
          | :output_too_large
          | :permission_denied
          | :command_failed

  @probe_env [{"LC_ALL", "C"}, {"LANG", "C"}, {"PATH", "/usr/bin:/bin"}]
  @guardian_version_deadline_ms 2_000
  @guardian_version_max_bytes 4_096
  @default_timeout_ms 2_000
  @default_kill_after_ms 1_000
  @default_max_output_bytes 1_048_576
  @backstop_grace_ms 500

  @doc "Returns the first candidate that is an absolute, regular, executable file."
  @spec resolve([String.t()]) :: {:ok, String.t()} | {:error, :missing_tool}
  def resolve(candidates) when is_list(candidates) do
    case Enum.find(candidates, &executable_file?/1) do
      nil -> {:error, :missing_tool}
      path -> {:ok, path}
    end
  end

  @doc """
  Returns the first resolvable guardian candidate whose `--version` identifies
  GNU coreutils `timeout`. Any other implementation is unavailable, because its
  process-group and escalation semantics are not verified.
  """
  @spec guardian([String.t()]) :: {:ok, String.t()} | {:error, :guardian_unavailable}
  def guardian(candidates) when is_list(candidates) do
    with {:ok, path} <- resolve(candidates),
         {:ok, output} <-
           spawn_bounded(
             path,
             ["--version"],
             @guardian_version_deadline_ms,
             @guardian_version_max_bytes
           ),
         [first_line | _] <- String.split(output, "\n"),
         true <- String.starts_with?(first_line, "timeout (GNU coreutils) ") do
      {:ok, path}
    else
      _unverified -> {:error, :guardian_unavailable}
    end
  end

  @doc """
  Runs `executable` with `args` under a verified `guardian` and returns its
  bounded output.

  Options: `:timeout_ms` (TERM deadline), `:kill_after_ms` (KILL escalation),
  and `:max_output_bytes`. A Node-side backstop closes the port shortly after
  the guardian's own deadline.
  """
  @spec run(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, binary()} | {:error, error()}
  def run(guardian, executable, args, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    kill_after_ms = Keyword.get(opts, :kill_after_ms, @default_kill_after_ms)
    max_bytes = Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)

    guarded_args = [
      "--signal=TERM",
      "--kill-after=#{seconds(kill_after_ms)}",
      seconds(timeout_ms),
      executable | args
    ]

    spawn_bounded(
      guardian,
      guarded_args,
      timeout_ms + kill_after_ms + @backstop_grace_ms,
      max_bytes
    )
  end

  defp seconds(milliseconds) do
    fraction = milliseconds |> rem(1_000) |> Integer.to_string() |> String.pad_leading(3, "0")
    "#{div(milliseconds, 1_000)}.#{fraction}s"
  end

  defp executable_file?(path) when is_binary(path) do
    Path.type(path) == :absolute and
      match?(
        {:ok, %File.Stat{type: :regular, mode: mode}} when (mode &&& 0o111) != 0,
        File.stat(path)
      )
  end

  defp executable_file?(_path), do: false

  defp spawn_bounded(executable, args, deadline_ms, max_bytes) do
    with {:ok, port} <- open(executable, args) do
      collect(port, [], 0, max_bytes, System.monotonic_time(:millisecond) + deadline_ms)
    end
  end

  # The verified executable can vanish or lose permission before it starts.
  defp open(executable, args) do
    {:ok,
     Port.open({:spawn_executable, executable}, [
       :binary,
       :exit_status,
       :stderr_to_stdout,
       :hide,
       args: args,
       env: probe_env()
     ])}
  rescue
    error in ErlangError -> {:error, start_error(error.original)}
  end

  defp start_error(reason) when reason in [:enoent, :eacces], do: :guardian_unavailable
  defp start_error(_reason), do: :command_failed

  defp probe_env do
    cleared = for {name, _value} <- System.get_env(), do: {String.to_charlist(name), false}

    cleared ++
      for {name, value} <- @probe_env, do: {String.to_charlist(name), String.to_charlist(value)}
  end

  defp collect(port, chunks, size, max_bytes, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when size + byte_size(data) <= max_bytes ->
        collect(port, [data | chunks], size + byte_size(data), max_bytes, deadline)

      {^port, {:data, _data}} ->
        close(port)
        {:error, :output_too_large}

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        {:error, exit_error(status)}
    after
      remaining ->
        close(port)
        {:error, :command_timeout}
    end
  end

  # GNU timeout: 124 deadline reached, 137 killed after the grace period,
  # 126 probe not executable, 127 probe not found.
  defp exit_error(status) when status in [124, 137], do: :command_timeout
  defp exit_error(126), do: :permission_denied
  defp exit_error(127), do: :missing_tool
  defp exit_error(_status), do: :command_failed

  defp close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end
end
