defmodule Orchard.FSTest do
  use ExUnit.Case, async: true

  alias Orchard.FS

  setup do
    root = Path.join(System.tmp_dir!(), "orchard-fs-test-#{System.unique_integer([:positive])}")
    bundle = Path.join(root, "bundle")
    File.mkdir_p!(bundle)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, bundle: bundle, manifest_path: Path.join(bundle, "manifest.json")}
  end

  test "writes content atomically with temp outside the bundle tree", ctx do
    assert :ok = FS.atomic_write!(ctx.manifest_path, ~s({"ok":true}))

    assert File.read!(ctx.manifest_path) == ~s({"ok":true})
    assert File.ls!(ctx.bundle) == ["manifest.json"]
    refute Enum.any?(File.ls!(ctx.root), &String.starts_with?(&1, ".tmp-"))
  end

  test "applies requested permissions before publishing content", ctx do
    assert :ok =
             FS.atomic_write!(ctx.manifest_path, ~s({"private":true}), permissions: 0o600)

    assert %File.Stat{mode: mode} = File.stat!(ctx.manifest_path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "concurrent writers never leave half-written content", ctx do
    payloads =
      for index <- 1..24 do
        marker = "payload-#{index}-"
        String.duplicate(marker, 2_000)
      end

    results =
      payloads
      |> Task.async_stream(&FS.atomic_write!(ctx.manifest_path, &1),
        max_concurrency: 24,
        timeout: 5_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, :ok}, &1))
    assert File.read!(ctx.manifest_path) in payloads
  end

  test "cleans up temp files when the write fails", ctx do
    assert_raise File.Error, fn ->
      FS.atomic_write!(ctx.manifest_path, ["valid", :invalid_iodata])
    end

    refute File.exists?(ctx.manifest_path)
    refute Enum.any?(File.ls!(ctx.root), &String.starts_with?(&1, ".tmp-"))
  end
end
