defmodule LoopctlWeb.KnowledgeAnalyticsJSON do
  @moduledoc """
  JSON rendering helpers for `LoopctlWeb.KnowledgeAnalyticsController`.
  """

  alias Loopctl.Knowledge.Article

  @doc "Top accessed articles response."
  def top_articles(rows, opts) do
    %{
      data: Enum.map(rows, &render_top_row/1),
      meta: %{
        count: length(rows),
        limit: Keyword.get(opts, :limit),
        since: encode_dt(Keyword.get(opts, :since)),
        access_type: Keyword.get(opts, :access_type)
      }
    }
  end

  @doc "Per-article stats response."
  def article_stats(%Article{} = article, stats) do
    %{
      data: %{
        article_id: article.id,
        title: article.title,
        category: to_string(article.category),
        status: to_string(article.status),
        tags: article.tags || [],
        total_accesses: stats.total_accesses,
        unique_agents: stats.unique_agents,
        last_accessed_at: encode_dt(stats.last_accessed_at),
        accesses_by_type: stats.accesses_by_type,
        recent_accesses: Enum.map(stats.recent_accesses, &render_recent/1)
      }
    }
  end

  @doc "Per-agent usage response."
  def agent_usage(usage, opts) do
    %{
      data: %{
        api_key_id: usage.api_key_id,
        total_reads: usage.total_reads,
        unique_articles: usage.unique_articles,
        access_by_type: usage.access_by_type,
        top_articles: Enum.map(usage.top_articles, &render_top_row/1)
      },
      meta: %{
        limit: Keyword.get(opts, :limit),
        since: encode_dt(Keyword.get(opts, :since))
      }
    }
  end

  @doc "Unused articles response."
  def unused_articles(rows, opts) do
    %{
      data: Enum.map(rows, &render_unused_row/1),
      meta: %{
        count: length(rows),
        days_unused: Keyword.get(opts, :days_unused),
        limit: Keyword.get(opts, :limit)
      }
    }
  end

  # ---------------------------------------------------------------------------

  defp render_top_row(row) do
    %{
      article_id: row.article_id,
      title: row.title,
      category: row.category,
      access_count: row.access_count,
      unique_agents: Map.get(row, :unique_agents)
    }
    |> compact()
  end

  defp render_unused_row(row) do
    %{
      article_id: row.article_id,
      title: row.title,
      category: row.category,
      tags: row.tags || [],
      inserted_at: encode_dt(row.inserted_at),
      updated_at: encode_dt(row.updated_at)
    }
  end

  defp render_recent(event) do
    %{
      id: event.id,
      api_key_id: event.api_key_id,
      access_type: event.access_type,
      metadata: event.metadata || %{},
      accessed_at: encode_dt(event.accessed_at)
    }
  end

  defp encode_dt(nil), do: nil
  defp encode_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_dt(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp encode_dt(other), do: other

  defp compact(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
