%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["config/", "apps/", "mix.exs"],
        excluded: ["_build/", "deps/"]
      },
      strict: true,
      requires: [],
      checks: [
        {Credo.Check.Readability.MaxLineLength, priority: :low, max_length: 100},
        {Credo.Check.Design.TagTODO, exit_status: 0}
      ]
    }
  ]
}
