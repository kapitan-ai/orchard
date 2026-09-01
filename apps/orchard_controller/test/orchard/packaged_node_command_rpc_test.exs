defmodule Orchard.PackagedNodeCommandRPCTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Orchard.PackagedNodeCommandRPC

  test "SPEC 11.9 packages node admission results for Controller-runtime RPC" do
    encoded_args = encode_args(["nodes", "admit", "--help"])

    assert {:stdout, 0, message} =
             encoded_args
             |> PackagedNodeCommandRPC.run_base64()
             |> decode_envelope()

    assert message =~ "orchardctl nodes admit"
  end

  test "Controller-owned RPC allowlist matches every packaged authoritative node command" do
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
               |> PackagedNodeCommandRPC.run_base64()
               |> decode_envelope()
    end
  end

  test "SPEC 11.9 preserves node command errors without halting the Controller" do
    encoded_args = encode_args(["nodes", "admit"])

    assert {:stderr, 1, message} =
             encoded_args
             |> PackagedNodeCommandRPC.run_base64()
             |> decode_envelope()

    assert message =~ "orchardctl nodes admit"
  end

  test "SPEC 11.9 RPC entrypoint writes exactly one transport envelope" do
    encoded_args = encode_args(["nodes", "pending", "--help"])

    output =
      capture_io(fn -> assert :ok = PackagedNodeCommandRPC.main_base64(encoded_args) end)

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
               args
               |> encode_args()
               |> PackagedNodeCommandRPC.run_base64()
               |> decode_envelope()
    end
  end

  test "RPC bridge rejects malformed Base64 arguments" do
    assert {:stderr, 1, "Error: invalid Controller runtime RPC arguments."} =
             ["%%%"]
             |> PackagedNodeCommandRPC.run_base64()
             |> decode_envelope()
  end

  test "Controller-owned RPC bounds result envelopes before Base64 expansion" do
    limit = PackagedNodeCommandRPC.max_message_bytes()
    within_limit = String.duplicate("a", limit)
    above_limit = within_limit <> "a"

    assert {:stdout, 0, ^within_limit} =
             run_with_result({:ok, within_limit})

    assert {:stderr, 1, message} = run_with_result({:ok, above_limit})
    assert message == "Error: Controller runtime RPC result exceeded the 786000-byte limit."
  end

  defp encode_args(args), do: Enum.map(args, &Base.encode64/1)

  defp run_with_result(result) do
    command_runner = fn _args -> result end

    ["nodes", "list"]
    |> encode_args()
    |> PackagedNodeCommandRPC.run_base64(command_runner)
    |> decode_envelope()
  end

  defp decode_envelope(envelope) do
    assert ["ORCHARDCTL_RPC_V1", status, stream, encoded_message] =
             String.split(envelope, ":", parts: 4)

    assert {status, ""} = Integer.parse(status)
    assert {:ok, message} = Base.decode64(encoded_message)

    {String.to_existing_atom(stream), status, message}
  end
end
