defmodule OrchardCLI.ConsolePTYProcess do
  @moduledoc false

  alias OrchardCLI.Commands.Console
  alias OrchardCLI.SecretTTY

  @spec main([String.t()]) :: no_return()
  def main(args) do
    IO.puts("__ORCHARD_OWNER_PID__:#{System.pid()}")
    dispatch(args)
  end

  defp dispatch([action, support_root, side_effect_marker]) when action in ["enable", "rotate"] do
    runtime = %{
      uid: fn -> 0 end,
      read_install_role: fn -> {:ok, "controller"} end,
      tty?: fn -> true end,
      support_root: support_root,
      cmd: command_recorder(side_effect_marker)
    }

    Console.run([action], runtime)
    |> halt_with_result()
  end

  defp dispatch(["exception", _support_root, _side_effect_marker]) do
    SecretTTY.run(fn reader ->
      {:ok, _value} = reader.("Console username: ")
      raise "test callback failure"
    end)

    halt_for_harness(65)
  rescue
    RuntimeError -> halt_for_harness(70)
  end

  defp dispatch(["setup-failure", _support_root, side_effect_marker]) do
    result =
      SecretTTY.run(
        fn _reader ->
          File.write!(side_effect_marker, "callback-entered\n")
          {:ok, :unexpected}
        end,
        test_fault: :partial_protect
      )

    halt_with_result(normalize_direct_result(result))
  end

  defp dispatch([fault, _support_root, side_effect_marker])
       when fault in [
              "post-protect",
              "signal-int",
              "signal-hup",
              "signal-term",
              "signal-kill",
              "marker-pre-ready-kill",
              "watchdog-handshake",
              "watchdog-custody-handshake",
              "watchdog-protected-handshake",
              "restorer-parent-kill",
              "restorer-pre-teardown-kill",
              "restorer-identity-retry",
              "restorer-signal-setup",
              "watchdog-idle",
              "watchdog-read"
            ] do
    test_fault = test_fault(fault)

    result =
      SecretTTY.run(
        fn reader ->
          case reader.("Console username: ") do
            {:ok, _value} ->
              File.write!(side_effect_marker, "callback-completed\n")
              {:ok, :unexpected}

            error ->
              error
          end
        end,
        test_fault: test_fault
      )

    halt_with_result(normalize_direct_result(result))
  end

  defp dispatch(["port-owner-exit", _support_root, _side_effect_marker]) do
    parent = self()

    {owner, reference} =
      spawn_monitor(fn ->
        result =
          SecretTTY.run(fn reader ->
            send(parent, :port_owner_ready)
            reader.("Console username: ")
          end)

        send(parent, {:port_owner_result, result})
      end)

    receive do
      :port_owner_ready -> IO.puts("__ORCHARD_PORT_OWNER_READY__")
      {:port_owner_result, _result} -> halt_for_harness(65)
    after
      5_000 -> halt_for_harness(66)
    end

    Process.sleep(500)
    Process.exit(owner, :kill)

    receive do
      {:DOWN, ^reference, :process, ^owner, :killed} ->
        IO.puts("__ORCHARD_PORT_OWNER_DIED__")

      {:port_owner_result, _result} ->
        halt_for_harness(67)
    after
      5_000 -> halt_for_harness(68)
    end

    Process.sleep(5_000)
    halt_for_harness(1)
  end

  defp dispatch(_args), do: System.halt(64)

  defp normalize_direct_result({:error, message}), do: {:error, "Error: #{message}", 1}
  defp normalize_direct_result({:ok, _value}), do: {:ok, "unexpected success"}

  defp test_fault("post-protect"), do: :post_protect
  defp test_fault("signal-int"), do: :signal_int
  defp test_fault("signal-hup"), do: :signal_hup
  defp test_fault("signal-term"), do: :signal_term
  defp test_fault("signal-kill"), do: :signal_kill
  defp test_fault("marker-pre-ready-kill"), do: :marker_pre_ready_kill
  defp test_fault("watchdog-handshake"), do: :watchdog_handshake
  defp test_fault("watchdog-custody-handshake"), do: :watchdog_custody_handshake
  defp test_fault("watchdog-protected-handshake"), do: :watchdog_protected_handshake
  defp test_fault("restorer-parent-kill"), do: :restorer_parent_kill
  defp test_fault("restorer-pre-teardown-kill"), do: :restorer_pre_teardown_kill
  defp test_fault("restorer-identity-retry"), do: :restorer_identity_retry
  defp test_fault("restorer-signal-setup"), do: :restorer_signal_setup
  defp test_fault("watchdog-idle"), do: :watchdog_idle
  defp test_fault("watchdog-read"), do: :watchdog_read

  defp command_recorder(side_effect_marker) do
    fn _program, _args, _opts ->
      File.write!(side_effect_marker, "invoked\n", [:append])
      {"Could not find service", 113}
    end
  end

  defp halt_with_result({:ok, message}) do
    IO.puts(message)
    halt_for_harness(0)
  end

  defp halt_with_result({:error, message, code}) do
    IO.puts(:stderr, message)
    halt_for_harness(code)
  end

  defp halt_for_harness(code) do
    IO.puts("__ORCHARD_PTY_RESULT__:#{code}")
    Process.sleep(10)
    System.halt(code)
  end
end
