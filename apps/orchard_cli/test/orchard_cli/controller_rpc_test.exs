defmodule OrchardCLI.ControllerRPCTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias OrchardCLI.Commands.Nodes
  alias OrchardCLI.ControllerRPC

  test "SPEC 11.9 packages node admission results for Controller-runtime RPC" do
    encoded_args = encode_args(["nodes", "admit", "--help"])
    expected = Nodes.run(["admit", "--help"])

    assert decode_envelope(ControllerRPC.run_base64(encoded_args)) ==
             {:stdout, 0, elem(expected, 1)}
  end

  test "Controller RPC allowlist matches every packaged authoritative node command" do
    for command <- ~w(
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
        ) do
      assert {:stdout, 0, _message} =
               ["nodes", command, "--help"]
               |> encode_args()
               |> ControllerRPC.run_base64()
               |> decode_envelope()
    end
  end

  test "SPEC 11.9 preserves node command errors without halting the Controller" do
    encoded_args = encode_args(["nodes", "admit"])
    {:error, expected_message, expected_status} = Nodes.run(["admit"])

    assert decode_envelope(ControllerRPC.run_base64(encoded_args)) ==
             {:stderr, expected_status, expected_message}
  end

  test "SPEC 11.9 RPC entrypoint writes exactly one transport envelope" do
    encoded_args = encode_args(["nodes", "pending", "--help"])

    output = capture_io(fn -> assert :ok = ControllerRPC.main_base64(encoded_args) end)

    assert [envelope] = String.split(output, "\n", trim: true)
    assert {:stdout, 0, message} = decode_envelope(envelope)
    assert message =~ "orchardctl nodes pending"
  end

  test "RPC bridge rejects commands outside the Controller-runtime authority set" do
    for args <- [
          ["status"],
          ["nodes", "enrollment", "create"],
          ["nodes", "trust", "init"],
          ["nodes", "unknown"]
        ] do
      assert {:stderr, 1, "Error: command is not available through Controller runtime RPC."} =
               args |> encode_args() |> ControllerRPC.run_base64() |> decode_envelope()
    end
  end

  test "RPC bridge rejects malformed Base64 arguments" do
    assert {:stderr, 1, "Error: invalid Controller runtime RPC arguments."} =
             ["%%%"] |> ControllerRPC.run_base64() |> decode_envelope()
  end

  defp encode_args(args), do: Enum.map(args, &Base.encode64/1)

  defp decode_envelope(envelope) do
    assert ["ORCHARDCTL_RPC_V1", status, stream, encoded_message] =
             String.split(envelope, ":", parts: 4)

    assert {status, ""} = Integer.parse(status)
    assert {:ok, message} = Base.decode64(encoded_message)

    {String.to_existing_atom(stream), status, message}
  end
end
