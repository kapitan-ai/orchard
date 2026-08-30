defmodule Orchard.Config.TestNodeAgentPort do
  @moduledoc false

  @default_port 15_071
  @linux_ephemeral_range_path "/proc/sys/net/ipv4/ip_local_port_range"

  @type range :: {pos_integer(), pos_integer()} | nil

  @spec resolve!(nil | binary(), range()) :: pos_integer()
  def resolve!(value, ephemeral_range) do
    value
    |> parse_port!()
    |> reject_ephemeral!(ephemeral_range)
  end

  @spec local_ephemeral_range(Path.t()) :: range()
  def local_ephemeral_range(path \\ @linux_ephemeral_range_path) do
    with {:ok, contents} <- File.read(path),
         [low, high] <- String.split(contents, ~r/\s+/, trim: true),
         {low, ""} <- Integer.parse(low),
         {high, ""} <- Integer.parse(high) do
      {low, high}
    else
      _ -> nil
    end
  end

  defp parse_port!(nil), do: @default_port

  defp parse_port!(value) when is_binary(value) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 ->
        port

      _ ->
        raise "ORCHARD_TEST_NODE_AGENT_PORT must be an integer between 1 and 65535, got: #{inspect(value)}"
    end
  end

  defp reject_ephemeral!(port, nil), do: port

  defp reject_ephemeral!(port, {low, high}) when port >= low and port <= high do
    raise """
    ORCHARD_TEST_NODE_AGENT_PORT #{port} lies inside this host's ephemeral port range #{low}-#{high}.

    The kernel can hand that port to an unrelated outbound socket, making the
    node-agent test listener fail with :eaddrinuse. Choose a fixed test port
    outside #{low}-#{high} (Orchard defaults to #{@default_port}), or widen the
    ephemeral floor via #{@linux_ephemeral_range_path}.
    """
  end

  defp reject_ephemeral!(port, {_low, _high}), do: port
end
