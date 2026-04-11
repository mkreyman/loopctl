defmodule LoopctlWeb.KnowledgeAnalyticsController do
  @moduledoc """
  Controller for knowledge analytics endpoints.

  All endpoints require `orchestrator+` role and surface aggregated
  article usage data captured by `Loopctl.Knowledge.Analytics`.

  - `GET /api/v1/knowledge/analytics/top-articles` -- top accessed articles
  - `GET /api/v1/knowledge/articles/:id/stats` -- per-article usage stats
  - `GET /api/v1/knowledge/analytics/agents/:agent_id` -- per-agent usage
  - `GET /api/v1/knowledge/analytics/projects/:id/usage` -- per-project rollup
  - `GET /api/v1/knowledge/analytics/unused-articles` -- unused published articles
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :orchestrator

  tags(["Knowledge Analytics"])

  @max_limit 100
  @max_unused_limit 200
  @valid_access_types ~w(search get context index)
  @valid_group_by ~w(article project agent)

  operation(:top_articles,
    summary: "Top accessed knowledge articles",
    description:
      "Returns the top accessed articles for the tenant in a time window. " <>
        "Supports `project_id` filtering and `group_by` (article|project|agent). " <>
        "Role: orchestrator+.",
    parameters: [
      limit: [
        in: :query,
        type: :integer,
        description: "Max rows to return (default 20, max 100)",
        required: false
      ],
      since_days: [
        in: :query,
        type: :integer,
        description: "Look back this many days (default 7, min 1, max 365)",
        required: false
      ],
      access_type: [
        in: :query,
        type: :string,
        description: "Restrict to a single access type (search, get, context, index)",
        required: false
      ],
      project_id: [
        in: :query,
        type: :string,
        description:
          "Filter events to a single project_id (events without attribution are excluded)",
        required: false
      ],
      group_by: [
        in: :query,
        type: :string,
        description: "Grouping dimension: article (default), project, or agent",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Top articles", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/analytics/top-articles"
  def top_articles(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    group_by = parse_group_by(params["group_by"])

    opts =
      []
      |> put_limit(params["limit"], 20, @max_limit)
      |> put_since(params["since_days"], 7)
      |> put_access_type(params["access_type"])
      |> put_project_id(params["project_id"])
      |> Keyword.put(:group_by, group_by)

    rows = Knowledge.list_top_articles(tenant_id, opts)
    json(conn, LoopctlWeb.KnowledgeAnalyticsJSON.top_articles(rows, opts))
  end

  operation(:article_stats,
    summary: "Per-article usage statistics",
    description: "Returns aggregated access counts for a single article. Role: orchestrator+.",
    parameters: [
      id: [in: :path, type: :string, description: "Article UUID", required: true]
    ],
    responses: %{
      200 =>
        {"Article stats", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/articles/:id/stats"
  def article_stats(conn, %{"id" => article_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    case Knowledge.get_article(tenant_id, article_id) do
      {:ok, article} ->
        stats = Knowledge.get_article_stats(tenant_id, article.id)
        json(conn, LoopctlWeb.KnowledgeAnalyticsJSON.article_stats(article, stats))

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  operation(:agent_usage,
    summary: "Per-agent knowledge usage",
    description:
      ~s(Returns the reads, top articles, and access type breakdown for a single ) <>
        ~s(api_key OR logical agent. The path parameter is resolved against ) <>
        ~s(`api_keys.id` first, then `agents.id`. The response envelope includes ) <>
        ~s(`resolved_as: "api_key" | "agent"` so callers can tell which branch ) <>
        ~s(ran. Cross-tenant or missing ids return 404. Role: orchestrator+.),
    parameters: [
      agent_id: [
        in: :path,
        type: :string,
        description: "API key UUID or agent UUID",
        required: true
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Max top articles to return (default 20, max 100)",
        required: false
      ],
      since_days: [
        in: :query,
        type: :integer,
        description: "Look back this many days (default 7, min 1, max 365)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Agent usage", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/analytics/agents/:agent_id"
  def agent_usage(conn, %{"agent_id" => id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> put_limit(params["limit"], 20, @max_limit)
      |> put_since(params["since_days"], 7)

    with {:ok, usage} <- Knowledge.get_agent_usage(tenant_id, id, opts) do
      json(conn, LoopctlWeb.KnowledgeAnalyticsJSON.agent_usage(usage, opts))
    end
  end

  operation(:project_usage,
    summary: "Per-project wiki usage rollup",
    description:
      "Returns total reads, unique articles, unique callers, access type " <>
        "breakdown, top articles, and a zero-filled daily read-count series " <>
        "for a single project. Cross-tenant or missing projects return 404. " <>
        "Role: orchestrator+.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        description: "Project UUID",
        required: true
      ],
      since_days: [
        in: :query,
        type: :integer,
        description: "Look back this many days (default 7, min 1, max 365)",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Max top articles to return (default 20, max 100)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Project usage", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/analytics/projects/:id/usage"
  def project_usage(conn, %{"id" => project_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    since_days = parse_int(params["since_days"], 7) |> max(1) |> min(365)

    opts =
      []
      |> put_limit(params["limit"], 20, @max_limit)
      |> Keyword.put(:since_days, since_days)

    with {:ok, usage} <- Knowledge.get_project_usage(tenant_id, project_id, opts) do
      json(conn, LoopctlWeb.KnowledgeAnalyticsJSON.project_usage(usage, since_days))
    end
  end

  operation(:unused_articles,
    summary: "Unused published articles",
    description:
      "Returns published articles with zero access events in the configured window. " <>
        "Role: orchestrator+.",
    parameters: [
      days_unused: [
        in: :query,
        type: :integer,
        description: "Window length in days (default 30)",
        required: false
      ],
      limit: [
        in: :query,
        type: :integer,
        description: "Max rows to return (default 50, max 200)",
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"Unused articles", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/analytics/unused-articles"
  def unused_articles(conn, params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    opts =
      []
      |> put_int(:days_unused, params["days_unused"], 30, 1, 365)
      |> put_limit(params["limit"], 50, @max_unused_limit)

    rows = Knowledge.list_unused_articles(tenant_id, opts)
    json(conn, LoopctlWeb.KnowledgeAnalyticsJSON.unused_articles(rows, opts))
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp put_limit(opts, value, default, max_value) do
    Keyword.put(opts, :limit, parse_int(value, default) |> max(1) |> min(max_value))
  end

  defp put_since(opts, value, default_days) do
    days = parse_int(value, default_days) |> max(1) |> min(365)
    since = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    Keyword.put(opts, :since, since)
  end

  defp put_access_type(opts, nil), do: opts
  defp put_access_type(opts, ""), do: opts

  defp put_access_type(opts, value) when value in @valid_access_types do
    Keyword.put(opts, :access_type, value)
  end

  defp put_access_type(opts, _), do: opts

  defp put_project_id(opts, nil), do: opts
  defp put_project_id(opts, ""), do: opts

  defp put_project_id(opts, value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, cast_id} -> Keyword.put(opts, :project_id, cast_id)
      :error -> opts
    end
  end

  defp put_project_id(opts, _), do: opts

  defp parse_group_by(nil), do: :article
  defp parse_group_by(""), do: :article

  defp parse_group_by(value) when value in @valid_group_by do
    String.to_existing_atom(value)
  end

  defp parse_group_by(_), do: :article

  defp put_int(opts, key, value, default, min_value, max_value) do
    Keyword.put(opts, key, parse_int(value, default) |> max(min_value) |> min(max_value))
  end

  defp parse_int(nil, default), do: default
  defp parse_int(int, _default) when is_integer(int), do: int

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_, default), do: default
end
