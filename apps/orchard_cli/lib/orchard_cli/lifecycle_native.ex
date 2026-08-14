defmodule OrchardCLI.LifecycleNative do
  @moduledoc false

  @lock_timeout_ms 5_000

  @type lock :: %{
          required(:port) => port(),
          required(:owner) => pid(),
          required(:path) => String.t(),
          required(:guard_identity) => process_identity(),
          required(:lock_device) => non_neg_integer(),
          required(:lock_inode) => non_neg_integer()
        }
  @type process_identity :: %{required(String.t()) => integer() | String.t()}

  @spec with_lock(String.t(), (lock() -> result)) :: result | {:error, term()} when result: var
  def with_lock(path, callback) when is_binary(path) and is_function(callback, 1) do
    with {:ok, port} <- open_lock(path),
         {:ok, metadata} <- await_lock(port) do
      lock = Map.merge(metadata, %{port: port, owner: self(), path: path})

      try do
        result = callback.(lock)

        case release_lock(port) do
          :ok -> result
          {:error, reason} -> {:error, reason}
        end
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          _release_result = release_lock(port)
          :erlang.raise(kind, reason, stacktrace)
      end
    end
  end

  @spec lock_valid(lock()) :: :ok | {:error, :exclusion_lost | :not_owner}
  def lock_valid(%{port: port, owner: owner}) do
    cond do
      owner != self() -> {:error, :not_owner}
      Port.info(port) == nil -> {:error, :exclusion_lost}
      Port.command(port, "CHECK\n") -> await_lock_check(port)
      true -> {:error, :exclusion_lost}
    end
  rescue
    ArgumentError -> {:error, :exclusion_lost}
  end

  @spec ensure_private_directory(lock(), String.t()) :: :ok | {:error, term()}
  def ensure_private_directory(%{port: port, owner: owner}, path) do
    guard_command(port, owner, ["PRIVATE\n", path, "\n"], "PRIVATE_READY")
  end

  @spec atomic_publish(lock(), String.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def atomic_publish(%{port: port, owner: owner}, destination, contents, options \\ []) do
    directory = Path.dirname(destination)
    staging_directory = Keyword.get(options, :staging_directory, directory)

    temporary =
      Path.join(staging_directory, ".#{Path.basename(destination)}.tmp-#{random_suffix()}")

    try do
      with :ok <- write_temporary(temporary, contents) do
        guard_command(
          port,
          owner,
          ["PUBLISH\n", temporary, "\n", destination, "\n"],
          "PUBLISHED"
        )
      end
    after
      File.rm(temporary)
    end
  end

  @spec disable_job(lock(), String.t()) :: :ok | {:error, term()}
  def disable_job(%{port: port, owner: owner}, label) do
    guard_command(port, owner, ["DISABLE\n", label, "\n"], "DISABLED", 12_000)
  end

  @spec bootout(lock(), String.t()) :: :ok | {:error, term()}
  def bootout(%{port: port, owner: owner}, plist_path) do
    guard_command(
      port,
      owner,
      ["BOOTOUT\n", plist_path, "\n"],
      ["BOOTED_OUT", "BOOTOUT_ABSENT"],
      12_000
    )
  end

  @spec process_identity(String.t() | pos_integer()) ::
          {:ok, process_identity()} | {:error, term()}
  def process_identity(pid) do
    case helper_command(["identity", to_string(pid)]) do
      {output, 0} -> Jason.decode(output)
      {_output, 3} -> {:error, :exited}
      {output, code} -> {:error, {:identity_failed, code, String.trim(output)}}
    end
  end

  @spec process_snapshot(pos_integer() | nil) ::
          {:ok, [process_identity()]} | {:error, term()}
  def process_snapshot(expected_pid \\ nil) do
    args = if is_nil(expected_pid), do: ["snapshot"], else: ["snapshot", to_string(expected_pid)]

    case helper_command(args) do
      {output, 0} -> Jason.decode(output)
      {output, code} -> {:error, {:snapshot_failed, code, String.trim(output)}}
    end
  end

  @spec process_identity_state(process_identity()) ::
          :alive | :exited | :reused | {:unknown, term()}
  def process_identity_state(identity) do
    args = [
      "identity-state",
      to_string(identity["pid"] || identity[:pid]),
      to_string(identity["start_sec"] || identity[:start_sec]),
      to_string(identity["start_usec"] || identity[:start_usec])
    ]

    case helper_command(args) do
      {"ALIVE\n", 0} -> :alive
      {"EXITED\n", 0} -> :exited
      {"REUSED\n", 0} -> :reused
      {output, code} -> {:unknown, {:identity_state_failed, code, String.trim(output)}}
    end
  end

  @spec signal_process(lock(), process_identity()) :: :ok | {:error, term()}
  def signal_process(%{port: port, owner: owner}, identity) do
    command = [
      "SIGNAL\n",
      to_string(identity["pid"] || identity[:pid]),
      "\n",
      to_string(identity["start_sec"] || identity[:start_sec]),
      "\n",
      to_string(identity["start_usec"] || identity[:start_usec]),
      "\n"
    ]

    guard_command(port, owner, command, ["SIGNALED", "SIGNAL_EXITED"])
  end

  defp open_lock(path) do
    port =
      Port.open(
        {:spawn_executable, helper_path()},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:line, 1024},
          args: ["lock", path]
        ]
      )

    {:ok, port}
  rescue
    error in ArgumentError -> {:error, {:helper_open_failed, Exception.message(error)}}
  end

  defp await_lock(port) do
    receive do
      {^port, {:data, {:eol, "READY " <> encoded}}} ->
        case Jason.decode(encoded) do
          {:ok,
           %{
             "guard_identity" => guard_identity,
             "lock_device" => lock_device,
             "lock_inode" => lock_inode
           }} ->
            {:ok,
             %{
               guard_identity: guard_identity,
               lock_device: lock_device,
               lock_inode: lock_inode
             }}

          _invalid ->
            Port.close(port)
            {:error, :invalid_lock_metadata}
        end

      {^port, {:exit_status, 75}} ->
        {:error, :locked}

      {^port, {:exit_status, code}} ->
        {:error, {:lock_failed, code}}
    after
      @lock_timeout_ms ->
        Port.close(port)
        {:error, :lock_timeout}
    end
  end

  defp await_lock_check(port) do
    receive do
      {^port, {:data, {:eol, "LOCKED"}}} -> :ok
      {^port, {:exit_status, _code}} -> {:error, :exclusion_lost}
      {^port, {:data, _data}} -> {:error, :exclusion_lost}
    after
      @lock_timeout_ms -> {:error, :exclusion_lost}
    end
  end

  defp guard_command(port, owner, command, expected, timeout \\ @lock_timeout_ms) do
    expected = List.wrap(expected)

    cond do
      owner != self() ->
        {:error, :not_owner}

      Port.info(port) == nil ->
        {:error, :exclusion_lost}

      Port.command(port, command) ->
        receive do
          {^port, {:data, {:eol, response}}} ->
            if response in expected, do: :ok, else: {:error, {:guard_rejected, response}}

          {^port, {:exit_status, _code}} ->
            {:error, :exclusion_lost}

          {^port, {:data, _data}} ->
            {:error, :exclusion_lost}
        after
          timeout -> {:error, :guard_timeout}
        end

      true ->
        {:error, :exclusion_lost}
    end
  rescue
    ArgumentError -> {:error, :exclusion_lost}
  end

  defp release_lock(port) do
    if Port.info(port) != nil and Port.command(port, "RELEASE\n") do
      await_exit(port)
    else
      {:error, :lock_release_lost}
    end
  rescue
    ArgumentError -> {:error, :lock_release_lost}
  end

  defp await_exit(port) do
    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, code}} -> {:error, {:lock_release_failed, code}}
      {^port, {:data, _data}} -> await_exit(port)
    after
      @lock_timeout_ms ->
        Port.close(port)
        {:error, :lock_release_timeout}
    end
  end

  defp write_temporary(path, contents) do
    with {:ok, file} <- File.open(path, [:write, :binary, :exclusive]),
         :ok <- IO.binwrite(file, contents),
         :ok <- :file.sync(file),
         :ok <- File.close(file) do
      File.chmod(path, 0o600)
    end
  end

  @spec run_command(String.t(), [String.t()], non_neg_integer()) :: {String.t(), integer()}
  def run_command(executable, args, timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: args]
      )

    await_command(port, [], System.monotonic_time(:millisecond) + timeout_ms)
  rescue
    error in ArgumentError -> {Exception.message(error), 127}
  end

  defp helper_command(args), do: run_command(helper_path(), args, @lock_timeout_ms)

  defp await_command(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> await_command(port, [output, data], deadline)
      {^port, {:exit_status, code}} -> {IO.iodata_to_binary(output), code}
    after
      remaining ->
        Port.close(port)
        {IO.iodata_to_binary(output), 124}
    end
  end

  defp helper_path do
    :orchard_cli
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join("orchard-lifecycle-helper")
  end

  defp random_suffix do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
