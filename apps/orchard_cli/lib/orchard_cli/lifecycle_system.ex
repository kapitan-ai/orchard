defmodule OrchardCLI.LifecycleSystem do
  @moduledoc false

  alias OrchardCLI.LifecycleNative

  @support_root "/Library/Application Support/Orchard/support"
  @lock_path Path.join(@support_root, ".app-lifecycle.lock")

  @spec with_lock((LifecycleNative.lock() -> result)) :: result | {:error, term()}
        when result: var
  def with_lock(callback) do
    with :ok <- ensure_trusted_directory(@support_root) do
      LifecycleNative.with_lock(@lock_path, callback)
    end
  end

  @spec lock_valid(LifecycleNative.lock()) :: :ok | {:error, term()}
  def lock_valid(lock), do: LifecycleNative.lock_valid(lock)

  @spec job_state(map()) :: :loaded | :unloaded | {:unknown, term()}
  def job_state(service) do
    case launchctl(["print", "system/#{service.label}"]) do
      {_output, 0} ->
        :loaded

      {output, 113} ->
        if(not_found?(output), do: :unloaded, else: {:unknown, {113, summary(output)}})

      {output, code} ->
        {:unknown, {code, summary(output)}}
    end
  end

  @spec process_snapshot(map()) :: {:ok, [map()]} | {:error, term()}
  def process_snapshot(service) do
    case launchctl(["print", "system/#{service.label}"]) do
      {output, 0} ->
        case job_pid(output) do
          pid when is_integer(pid) -> LifecycleNative.process_snapshot(pid)
          :missing -> LifecycleNative.process_snapshot()
          :ambiguous -> {:error, :ambiguous_launchd_pid}
        end

      {output, 113} ->
        if not_found?(output),
          do: LifecycleNative.process_snapshot(),
          else: {:error, {:launchd_pid_observation_failed, 113, summary(output)}}

      {output, code} ->
        {:error, {:launchd_pid_observation_failed, code, summary(output)}}
    end
  end

  @doc "Parses one service's PID from launchctl print output."
  @spec job_pid(String.t()) :: pos_integer() | :missing | :ambiguous
  def job_pid(output) do
    case Regex.scan(~r/^\s*pid\s*=\s*(\d+)\s*$/m, output, capture: :all_but_first) do
      [[pid]] ->
        case Integer.parse(pid) do
          {value, ""} when value > 1 -> value
          _invalid -> :ambiguous
        end

      [] ->
        :missing

      _matches ->
        :ambiguous
    end
  end

  @spec bootout(LifecycleNative.lock(), map()) :: :ok | {:error, term()}
  def bootout(lock, service) do
    LifecycleNative.bootout(lock, "system/#{service.label}")
  end

  @spec signal_process(LifecycleNative.lock(), map()) :: :ok | {:error, term()}
  def signal_process(lock, identity), do: LifecycleNative.signal_process(lock, identity)

  @spec process_identity_state(map()) :: :alive | :exited | :reused | {:unknown, term()}
  def process_identity_state(identity), do: LifecycleNative.process_identity_state(identity)

  defp ensure_trusted_directory(path) do
    path
    |> Path.split()
    |> Enum.reduce_while({:ok, ""}, fn component, {:ok, current} ->
      candidate = if component == "/", do: "/", else: Path.join(current, component)

      case File.lstat(candidate) do
        {:ok, stat} -> trusted_directory_component(stat, candidate)
        {:error, reason} -> {:halt, {:error, {reason, candidate}}}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp trusted_directory_component(stat, candidate) do
    if stat.type == :directory and trusted_owner?(stat) and
         Bitwise.band(stat.mode, 0o022) == 0 do
      {:cont, {:ok, candidate}}
    else
      {:halt, {:error, {:unsafe_directory_component, candidate}}}
    end
  end

  defp trusted_owner?(stat), do: stat.uid == 0

  defp launchctl(args), do: LifecycleNative.run_command("/bin/launchctl", args, 5_000)

  defp not_found?(output) do
    String.contains?(output, "Could not find service") or
      String.contains?(output, "service not found")
  end

  defp summary(output) do
    output
    |> String.trim()
    |> String.split("\n", trim: true)
    |> List.first()
    |> case do
      nil -> "no output"
      line -> line
    end
  end
end
