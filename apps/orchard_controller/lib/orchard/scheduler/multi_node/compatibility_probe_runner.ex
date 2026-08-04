defmodule Orchard.Scheduler.MultiNode.CompatibilityProbeRunner do
  @moduledoc false

  @type probe :: (term() -> term())
  @type result :: {:ok, term()} | {:exit, term()}
  @type options :: [
          max_concurrency: pos_integer(),
          timeout: non_neg_integer()
        ]

  @callback run([term()], probe(), options()) :: [result()]

  @spec run([term()], probe(), options()) :: [result()]
  def run(targets, probe, opts) do
    targets
    |> Task.async_stream(probe,
      max_concurrency: Keyword.fetch!(opts, :max_concurrency),
      ordered: true,
      timeout: Keyword.fetch!(opts, :timeout),
      on_timeout: :kill_task
    )
    |> Enum.to_list()
  end
end
