defmodule OrchardCLI.ControllerRPC do
  @moduledoc false

  alias OrchardCLI.Commands.Nodes

  @protocol "ORCHARDCTL_RPC_V1"
  @controller_commands ~w(
    list
    inspect
    pending
    admit
    reject
    cordon
    uncordon
    drain
    cancel-drain
    maintenance
    resume
    decommission
  )

  @doc "Executes an encoded packaged node command and writes one result envelope to the RPC caller."
  @spec main_base64([String.t()]) :: :ok
  def main_base64(encoded_args) do
    caller_group_leader = Process.group_leader()
    envelope = with_isolated_group_leader(fn -> run_base64(encoded_args) end)
    IO.puts(caller_group_leader, envelope)
  end

  @doc "Decodes an encoded packaged node command and returns its versioned RPC result envelope."
  @spec run_base64([String.t()]) :: String.t()
  def run_base64(encoded_args) when is_list(encoded_args) do
    with {:ok, args} <- decode_arguments(encoded_args),
         {:ok, node_args} <- controller_node_args(args) do
      node_args
      |> Nodes.run()
      |> encode_result()
    else
      {:error, :invalid_arguments} ->
        encode_result({:error, "Error: invalid Controller runtime RPC arguments.", 1})

      {:error, :command_not_allowed} ->
        encode_result(
          {:error, "Error: command is not available through Controller runtime RPC.", 1}
        )
    end
  end

  defp with_isolated_group_leader(fun) do
    caller_group_leader = Process.group_leader()
    {:ok, sink} = StringIO.open("")
    true = Process.group_leader(self(), sink)

    try do
      fun.()
    after
      Logger.flush()
      true = Process.group_leader(self(), caller_group_leader)
      StringIO.close(sink)
    end
  end

  defp decode_arguments(encoded_args) do
    Enum.reduce_while(encoded_args, {:ok, []}, fn encoded, {:ok, decoded} ->
      case Base.decode64(encoded) do
        {:ok, argument} -> {:cont, {:ok, [argument | decoded]}}
        :error -> {:halt, {:error, :invalid_arguments}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp controller_node_args(["nodes", command | rest]) when command in @controller_commands,
    do: {:ok, [command | rest]}

  defp controller_node_args(_args), do: {:error, :command_not_allowed}

  defp encode_result(:ok), do: envelope(0, "none", "")
  defp encode_result({:ok, message}), do: envelope(0, "stdout", message)
  defp encode_result({:error, message, status}), do: envelope(status, "stderr", message)

  defp envelope(status, stream, message) do
    Enum.join([@protocol, status, stream, Base.encode64(message)], ":")
  end
end
