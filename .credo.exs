%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["config/", "apps/", "mix.exs"],
        excluded: ["_build/", "deps/"]
      },
      strict: true,
      requires: ["deps/ex_dna/lib/ex_dna/integrations/credo.ex"],
      checks: [
        # Built-in overrides
        {Credo.Check.Readability.MaxLineLength, priority: :low, max_length: 100},
        {Credo.Check.Design.TagTODO, exit_status: 0},

        # Disable built-in duplicate-code check (superseded by ex_dna)
        {Credo.Check.Design.DuplicatedCode, false},

        # ex_dna — AST-level code duplication detection
        {ExDNA.Credo, min_mass: 80, excluded_macros: [:@, :schema, :pipe_through, :plug]},

        # ex_slop — AI-generated code pattern checks (20 checks, 2 Ecto + 1 GenServer skipped)
        # Warnings
        {ExSlop.Check.Warning.BlanketRescue, []},
        {ExSlop.Check.Warning.RescueWithoutReraise, []},
        # Refactoring
        {ExSlop.Check.Refactor.FilterNil, []},
        {ExSlop.Check.Refactor.RejectNil, []},
        {ExSlop.Check.Refactor.ReduceAsMap, []},
        {ExSlop.Check.Refactor.MapIntoLiteral, []},
        {ExSlop.Check.Refactor.IdentityPassthrough, []},
        {ExSlop.Check.Refactor.IdentityMap, []},
        {ExSlop.Check.Refactor.CaseTrueFalse, []},
        {ExSlop.Check.Refactor.TryRescueWithSafeAlternative, []},
        {ExSlop.Check.Refactor.WithIdentityElse, []},
        {ExSlop.Check.Refactor.WithIdentityDo, []},
        {ExSlop.Check.Refactor.SortThenReverse, []},
        {ExSlop.Check.Refactor.StringConcatInReduce, []},
        # Readability
        {ExSlop.Check.Readability.NarratorDoc, []},
        {ExSlop.Check.Readability.DocFalseOnPublicFunction, []},
        {ExSlop.Check.Readability.BoilerplateDocParams, []},
        {ExSlop.Check.Readability.ObviousComment, []},
        {ExSlop.Check.Readability.StepComment, []},
        {ExSlop.Check.Readability.NarratorComment, []}
      ]
    }
  ]
}
