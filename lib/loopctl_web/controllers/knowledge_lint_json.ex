defmodule LoopctlWeb.KnowledgeLintJSON do
  @moduledoc """
  JSON rendering helpers for the knowledge lint endpoint.

  Renders the structured lint report with issue arrays and a top-level summary.
  """

  @doc "Renders the knowledge lint report."
  def lint(%{
        stale_articles: stale,
        orphan_articles: orphans,
        contradiction_clusters: contradictions,
        coverage_gaps: gaps,
        broken_sources: broken,
        summary: summary
      }) do
    %{
      data: %{
        stale_articles: Enum.map(stale, &render_stale/1),
        orphan_articles: Enum.map(orphans, &render_orphan/1),
        contradiction_clusters: Enum.map(contradictions, &render_contradiction/1),
        coverage_gaps: Enum.map(gaps, &render_coverage_gap/1),
        broken_sources: Enum.map(broken, &render_broken_source/1)
      },
      summary: %{
        total_articles: summary.total_articles,
        total_issues: summary.total_issues,
        issues_by_severity: summary.issues_by_severity,
        total_per_category: Map.get(summary, :total_per_category, %{}),
        truncated: Map.get(summary, :truncated, %{}),
        generated_at: summary.generated_at
      }
    }
  end

  defp render_stale(item) do
    %{
      article_id: item.article_id,
      title: item.title,
      last_updated: item.last_updated,
      days_since_update: item.days_since_update,
      severity: item.severity,
      suggested_action: item.suggested_action
    }
  end

  defp render_orphan(item) do
    %{
      article_id: item.article_id,
      title: item.title,
      category: item.category,
      severity: item.severity,
      suggested_action: item.suggested_action
    }
  end

  defp render_contradiction(item) do
    %{
      article_ids: item.article_ids,
      titles: item.titles,
      link_ids: item.link_ids,
      severity: item.severity,
      suggested_action: item.suggested_action
    }
  end

  defp render_coverage_gap(item) do
    %{
      category: item.category,
      current_count: item.current_count,
      threshold: item.threshold,
      severity: item.severity,
      suggested_action: item.suggested_action
    }
  end

  defp render_broken_source(item) do
    %{
      article_id: item.article_id,
      title: item.title,
      source_type: item.source_type,
      source_id: item.source_id,
      severity: item.severity,
      suggested_action: item.suggested_action
    }
  end
end
