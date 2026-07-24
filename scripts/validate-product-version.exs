Mix.start()

repo_root = Path.expand("..", __DIR__)
Code.require_file(Path.join(repo_root, "config/product_version.exs"))

product_version =
  try do
    Orchard.ProductVersion.read!()
  rescue
    error in ArgumentError ->
      IO.puts(:stderr, "Product Version validation failed: #{Exception.message(error)}")
      System.halt(1)
  end

app_projects =
  repo_root
  |> Path.join("apps/*/mix.exs")
  |> Path.wildcard()
  |> Enum.sort()
  |> Enum.map(fn mix_file ->
    app = mix_file |> Path.dirname() |> Path.basename() |> String.to_atom()
    {Path.relative_to(mix_file, repo_root), Path.dirname(mix_file), app}
  end)

projects = [{"mix.exs", repo_root, :orchard} | app_projects]

drift =
  Enum.flat_map(projects, fn {relative_path, project_root, app} ->
    version =
      Mix.Project.in_project(app, project_root, fn _module ->
        Mix.Project.config()[:version]
      end)

    if version == product_version do
      []
    else
      [{relative_path, version}]
    end
  end)

case drift do
  [] ->
    IO.puts(
      "Product Version validation passed: #{product_version}; " <>
        "#{length(projects)} Mix project surfaces agree"
    )

  mismatches ->
    Enum.each(mismatches, fn {path, version} ->
      IO.puts(
        :stderr,
        "Product Version validation failed: #{path} reports #{inspect(version)} " <>
          "but VERSION is #{inspect(product_version)}"
      )
    end)

    System.halt(1)
end
