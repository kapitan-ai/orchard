Code.require_file(
  Path.expand(
    "../../../../scripts/support/beam-peer-grant-control-files.exs",
    __DIR__
  )
)

defmodule Orchard.BeamPeerGrantControlFilesTest do
  use ExUnit.Case, async: true

  alias Orchard.BeamPeerGrantControlFiles

  test "source-dev control application rejects a non-owner-only root" do
    root = temporary_path("weak-root")
    File.mkdir!(root)
    File.chmod!(root, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, :beam_peer_grant_control_root_invalid} =
             BeamPeerGrantControlFiles.validate_root(root)
  end

  test "source-dev control application refuses a symlinked ready marker" do
    root = temporary_path("ready-symlink")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    target = Path.join(root, "target")
    ready = Path.join(root, "control.ready")
    File.write!(target, "sentinel\n")
    File.ln_s!(target, ready)

    assert {:error, :beam_peer_grant_control_ready_invalid} =
             BeamPeerGrantControlFiles.publish_ready(ready)

    assert File.read!(target) == "sentinel\n"
  end

  test "source-dev control application bounds a missing stop marker" do
    root = temporary_path("stop-timeout")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :beam_peer_grant_control_stop_timeout} =
             BeamPeerGrantControlFiles.wait_for_stop(Path.join(root, "control.stop"), 10)

    assert System.monotonic_time(:millisecond) - started_at < 500
  end

  defp temporary_path(label) do
    Path.join(
      System.tmp_dir!(),
      "orchard-peer-grant-control-#{label}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end
end
