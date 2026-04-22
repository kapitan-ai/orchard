defmodule Mix.Tasks.Orchard.Backfill.ResidentMemory do
  @moduledoc false

  use Mix.Task

  alias Orchard.Models.ResidentMemoryBackfill

  @requirements ["app.start"]
  @shortdoc "Backfill resident_memory_bytes for existing model bundles"

  @impl Mix.Task
  def run(args) do
    apply? = "--apply" in args

    if apply? do
      IO.puts("Applying resident_memory_bytes backfill...")
    else
      IO.puts("DRY RUN — no changes will be written. Pass --apply to execute.")
    end

    log = fn message -> IO.puts(message) end

    case ResidentMemoryBackfill.run(apply: apply?, log: log) do
      {:ok, result} ->
        print_summary(result)

      {:error, result} ->
        print_summary(result)
        raise "resident_memory_bytes backfill aborted; see critical rollback failure above"
    end
  end

  defp print_summary(result) do
    IO.puts("processed=#{result.processed}")
    IO.puts("updated=#{result.updated}")
    IO.puts("would_update=#{result.would_update}")
    IO.puts("skipped=#{result.skipped}")
    IO.puts("skipped_already_present=#{result.skipped_already_present}")
    IO.puts("skipped_drift=#{result.skipped_drift}")
    IO.puts("skipped_concurrent=#{result.skipped_concurrent}")
    IO.puts("skipped_unknown=#{result.skipped_unknown}")
    IO.puts("failed=#{result.failed}")
  end
end
