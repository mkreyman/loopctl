defmodule LoopctlWeb.KnowledgeConsolidationJSON do
  @moduledoc """
  JSON rendering for the nightly consolidation report (#584 stage 1).

  Every count rendered here is a count of PROPOSALS, never of articles — see the
  endpoint's OpenAPI description for each denominator.
  """

  @doc "Renders a consolidation report with its numbered proposals."
  def show(%{report: nil, proposals: [], total_count: 0}) do
    %{data: nil, meta: %{total_count: 0, report_available: false}}
  end

  def show(%{report: report, proposals: proposals, total_count: total}) do
    %{
      data: %{
        day: report.day,
        generated_at: report.generated_at,
        corpus_size: report.corpus_size,
        proposal_count: report.proposal_count,
        persisted_count: report.persisted_count,
        proposals_by_class: report.proposals_by_class,
        truncated: report.truncated,
        max_per_class: report.max_per_class,
        proposals: Enum.map(proposals, &render_proposal/1)
      },
      meta: %{total_count: total, report_available: true, applied: false}
    }
  end

  defp render_proposal(proposal) do
    %{
      number: proposal.number,
      class: proposal.proposal_class,
      article_ids: proposal.article_ids,
      evidence: proposal.evidence,
      rationale: proposal.rationale,
      suggested_action: proposal.suggested_action,
      severity: proposal.severity,
      review_status: proposal.review_status,
      reviewed_by: proposal.reviewed_by,
      reviewed_at: proposal.reviewed_at
    }
  end
end
