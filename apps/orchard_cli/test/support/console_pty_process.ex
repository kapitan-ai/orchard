defmodule OrchardCLI.ConsolePTYProcess do
  @moduledoc false

  alias OrchardCLI.Commands.Console
  alias OrchardCLI.SecretTTY

  @spec main([String.t()]) :: no_return()
  def main([action, support_root, side_effect_marker]) when action in ["enable", "rotate"] do
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

  def main(["exception", _support_root, _side_effect_marker]) do
    SecretTTY.run(fn reader ->
      {:ok, _value} = reader.("Console username: ")
      raise "test callback failure"
    end)

    await_harness(65)
  rescue
    RuntimeError -> await_harness(70)
  end

  def main(["setup-failure", _support_root, side_effect_marker]) do
    result =
      SecretTTY.run(
        fn _reader ->
          File.write!(side_effect_marker, "callback-entered\n")
          {:ok, :unexpected}
        end,
        stty_path: "/usr/bin/false"
      )

    halt_with_result(normalize_direct_result(result))
  end

  def main(_args), do: System.halt(64)

  defp normalize_direct_result({:error, message}), do: {:error, "Error: #{message}", 1}
  defp normalize_direct_result({:ok, _value}), do: {:ok, "unexpected success"}

  defp command_recorder(side_effect_marker) do
    fn _program, _args, _opts ->
      File.write!(side_effect_marker, "invoked\n", [:append])
      {"Could not find service", 113}
    end
  end

  defp halt_with_result({:ok, message}) do
    IO.puts(message)
    await_harness(0)
  end

  defp halt_with_result({:error, message, code}) do
    IO.puts(:stderr, message)
    await_harness(code)
  end

  defp await_harness(code) do
    IO.puts("__ORCHARD_PTY_RESULT__:#{code}")
    Process.sleep(:infinity)
  end
end
