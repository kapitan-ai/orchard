case System.argv() do
  [bundle_path] ->
    if Code.loaded?(Orchard.ModelManifest) do
      IO.puts("preloaded_before_parse=true")
      System.halt(3)
    end

    IO.puts("preloaded_before_parse=false")

    try do
      case Orchard.Models.ManifestParser.parse_from_bundle(bundle_path) do
        {:ok, manifest} ->
          IO.puts("parse_status=ok")
          IO.puts("model_id=#{Map.fetch!(manifest, :model_id)}")
          IO.puts("version=#{Map.fetch!(manifest, :version)}")
          IO.puts("COLD_BOOT_PARSE_OK")
          System.halt(0)

        {:error, reason} ->
          IO.puts("parse_status=error")
          IO.puts("reason=#{inspect(reason)}")
          System.halt(4)
      end
    rescue
      exception ->
        IO.puts("parse_status=exception")
        IO.puts("exception=#{Exception.message(exception)}")
        System.halt(5)
    end

  _ ->
    IO.puts("usage=manifest_parser_cold_boot_runner.exs <bundle_path>")
    System.halt(2)
end
