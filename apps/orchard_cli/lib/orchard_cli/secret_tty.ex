defmodule OrchardCLI.SecretTTY do
  @moduledoc false

  @setup_error "could not disable terminal echo; refusing to read secret input"
  @restore_error "could not restore the prior terminal state; Console credentials were not saved"
  @protocol_limit 16_384
  @timeout_ms 5_000

  @type read_result :: {:ok, String.t()} | :eof | {:error, String.t()}
  @type reader :: (String.t() -> read_result())

  @spec available?() :: boolean()
  def available? do
    match?({:ok, _path}, controlling_tty_path())
  end

  @spec run((reader() -> result), keyword()) :: result | {:error, String.t()}
        when result: var
  def run(callback, opts \\ []) when is_function(callback, 1) do
    stty_path = Keyword.get(opts, :stty_path, "/bin/stty")
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    with {:ok, tty_path} <- tty_path(opts),
         {:ok, port} <- open_guard(tty_path, stty_path),
         :ok <- await_ready(port, timeout) do
      execute(port, callback, timeout)
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

  defp execute(port, callback, timeout) do
    reader = fn prompt -> read_value(port, prompt) end

    try do
      result = callback.(reader)

      case restore(port, timeout) do
        :ok -> result
        {:error, :restore} -> {:error, @restore_error}
      end
    catch
      kind, reason ->
        _result = restore(port, timeout)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      close_port(port)
    end
  end

  defp open_guard(tty_path, stty_path) do
    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          :binary,
          :exit_status,
          :use_stdio,
          args: ["-c", guard_script(), "orchard-secret-tty", tty_path, stty_path]
        ]
      )

    {:ok, port}
  rescue
    ArgumentError -> {:error, :open}
  end

  defp await_ready(port, timeout) do
    case await_line(port, timeout, "") do
      {:ok, "READY"} ->
        :ok

      _other ->
        close_port(port)
        {:error, :setup}
    end
  end

  defp read_value(port, prompt) do
    command = "READ:" <> Base.encode64(prompt) <> "\n"

    if Port.command(port, command) do
      case await_line(port, :infinity, "") do
        {:ok, "VALUE:" <> encoded} -> decode_value(encoded)
        {:ok, "EOF"} -> :eof
        _other -> {:error, "unable to read Console credential prompt input"}
      end
    else
      {:error, "unable to read Console credential prompt input"}
    end
  end

  defp decode_value(encoded) do
    case Base.decode64(encoded) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "unable to read Console credential prompt input"}
    end
  end

  defp restore(port, timeout) do
    if Port.command(port, "RESTORE\n") do
      case await_line(port, timeout, "") do
        {:ok, "RESTORED"} -> :ok
        _other -> {:error, :restore}
      end
    else
      {:error, :restore}
    end
  end

  defp await_line(_port, _timeout, buffer) when byte_size(buffer) > @protocol_limit,
    do: {:error, :protocol}

  defp await_line(port, timeout, buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [line, _rest] ->
        {:ok, String.trim_trailing(line, "\r")}

      [_partial] ->
        receive do
          {^port, {:data, data}} -> await_line(port, timeout, buffer <> data)
          {^port, {:exit_status, _status}} -> {:error, :closed}
        after
          timeout -> {:error, :timeout}
        end
    end
  end

  defp close_port(port) do
    if Port.info(port) do
      Port.close(port)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp guard_script do
    ~S'''
    tty=$1
    stty=$2

    restore() {
      "$stty" -f "$tty" "$state" >/dev/null 2>&1
    }

    state=$("$stty" -f "$tty" -g 2>/dev/null) || {
      printf 'SETUP_ERROR\n'
      exit 1
    }
    trap '' HUP INT TERM
    "$stty" -f "$tty" -echo -echonl >/dev/null 2>&1 || {
      printf 'SETUP_ERROR\n'
      exit 1
    }
    exec 3<>"$tty" || {
      restore
      printf 'SETUP_ERROR\n'
      exit 1
    }
    umask 077
    pipe_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/orchard-secret-tty.XXXXXX") || {
      restore
      printf 'SETUP_ERROR\n'
      exit 1
    }
    /usr/bin/mkfifo "$pipe_root/events" || {
      /bin/rmdir "$pipe_root"
      restore
      printf 'SETUP_ERROR\n'
      exit 1
    }
    exec 5<>"$pipe_root/events"
    /bin/rm "$pipe_root/events"
    /bin/rmdir "$pipe_root"
    exec 4<&0

    (
      trap - HUP INT TERM
      while IFS= read -r owner_command <&4; do
        printf 'COMMAND:%s\n' "$owner_command" >&5
      done
      printf 'OWNER_EOF\n' >&5
    ) &
    owner_monitor=$!
    tty_reader=

    stop_child() {
      child_pid=$1
      if [ -n "$child_pid" ]; then
        kill "$child_pid" >/dev/null 2>&1
        wait "$child_pid" 2>/dev/null
      fi
    }

    cleanup_children() {
      stop_child "$tty_reader"
      tty_reader=
      stop_child "$owner_monitor"
      owner_monitor=
    }

    printf 'READY\n'

    while IFS= read -r event <&5; do
      case "$event" in
        COMMAND:READ:*)
          if [ -n "$tty_reader" ]; then
            printf 'PROTOCOL_ERROR\n'
            cleanup_children
            restore
            exit 1
          fi
          prompt=${event#COMMAND:READ:}
          (
            trap - HUP INT TERM
            if printf '%s' "$prompt" | /usr/bin/base64 -D >&3 2>/dev/null; then
              if IFS= read -r value <&3; then
                printf '\n' >&3
                encoded=$(printf '%s' "$value" | /usr/bin/base64 -b 0) &&
                  printf 'TTY:VALUE:%s\n' "$encoded" >&5
              else
                printf '\n' >&3
                printf 'TTY:EOF\n' >&5
              fi
            else
              printf 'TTY:READ_ERROR\n' >&5
            fi
          ) &
          tty_reader=$!
          ;;
        TTY:*)
          wait "$tty_reader" 2>/dev/null
          tty_reader=
          printf '%s\n' "${event#TTY:}"
          ;;
        COMMAND:RESTORE)
          cleanup_children
          if restore; then
            printf 'RESTORED\n'
            exit 0
          else
            printf 'RESTORE_ERROR\n'
            exit 1
          fi
          ;;
        OWNER_EOF)
          cleanup_children
          restore
          exit 0
          ;;
        *)
          printf 'PROTOCOL_ERROR\n'
          ;;
      esac
    done

    cleanup_children
    restore
    '''
  end
end
