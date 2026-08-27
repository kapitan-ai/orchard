[dir, repo_id, revision] = System.argv()

case Orchard.Models.BundleBuilder.prepare_bundle(dir, repo_id, %{revision_sha: revision}) do
  {:ok, prepared} ->
    IO.puts(prepared)

  {:error, reason} ->
    IO.puts(:stderr, "write_mlx_smoke_manifest failed: #{inspect(reason)}")
    System.halt(1)
end
