defmodule LoopctlWeb.ArticleLinkController do
  @moduledoc """
  Controller for Knowledge Wiki article link management.

  - `POST /api/v1/article_links` -- create link between articles (agent+)
  - `DELETE /api/v1/article_links/:id` -- delete a link (user+)
  - `GET /api/v1/articles/:article_id/links` -- list links for an article (agent+)
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Auth.Role
  alias Loopctl.Knowledge
  alias LoopctlWeb.ArticleLinkJSON
  alias LoopctlWeb.AuditContext
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :user]
       when action in [:delete]

  plug LoopctlWeb.Plugs.RequireRole,
       [role: :agent]
       when action in [:create, :index]

  tags(["Knowledge Wiki"])

  operation(:create,
    summary: "Create article link",
    description:
      "Creates a directed link between two articles in the same tenant. " <>
        "When relationship_type is 'supersedes', the target article's status " <>
        "is set to 'superseded' (retired), so that destructive relationship_type " <>
        "requires role: user+. Non-destructive types (relates_to, derived_from, " <>
        "contradicts) are agent+.",
    request_body:
      {"ArticleLink params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:source_article_id, :target_article_id, :relationship_type],
         properties: %{
           source_article_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
           target_article_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
           relationship_type: %OpenApiSpex.Schema{
             type: :string,
             enum: ["relates_to", "derived_from", "contradicts", "supersedes"]
           },
           metadata: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
         }
       }},
    responses: %{
      201 =>
        {"Link created", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      422 => {"Validation error", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:delete,
    summary: "Delete article link",
    description: "Deletes an article link. Role: user+.",
    parameters: [id: [in: :path, type: :string, description: "ArticleLink UUID"]],
    responses: %{
      204 => {"No content", "application/json", %OpenApiSpex.Schema{type: :string}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:index,
    summary: "List links for article",
    description:
      "Returns all links (outgoing and incoming) for an article, " <>
        "with linked articles preloaded. Role: agent+.",
    parameters: [
      article_id: [in: :path, type: :string, description: "Article UUID"]
    ],
    responses: %{
      200 =>
        {"Link list", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  # --- Actions ---

  @doc "POST /api/v1/article_links"
  def create(conn, params) do
    api_key = conn.assigns.current_api_key
    rel_type = params["relationship_type"] || params[:relationship_type]

    # kb-01 (GHSA-9g2g-cm9x-9r2p): a "supersedes" link retires the TARGET article
    # (published -> superseded), hiding it from every default published read
    # (search/graph/context all default status: :published). That is a DESTRUCTIVE
    # op, so — consistent with archive/unpublish — it requires role: :user. The other
    # relationship types (relates_to, derived_from, contradicts) are non-destructive
    # and stay at :agent. This is an in-action check (not a static RequireRole plug)
    # because destructiveness depends on the body param relationship_type.
    if destructive_relationship?(rel_type) and
         not Role.role_at_least?(api_key.role, :user) do
      forbidden(
        conn,
        "Creating a 'supersedes' link retires the target article, which removes it " <>
          "from published reads. This destructive operation requires the user role or higher."
      )
    else
      do_create(conn, api_key.tenant_id, params)
    end
  end

  defp do_create(conn, tenant_id, params) do
    opts = AuditContext.from_conn(conn) ++ Visibility.scope_opts(conn)

    case Knowledge.create_link(tenant_id, params, opts) do
      {:ok, link} ->
        conn
        |> put_status(:created)
        |> json(ArticleLinkJSON.create(%{link: link}))

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, :target_not_found} ->
        {:error, :not_found}
    end
  end

  # A "supersedes" link is the one relationship_type that retires (hides) its target.
  defp destructive_relationship?(rel_type), do: to_string(rel_type) == "supersedes"

  # 403 body matches the RequireRole plug / FallbackController shape.
  defp forbidden(conn, message) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: %{status: 403, message: message}})
  end

  @doc "DELETE /api/v1/article_links/:id"
  def delete(conn, %{"id" => link_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    audit_opts = AuditContext.from_conn(conn)

    case Knowledge.delete_link(tenant_id, link_id, audit_opts) do
      {:ok, _link} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc "GET /api/v1/articles/:article_id/links"
  def index(conn, %{"article_id" => article_id}) do
    tenant_id = conn.assigns.current_api_key.tenant_id

    links = Knowledge.list_links_for_article(tenant_id, article_id, Visibility.scope_opts(conn))

    json(conn, ArticleLinkJSON.index(%{links: links}))
  end
end
