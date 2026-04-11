defmodule LoopctlWeb.KnowledgeAnalyticsJSON do
  @moduledoc """
  JSON rendering helpers for `LoopctlWeb.KnowledgeAnalyticsController`.
  """

  alias Loopctl.Knowledge.Article

  @doc """
  Top accessed articles response. Emits three different row shapes
  based on `Keyword.get(opts, :group_by)`:

  - `:article` (default) — per article row
  - `:project` — per project row
  - `:agent` — per logical agent row
  """
  def top_articles(rows, opts) do
    group_by = Keyword.get(opts, :group_by, :article)
    render_fn = row_renderer(group_by)

    %{
      data: Enum.map(rows, render_fn),
      meta: %{
        count: length(rows),
        limit: Keyword.get(opts, :limit),
        since: encode_dt(Keyword.get(opts, :since)),
        access_type: Keyword.get(opts, :access_type),
        project_id: Keyword.get(opts, :project_id),
        group_by: Atom.to_string(group_by)
      }
    }
  end

  defp row_renderer(:project), do: &render_project_row/1
  defp row_renderer(:agent), do: &render_agent_row/1
  defp row_renderer(_), do: &render_top_row/1

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

  @doc """
  Per-agent usage response.

  Includes `resolved_as: "api_key" | "agent"` at the top level of
  `data` so callers can tell which resolution branch ran. When
  resolved as an agent, additional `agent_id`, `agent_name`,
  `agent_type`, and `api_key_count` fields are surfaced.
  """
  def agent_usage(%{resolved_as: :api_key} = usage, opts) do
    %{
      data: %{
        resolved_as: "api_key",
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

  def agent_usage(%{resolved_as: :agent} = usage, opts) do
    %{
      data: %{
        resolved_as: "agent",
        agent_id: usage.agent_id,
        agent_name: usage.agent_name,
        agent_type: usage.agent_type,
        api_key_count: usage.api_key_count,
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

  @doc "Per-project wiki usage rollup response."
  def project_usage(usage, since_days) do
    %{
      data: %{
        project_id: usage.project_id,
        project_name: usage.project_name,
        total_reads: usage.total_reads,
        unique_articles: usage.unique_articles,
        unique_api_keys: usage.unique_api_keys,
        unique_agents: usage.unique_agents,
        access_by_type: usage.access_by_type,
        top_articles: Enum.map(usage.top_articles, &render_top_row/1),
        daily_series: Enum.map(usage.daily_series, &render_daily_point/1)
      },
      meta: %{
        since_days: since_days
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

  defp render_project_row(row) do
    %{
      project_id: row.project_id,
      project_name: row.project_name,
      access_count: row.access_count,
      unique_articles: row.unique_articles,
      unique_api_keys: row.unique_api_keys
    }
  end

  defp render_agent_row(row) do
    %{
      agent_id: Map.get(row, :agent_id),
      agent_name: Map.get(row, :agent_name),
      agent_type: Map.get(row, :agent_type),
      access_count: row.access_count,
      unique_articles: row.unique_articles,
      api_key_count: row.api_key_count
    }
  end

  defp render_daily_point(%{date: date, read_count: count}) do
    %{
      date: Date.to_iso8601(date),
      read_count: count
    }
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
