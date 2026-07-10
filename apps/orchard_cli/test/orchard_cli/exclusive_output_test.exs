defmodule OrchardCLI.ExclusiveOutputTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias OrchardCLI.ExclusiveOutput

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-exclusive-output-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:orchard_cli, :exclusive_output_fault_injector)
    Application.delete_env(:orchard_cli, :exclusive_output_fault_injector)

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    on_exit(fn ->
      File.rm_rf!(root)
      restore_app_env(:orchard_cli, :exclusive_output_fault_injector, previous)
    end)

    {:ok, root: root}
  end

  test "reservation exposes only a mode-0600 no-clobber inode and publish syncs file and parent",
       %{root: root} do
    path = Path.join(root, "node-enrollment.json")
    trace_sync_calls()

    assert {:ok, reservation} = ExclusiveOutput.reserve(path)
    refute File.exists?(path)
    assert {:ok, published} = ExclusiveOutput.publish(reservation, "sensitive-bundle\n")
    assert (File.stat!(path).mode &&& 0o777) == 0o600
    assert {:error, :eexist} = ExclusiveOutput.reserve(path)
    assert File.read!(path) == "sensitive-bundle\n"
    assert published.inode == File.stat!(path).inode

    assert {:call_count, count} = :erlang.trace_info({:file, :sync, 1}, :call_count)
    assert count >= 2
  end

  test "release never removes a path replaced after reservation", %{root: root} do
    path = Path.join(root, "node-enrollment.json")
    assert {:ok, reservation} = ExclusiveOutput.reserve(path)
    assert {:ok, published} = ExclusiveOutput.publish(reservation, "original")

    assert :ok = File.rm(path)
    assert :ok = File.write(path, "replacement-owned-by-another-writer")
    assert {:error, :output_identity_changed} = ExclusiveOutput.release(published)

    assert File.read!(path) == "replacement-owned-by-another-writer"
  end

  test "post-link failure preserves inode-bound cleanup status", %{root: root} do
    path = Path.join(root, "node-enrollment.json")

    Application.put_env(
      :orchard_cli,
      :exclusive_output_fault_injector,
      fn :after_link -> {:error, :simulated_after_link_failure} end
    )

    assert {:ok, reservation} = ExclusiveOutput.reserve(path)

    assert {:error, {:publication_failed, :cleanup_complete, :simulated_after_link_failure}} =
             ExclusiveOutput.publish(reservation, "sensitive-bundle")

    refute File.exists?(path)
  end

  test "reservation rejects a parent that is traversable by other users", %{root: root} do
    path = Path.join(root, "node-enrollment.json")
    File.chmod!(root, 0o755)

    assert {:error, :parent_not_owner_only} = ExclusiveOutput.reserve(path)
    refute File.exists?(path)
  end

  test "reservation creates a missing parent as an owner-only directory", %{root: root} do
    parent = Path.join([root, "created", "nested"])
    path = Path.join(parent, "node-enrollment.json")

    assert {:ok, reservation} = ExclusiveOutput.reserve(path)
    assert (File.stat!(parent).mode &&& 0o777) == 0o700
    assert {:ok, published} = ExclusiveOutput.publish(reservation, "sensitive-bundle\n")
    assert (File.stat!(path).mode &&& 0o777) == 0o600
    assert File.read!(path) == "sensitive-bundle\n"
    assert published.inode == File.stat!(path).inode
  end

  defp trace_sync_calls do
    :erlang.trace_pattern({:file, :sync, 1}, true, [:call_count])

    on_exit(fn ->
      :erlang.trace_pattern({:file, :sync, 1}, false, [:call_count])
    end)
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
