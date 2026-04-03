defmodule Loopctl.TokenUsage.RollupBehaviour do
  @moduledoc """
  Behaviour for cost rollup aggregation.

  Defines the contract for aggregating token usage reports into
  cost summaries for a given tenant and period. The default
  implementation queries `token_usage_reports` and groups by
  scope (agent, epic, project).

  Used by `Loopctl.Workers.CostRollupWorker` via compile-time DI.
  """

  @type summary_row :: %{
          scope_type: :agent | :epic | :project | :story,
          scope_id: Ecto.UUID.t(),
          total_input_tokens: non_neg_integer(),
          total_output_tokens: non_neg_integer(),
          total_cost_millicents: non_neg_integer(),
          report_count: non_neg_integer(),
          model_breakdown: map(),
          avg_cost_per_story_millicents: non_neg_integer() | nil
        }

  @callback aggregate(
              tenant_id :: Ecto.UUID.t(),
              period_start :: Date.t(),
              period_end :: Date.t()
            ) :: {:ok, [summary_row()]} | {:error, term()}
end
