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
      "Returns ranked link CANDIDATES for an article by embedding similarity within the " <>
        "caller's visible set, **read-only — creates nothing**. Agent callers see only " <>
        "their own and `shared` articles. Excludes the article itself and any " <>
        "already-linked article (either direction, any relationship type); only " <>
        "embedded, published, visible articles are considered. Each candidate is " <>
        "`{id, title, category, similarity_score}`, highest similarity first — POST " <>
        "the one you want as a **typed** link (relates_to/derived_from/contradicts/" <>
        "supersedes) via the article_links API. `threshold` (0–1, default 0.5) is the " <>
        "cosine floor; `limit` (default 5) caps results. Suggestions are approximate-NN " <>
        "over the embedding index: exclusions (already-linked / below-threshold) are " <>
        "applied to the nearest candidate pool, so a densely-linked article may return " <>
        "fewer than `limit` (or none) even if more-distant unlinked articles exist. " <>
        "Role: agent+.",
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
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError},
      503 =>
        {"Database unavailable / serialization failure / deadlock — retryable; " <>
           "see Retry-After header", "application/json", Schemas.ErrorResponse},
      504 =>
        {"Database statement timeout (code db_statement_timeout) — the vector " <>
           "similarity scan exceeded the statement timeout", "application/json",
         Schemas.ErrorResponse}
    }
  )

  @doc "GET /api/v1/knowledge/articles/:id/suggested_links"
  def suggest(conn, %{"id" => article_id} = params) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    with {:ok, threshold} <- parse_threshold(params["threshold"]),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, suggestions} <-
           suggest_links_guarded(
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

      # US-27.3: a DB exception (e.g. 57014 statement-timeout on the pgvector
      # scan) is rescued into a tuple so the FallbackController maps it to a
      # pinned status (504/503/500) and logs the SQLSTATE with the request_id,
      # instead of escaping as a blanket 500 that erases the SQLSTATE.
      {:error, %struct{} = db_error} when struct in [Postgrex.Error, DBConnection.ConnectionError] ->
        {:error, db_error}
    end
  end

  # Run the (possibly slow) vector-similarity query, translating a raised DB
  # exception into an `{:error, %Postgrex.Error{}}` / `{:error,
  # %DBConnection.ConnectionError{}}` tuple. Only DB exceptions are caught;
  # anything else is re-raised (let-it-crash). The suggest_links query runs on
  # AdminRepo — rescuing here does NOT change which tenant's data is touched.
  #
  # The executor is resolved via config-based DI (CLAUDE.md convention:
  # behaviour + Application.get_env, mock wired in config/test.exs) so a test can
  # deterministically inject a 57014 `Postgrex.Error` via Mox without seeding a
  # corpus large enough to actually breach `statement_timeout` (which is
  # inherently timing-dependent — the very reason the #170/#172 incident was
  # hard to reproduce). Production resolves to `Loopctl.Knowledge` itself, which
  # implements `Loopctl.Knowledge.SuggestLinksBehaviour`.
  defp suggest_links_guarded(tenant_id, article_id, opts) do
    knowledge().suggest_links(tenant_id, article_id, opts)
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, e}
  end

  defp knowledge do
    Application.get_env(:loopctl, :knowledge_suggest_links, Knowledge)
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
