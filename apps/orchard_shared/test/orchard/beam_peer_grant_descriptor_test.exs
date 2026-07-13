defmodule Orchard.BeamPeerGrantDescriptorTest do
  use ExUnit.Case, async: true

  alias Orchard.BeamPeerGrantDescriptor

  test "SPEC.md §7.5.0 syncs the descriptor directory after publication" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-beam-peer-grant-descriptor-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    path = Path.join(root, "beam-peer-grant.json")
    caller = self()

    assert :ok =
             BeamPeerGrantDescriptor.write(path, descriptor(),
               sync_directory: fn directory ->
                 send(caller, {:synced, directory})
                 :ok
               end
             )

    assert_received {:synced, ^root}
  end

  test "SPEC.md §7.5.0 rejects an abbreviated control endpoint IPv4" do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-beam-peer-grant-descriptor-abbreviated-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    path = Path.join(root, "beam-peer-grant.json")
    abbreviated = %{descriptor() | control_endpoint: "ipv4:10.1:50071"}

    assert {:error, :beam_peer_grant_descriptor_invalid} =
             BeamPeerGrantDescriptor.write(path, abbreviated)
  end

  defp descriptor do
    %{
      grant_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      generation: 1,
      controller_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      control_endpoint: "ipv4:127.0.0.1:50071"
    }
  end
end
