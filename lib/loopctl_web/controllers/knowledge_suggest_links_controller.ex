defmodule LoopctlWeb.KnowledgeSuggestLinksController do
  @moduledoc """
  Read-only typed-link suggestions.

  - `GET /api/v1/knowledge/articles/:id/suggested_links?limit=&threshold=` (agent+)

  Returns ranked link *candidates* (by embedding similarity) for an article
  **without creating anything**, so a caller can review them and POST a typed link
  (`relates_to`/`derived_from`/`contradicts`/`supersedes`) via the create-link API.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Knowledge
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, role: :agent

  tags(["Knowledge Wiki"])

  operation(:suggest,
    summary: "Suggest typed link candidates",
    description:
      "Returns ranked link CANDIDATES for an article by embedding similarity, " <>
        "**read-only — creates nothing**. Excludes the article itself and any " <>
        "already-linked article (either direction, any relationship type); only " <>
        "embedded, published articles are considered. Each candidate is " <>
        "`{id, title, category, similarity_score}`, highest similarity first — POST " <>
        "the one you want as a **typed** link (relates_to/derived_from/contradicts/" <>
        "supersedes) via the article_links API. `threshold` (0–1, default 0.5) is the " <>
        "cosine floor; `limit` (default 5) caps results. Role: agent+.",
    parameters: [
      id: [in: :path, type: :string, description: "Article UUID"],
      limit: [in: :query, type: :integer, description: "Max candidates (default 5)"],
      threshold: [
        in: :query,
        type: :number,
        description: "Cosine similarity floor 0–1 (default 0.5)"
      ]
    ],
    responses: %{
      200 =>
        {"Suggested links", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{data: %OpenApiSpex.Schema{type: :array}}
         }},
      400 => {"Bad request", "application/json", Schemas.ErrorResponse},
      404 => {"Article not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/knowledge/articles/:id/suggested_links"
  def suggest(conn, %{"id" => article_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, threshold} <- parse_threshold(params["threshold"]),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, suggestions} <-
           Knowledge.suggest_links(
             tenant_id,
             article_id,
             [threshold: threshold, limit: limit] ++ Visibility.scope_opts(conn)
           ) do
      json(conn, %{data: suggestions})
    else
      {:error, :invalid_threshold} ->
        {:error, :bad_request, "threshold must be a number between 0 and 1"}

      {:error, :invalid_limit} ->
        {:error, :bad_request, "limit must be a positive integer"}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # Absent → nil (context applies the default). A present value must parse to a
  # number; range (0–1) is validated by the context (→ :invalid_threshold).
  defp parse_threshold(value) when value in [nil, ""], do: {:ok, nil}

  defp parse_threshold(value) when is_binary(value) do
    case Float.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_threshold}
    end
  end

  defp parse_threshold(_), do: {:error, :invalid_threshold}

  # Absent → the context default. A present value must be a positive integer.
  defp parse_limit(value) when value in [nil, ""], do: {:ok, Knowledge.default_suggestion_limit()}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, :invalid_limit}
    end
  end

  defp parse_limit(_), do: {:error, :invalid_limit}
end
