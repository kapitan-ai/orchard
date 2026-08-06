defmodule OrchardCLI.SecretTTY do
  @moduledoc false

  @setup_error "could not disable terminal echo; refusing to read secret input"
  @restore_error "could not restore the prior terminal state; Console credentials were not saved"
  @timeout_ms 10_000

  @type read_result :: {:ok, String.t()} | :eof | {:error, String.t()}
  @type reader :: (String.t() -> read_result())

  @spec available?() :: boolean()
  def available? do
    match?({:ok, _path}, controlling_tty_path()) and
      match?({:ok, _group}, foreground_process_group()) and
      match?({:ok, _custody}, terminal_custody()) and is_binary(helper_path())
  end

  @spec run((reader() -> result), keyword()) :: result | {:error, String.t()}
        when result: var
  def run(callback, opts \\ []) when is_function(callback, 1) do
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    with {:ok, tty_path} <- tty_path(opts),
         {:ok, foreground_group} <- foreground_group(opts),
         {:ok, custody} <- terminal_custody(),
         {:ok, port} <- open_helper(tty_path, foreground_group, custody, opts),
         :ok <- await_ready(port, timeout) do
      execute(port, callback)
    else
      {:error, :tty} -> {:error, "interactive terminal unavailable"}
      {:error, :open} -> {:error, "interactive terminal unavailable"}
      {:error, :setup} -> {:error, @setup_error}
    end
  end

  defp tty_path(opts) do
    case Keyword.fetch(opts, :tty_path) do
      {:ok, path} -> {:ok, path}
      :error -> controlling_tty_path()
    end
  end

  defp foreground_group(opts) do
    case Keyword.fetch(opts, :foreground_group) do
      {:ok, group} when is_integer(group) and group > 1 -> {:ok, group}
      {:ok, _group} -> {:error, :tty}
      :error -> foreground_process_group()
    end
  end

  defp controlling_tty_path do
    case System.cmd("/bin/ps", ["-o", "tty=", "-p", System.pid()], stderr_to_stdout: true) do
      {output, 0} -> normalize_tty_name(output)
      _other -> {:error, :tty}
    end
  end

  defp normalize_tty_name(output) do
    name = String.trim(output)

    if Regex.match?(~r/\A[A-Za-z0-9]+\z/, name) do
      {:ok, Path.join("/dev", name)}
    else
      {:error, :tty}
    end
  end

  defp foreground_process_group do
    args = ["-o", "pgid=", "-o", "tpgid=", "-p", System.pid()]

    case System.cmd("/bin/ps", args, stderr_to_stdout: true) do
      {output, 0} -> normalize_foreground_group(output)
      _other -> {:error, :tty}
    end
  end

  defp normalize_foreground_group(output) do
    case output |> String.split() |> Enum.map(&Integer.parse/1) do
      [{group, ""}, {group, ""}] when group > 1 -> {:ok, group}
      _other -> {:error, :tty}
    end
  end

  defp execute(port, callback) do
    reader = fn prompt -> read_value(port, prompt) end

    try do
      result = callback.(reader)

      case restore(port, :infinity) do
        :ok -> result
        {:error, :restore} -> {:error, @restore_error}
      end
    catch
      kind, reason ->
        _result = restore(port, :infinity)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      close_port(port)
    end
  end

  defp open_helper(tty_path, foreground_group, {completion_dir, completion_identity}, opts) do
    case helper_path(opts) do
      path when is_binary(path) ->
        args =
          [
            tty_path,
            Integer.to_string(foreground_group),
            System.pid(),
            "supervisor=#{foreground_supervisor_pid()}",
            "completion=#{completion_dir}",
            "completion-identity=#{completion_identity}"
          ] ++ fault_args(opts)

        port =
          Port.open(
            {:spawn_executable, path},
            [
              :binary,
              :exit_status,
              :use_stdio,
              {:packet, 4},
              args: args
            ]
          )

        {:ok, port}

      nil ->
        {:error, :open}
    end
  rescue
    ArgumentError -> {:error, :open}
  end

  defp helper_path(opts \\ []) do
    name =
      if Keyword.has_key?(opts, :test_fault),
        do: "orchard-secret-tty-test",
        else: "orchard-secret-tty"

    with priv_dir when is_list(priv_dir) <- :code.priv_dir(:orchard_cli),
         path = Path.join(List.to_string(priv_dir), name),
         true <- File.regular?(path) do
      path
    else
      _other -> nil
    end
  end

  defp fault_args(opts) do
    case Keyword.get(opts, :test_fault) do
      nil ->
        []

      fault
      when fault in [
             :partial_protect,
             :post_protect,
             :signal_int,
             :signal_hup,
             :signal_term,
             :signal_kill,
             :marker_pre_ready_kill,
             :watchdog_handshake,
             :watchdog_custody_handshake,
             :watchdog_protected_handshake,
             :restorer_parent_kill,
             :restorer_pre_teardown_kill,
             :restorer_identity_retry,
             :restorer_signal_setup,
             :watchdog_idle,
             :watchdog_read
           ] ->
        [fault |> Atom.to_string() |> String.replace("_", "-")]

      _other ->
        ["invalid"]
    end
  end

  defp foreground_supervisor_pid do
    case System.get_env("ORCHARD_CLI_FOREGROUND_SUPERVISOR_PID") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {pid, ""} when pid > 1 -> Integer.to_string(pid)
          _other -> System.pid()
        end

      nil ->
        System.pid()
    end
  end

  defp terminal_custody do
    directory = System.get_env("ORCHARD_CLI_COMPLETION_DIR")
    identity = System.get_env("ORCHARD_CLI_COMPLETION_IDENTITY")

    if is_binary(directory) and Path.type(directory) == :absolute and
         is_binary(identity) and Regex.match?(~r/\A[0-9]+:[0-9]+\z/, identity) do
      {:ok, {directory, identity}}
    else
      {:error, :open}
    end
  end

  defp await_ready(port, timeout) do
    case await_packet(port, timeout) do
      {:ok, "PREPARED"} -> enter_protected_mode(port)
      _other -> close_with_error(port, :setup)
    end
  end

  defp enter_protected_mode(port) do
    if command(port, "ENTER") do
      case await_packet(port, :infinity) do
        {:ok, "READY"} -> :ok
        _other -> close_with_error(port, :setup)
      end
    else
      close_with_error(port, :setup)
    end
  end

  defp read_value(port, prompt) do
    if command(port, "READ:" <> prompt) do
      case await_packet(port, :infinity) do
        {:ok, "VALUE:" <> value} -> {:ok, value}
        {:ok, "EOF"} -> :eof
        _other -> {:error, "unable to read Console credential prompt input"}
      end
    else
      {:error, "unable to read Console credential prompt input"}
    end
  end

  defp restore(port, timeout) do
    if command(port, "RESTORE") do
      case await_packet(port, timeout) do
        {:ok, "RESTORED"} -> :ok
        _other -> {:error, :restore}
      end
    else
      {:error, :restore}
    end
  end

  defp command(port, message) do
    Port.info(port) != nil and Port.command(port, message)
  rescue
    ArgumentError -> false
  end

  defp await_packet(port, timeout) do
    receive do
      {^port, {:data, data}} -> {:ok, data}
      {^port, {:exit_status, _status}} -> {:error, :closed}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp close_with_error(port, reason) do
    close_port(port)
    {:error, reason}
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
