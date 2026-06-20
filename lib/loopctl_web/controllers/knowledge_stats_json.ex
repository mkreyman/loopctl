defmodule LoopctlWeb.KnowledgeStatsJSON do
  @moduledoc """
  JSON rendering helper for the knowledge stats endpoint.

  Passes through the aggregate counts produced by `Loopctl.Knowledge.stats/2`.
  Category/status keys are already stringified by the context.
  """

  @doc "Renders aggregate article counts (total, by_category, by_status)."
  def stats(%{total: total, by_category: by_category, by_status: by_status}) do
    %{
      total: total,
      by_category: by_category,
      by_status: by_status
    }
  end
end
