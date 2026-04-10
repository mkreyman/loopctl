defmodule Loopctl.Knowledge do
  @moduledoc """
  Context module for the Knowledge Wiki.

  Provides CRUD operations for articles and article links. Articles
  are the core knowledge units — reusable patterns, conventions,
  decisions, findings, and references within a tenant's knowledge base.

  All operations use AdminRepo (BYPASSRLS) with explicit `tenant_id`
  scoping, following the same pattern as other loopctl contexts.

  ## Usage

  ### Creating an article

      Loopctl.Knowledge.create_article(tenant_id, %{
        title: "Ecto Multi Pattern",
        body: "Use Ecto.Multi for atomic operations...",
        category: :pattern,
        tags: ["ecto", "transactions"]
      }, actor_id: api_key.id, actor_label: "user:admin")

  ### Listing articles with filters

      Loopctl.Knowledge.list_articles(tenant_id,
        project_id: project_id,
        category: :pattern,
        tags: ["ecto"],
        limit: 10,
        offset: 0
      )
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Projects.Project
  alias Loopctl.Webhooks.EventGenerator

  # --- Articles ---

  @doc """
  Creates a new article within a tenant.

  Sets `tenant_id` programmatically and records the `article.created`
  audit event.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `attrs` -- map with title (required), body (required), category (required),
    and optional: status, tags, source_type, source_id, metadata, project_id
  - `opts` -- keyword list with `:actor_id`, `:actor_label`, `:actor_type`

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec create_article(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Article.t()} | {:error, Ecto.Changeset.t()}
  def create_article(tenant_id, attrs, opts \\ []) do
    project_id = attrs[:project_id] || attrs["project_id"]

    with :ok <- validate_project_ownership(tenant_id, project_id) do
      actor_id = Keyword.get(opts, :actor_id)
      actor_label = Keyword.get(opts, :actor_label)
      actor_type = Keyword.get(opts, :actor_type, "api_key")

      changeset =
        %Article{tenant_id: tenant_id}
        |> Article.create_changeset(attrs)

      multi =
        Multi.new()
        |> Multi.insert(:article, changeset)
        |> Audit.log_in_multi(:audit, fn %{article: article} ->
          %{
            tenant_id: tenant_id,
            entity_type: "article",
            entity_id: article.id,
            action: "article.created",
            actor_type: actor_type,
            actor_id: actor_id,
            actor_label: actor_label,
            new_state: %{
              "title" => article.title,
              "category" => to_string(article.category),
              "status" => to_string(article.status),
              "tags" => article.tags,
              "project_id" => article.project_id
            }
          }
        end)
        |> EventGenerator.generate_events(:webhook_events, fn %{article: article} ->
          %{
            tenant_id: tenant_id,
            event_type: "article.created",
            project_id: article.project_id,
            payload: article_event_payload(article)
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{article: article}} -> {:ok, article}
        {:error, :article, changeset, _} -> {:error, changeset}
      end
    end
  end

  @doc """
  Retrieves a single article by ID, scoped to the tenant.

  Preloads outgoing links (with target articles) and incoming links
  (with source articles).

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID

  ## Returns

  - `{:ok, %Article{}}` with preloaded links
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec get_article(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Article.t()} | {:error, :not_found}
  def get_article(tenant_id, article_id) do
    case AdminRepo.get_by(Article, id: article_id, tenant_id: tenant_id) do
      nil ->
        {:error, :not_found}

      article ->
        article =
          AdminRepo.preload(article,
            outgoing_links: :target_article,
            incoming_links: :source_article
          )

        {:ok, article}
    end
  end

  @doc """
  Lists articles for a tenant with optional filtering and pagination.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `opts` -- keyword list with:
    - `:project_id` -- filter by project UUID (optional)
    - `:category` -- filter by category atom (optional)
    - `:status` -- filter by status atom (optional)
    - `:tags` -- filter by tag overlap, articles matching ANY tag (optional)
    - `:limit` -- max records to return (default 20, max 100)
    - `:offset` -- records to skip for pagination (default 0)

  ## Returns

  - `%{data: [%Article{}], meta: %{total_count: integer, limit: integer, offset: integer}}`
  """
  @spec list_articles(Ecto.UUID.t(), keyword()) :: %{
          data: [Article.t()],
          meta: %{total_count: non_neg_integer(), limit: pos_integer(), offset: non_neg_integer()}
        }
  def list_articles(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(100)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        order_by: [desc: a.inserted_at]
      )

    base = apply_article_filters(base, opts)

    total_count = AdminRepo.aggregate(base, :count, :id)

    articles =
      base
      |> limit(^limit)
      |> offset(^offset)
      |> AdminRepo.all()

    %{
      data: articles,
      meta: %{total_count: total_count, limit: limit, offset: offset}
    }
  end

  @doc """
  Updates an existing article.

  Uses `update_changeset` and records the `article.updated` audit event.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID
  - `attrs` -- map of fields to update
  - `opts` -- keyword list with `:actor_id`, `:actor_label`, `:actor_type`

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, changeset}` on validation failure
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec update_article(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Article.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_article(tenant_id, article_id, attrs, opts \\ []) do
    project_id = attrs[:project_id] || attrs["project_id"]

    with :ok <- validate_project_ownership(tenant_id, project_id),
         {:ok, article} <- fetch_article(tenant_id, article_id) do
      actor_id = Keyword.get(opts, :actor_id)
      actor_label = Keyword.get(opts, :actor_label)
      actor_type = Keyword.get(opts, :actor_type, "api_key")
      old_state = article_state_snapshot(article)
      changeset = Article.update_changeset(article, attrs)

      changed_fields = changeset.changes |> Map.keys() |> Enum.map(&to_string/1)

      multi =
        Multi.new()
        |> Multi.update(:article, changeset)
        |> Audit.log_in_multi(:audit, fn %{article: updated} ->
          %{
            tenant_id: tenant_id,
            entity_type: "article",
            entity_id: updated.id,
            action: "article.updated",
            actor_type: actor_type,
            actor_id: actor_id,
            actor_label: actor_label,
            old_state: old_state,
            new_state: article_state_snapshot(updated)
          }
        end)
        |> EventGenerator.generate_events(:webhook_events, fn %{article: updated} ->
          %{
            tenant_id: tenant_id,
            event_type: "article.updated",
            project_id: updated.project_id,
            payload:
              updated
              |> article_event_payload()
              |> Map.put("changed_fields", changed_fields)
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{article: updated}} -> {:ok, updated}
        {:error, :article, changeset, _} -> {:error, changeset}
      end
    end
  end

  @doc """
  Archives an article by setting its status to `:archived`.

  Records the `article.archived` audit event.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID
  - `opts` -- keyword list with `:actor_id`, `:actor_label`, `:actor_type`

  ## Returns

  - `{:ok, %Article{}}` on success
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec archive_article(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Article.t()} | {:error, :not_found}
  def archive_article(tenant_id, article_id, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    actor_type = Keyword.get(opts, :actor_type, "api_key")

    with {:ok, article} <- fetch_article(tenant_id, article_id) do
      old_status = to_string(article.status)
      changeset = Article.update_changeset(article, %{status: :archived})

      multi =
        Multi.new()
        |> Multi.update(:article, changeset)
        |> Audit.log_in_multi(:audit, fn %{article: updated} ->
          %{
            tenant_id: tenant_id,
            entity_type: "article",
            entity_id: updated.id,
            action: "article.archived",
            actor_type: actor_type,
            actor_id: actor_id,
            actor_label: actor_label,
            old_state: %{"status" => old_status},
            new_state: %{"status" => to_string(updated.status)}
          }
        end)
        |> EventGenerator.generate_events(:webhook_events, fn %{article: updated} ->
          %{
            tenant_id: tenant_id,
            event_type: "article.archived",
            project_id: updated.project_id,
            payload: %{
              "id" => updated.id,
              "title" => updated.title,
              "category" => to_string(updated.category)
            }
          }
        end)

      case AdminRepo.transaction(multi) do
        {:ok, %{article: updated}} -> {:ok, updated}
        {:error, :article, changeset, _} -> {:error, changeset}
      end
    end
  end

  # --- Article Links ---

  @doc """
  Creates a new link between two articles.

  Sets `tenant_id` programmatically. Validates that both source and target
  articles exist within the same tenant. Records the `article_link.created`
  audit event.

  When the relationship type is `:supersedes`, the target article's status
  is set to `:superseded` within the same Multi transaction.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `attrs` -- map with source_article_id, target_article_id, relationship_type,
    and optional metadata

  ## Returns

  - `{:ok, %ArticleLink{}}` on success
  - `{:error, changeset}` on validation failure
  """
  @spec create_link(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, ArticleLink.t()} | {:error, Ecto.Changeset.t() | :target_not_found}
  def create_link(tenant_id, attrs, opts \\ []) do
    source_id = attrs[:source_article_id] || attrs["source_article_id"]
    target_id = attrs[:target_article_id] || attrs["target_article_id"]
    rel_type = attrs[:relationship_type] || attrs["relationship_type"]

    with :ok <- validate_articles_exist(tenant_id, source_id, target_id) do
      changeset =
        %ArticleLink{tenant_id: tenant_id}
        |> ArticleLink.changeset(attrs)

      multi =
        Multi.new()
        |> Multi.insert(:link, changeset)
        |> maybe_supersede_target(tenant_id, target_id, rel_type)
        |> Audit.log_in_multi(:audit, &build_link_audit(tenant_id, &1, opts))
        |> generate_link_created_events(tenant_id, source_id, target_id, rel_type)

      case AdminRepo.transaction(multi) do
        {:ok, %{link: link}} -> {:ok, link}
        {:error, :link, changeset, _} -> {:error, changeset}
        {:error, :superseded_target, reason, _} -> {:error, reason}
      end
    end
  end

  @doc """
  Deletes an article link, scoped by tenant.

  Records the `article_link.deleted` audit event.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `link_id` -- the article link UUID

  ## Returns

  - `{:ok, %ArticleLink{}}` on success
  - `{:error, :not_found}` if not found or belongs to another tenant
  """
  @spec delete_link(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ArticleLink.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_link(tenant_id, link_id, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    actor_type = Keyword.get(opts, :actor_type, "api_key")

    case AdminRepo.get_by(ArticleLink, id: link_id, tenant_id: tenant_id) do
      nil ->
        {:error, :not_found}

      link ->
        multi =
          Multi.new()
          |> Multi.delete(:link, link)
          |> Audit.log_in_multi(:audit, fn %{link: deleted} ->
            %{
              tenant_id: tenant_id,
              entity_type: "article_link",
              entity_id: deleted.id,
              action: "article_link.deleted",
              actor_type: actor_type,
              actor_id: actor_id,
              actor_label: actor_label,
              old_state: %{
                "source_article_id" => to_string(deleted.source_article_id),
                "target_article_id" => to_string(deleted.target_article_id),
                "relationship_type" => to_string(deleted.relationship_type)
              }
            }
          end)
          |> EventGenerator.generate_events(:webhook_events, fn %{link: deleted} ->
            %{
              tenant_id: tenant_id,
              event_type: "article_link.deleted",
              payload: %{
                "id" => deleted.id,
                "source_article_id" => deleted.source_article_id,
                "target_article_id" => deleted.target_article_id,
                "relationship_type" => to_string(deleted.relationship_type)
              }
            }
          end)

        case AdminRepo.transaction(multi) do
          {:ok, %{link: deleted}} -> {:ok, deleted}
          {:error, :link, changeset, _} -> {:error, changeset}
          {:error, :audit, changeset, _} -> {:error, changeset}
        end
    end
  end

  @doc """
  Lists all links for an article (both outgoing and incoming),
  with linked articles preloaded.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `article_id` -- the article UUID

  ## Returns

  - List of `%ArticleLink{}` structs with linked articles preloaded
  """
  @spec list_links_for_article(Ecto.UUID.t(), Ecto.UUID.t()) :: [ArticleLink.t()]
  def list_links_for_article(tenant_id, article_id) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.source_article_id == ^article_id or l.target_article_id == ^article_id,
      preload: [:source_article, :target_article],
      order_by: [desc: l.inserted_at]
    )
    |> AdminRepo.all()
  end

  # --- Private helpers ---

  defp fetch_article(tenant_id, article_id) do
    case AdminRepo.get_by(Article, id: article_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      article -> {:ok, article}
    end
  end

  defp validate_project_ownership(_tenant_id, nil), do: :ok

  defp validate_project_ownership(tenant_id, project_id) do
    case AdminRepo.get_by(Project, id: project_id, tenant_id: tenant_id) do
      nil ->
        {:error,
         %Article{}
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:project_id, "does not belong to this tenant")}

      _project ->
        :ok
    end
  end

  defp apply_article_filters(query, opts) do
    query
    |> maybe_filter_by_project_id(Keyword.get(opts, :project_id))
    |> maybe_filter_by_category(Keyword.get(opts, :category))
    |> maybe_filter_by_status(Keyword.get(opts, :status))
    |> maybe_filter_by_tags(Keyword.get(opts, :tags))
  end

  defp maybe_filter_by_project_id(query, nil), do: query

  defp maybe_filter_by_project_id(query, project_id) do
    where(query, [a], a.project_id == ^project_id)
  end

  defp maybe_filter_by_category(query, nil), do: query

  defp maybe_filter_by_category(query, category) do
    where(query, [a], a.category == ^category)
  end

  defp maybe_filter_by_status(query, nil), do: query

  defp maybe_filter_by_status(query, status) do
    where(query, [a], a.status == ^status)
  end

  defp maybe_filter_by_tags(query, nil), do: query
  defp maybe_filter_by_tags(query, []), do: query

  defp maybe_filter_by_tags(query, tags) when is_list(tags) do
    where(query, [a], fragment("? && ?", a.tags, ^tags))
  end

  defp validate_articles_exist(tenant_id, source_id, target_id) do
    source_exists =
      from(a in Article,
        where: a.id == ^source_id and a.tenant_id == ^tenant_id,
        select: true
      )
      |> AdminRepo.one()

    target_exists =
      from(a in Article,
        where: a.id == ^target_id and a.tenant_id == ^tenant_id,
        select: true
      )
      |> AdminRepo.one()

    cond do
      is_nil(source_exists) ->
        {:error,
         %Article{}
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:source_article_id, "does not exist in this tenant")}

      is_nil(target_exists) ->
        {:error,
         %Article{}
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:target_article_id, "does not exist in this tenant")}

      true ->
        :ok
    end
  end

  defp maybe_supersede_target(multi, tenant_id, _target_id, rel_type)
       when rel_type in [:supersedes, "supersedes"] do
    Multi.run(multi, :superseded_target, fn _repo, changes ->
      case AdminRepo.get_by(Article,
             id: changes.link.target_article_id,
             tenant_id: tenant_id
           ) do
        nil ->
          {:error, :target_not_found}

        target ->
          target
          |> Article.update_changeset(%{status: :superseded})
          |> AdminRepo.update()
      end
    end)
  end

  defp maybe_supersede_target(multi, _tenant_id, _target_id, _rel_type), do: multi

  defp build_link_audit(tenant_id, changes, opts) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    actor_type = Keyword.get(opts, :actor_type, "api_key")

    new_state = %{
      "source_article_id" => to_string(changes.link.source_article_id),
      "target_article_id" => to_string(changes.link.target_article_id),
      "relationship_type" => to_string(changes.link.relationship_type)
    }

    new_state =
      if Map.has_key?(changes, :superseded_target) do
        Map.put(new_state, "target_superseded", true)
      else
        new_state
      end

    %{
      tenant_id: tenant_id,
      entity_type: "article_link",
      entity_id: changes.link.id,
      action: "article_link.created",
      actor_type: actor_type,
      actor_id: actor_id,
      actor_label: actor_label,
      new_state: new_state
    }
  end

  defp article_state_snapshot(article) do
    %{
      "title" => article.title,
      "body" => article.body,
      "category" => to_string(article.category),
      "status" => to_string(article.status),
      "tags" => article.tags,
      "project_id" => article.project_id,
      "metadata" => article.metadata
    }
  end

  defp article_event_payload(article) do
    %{
      "id" => article.id,
      "title" => article.title,
      "category" => to_string(article.category),
      "project_id" => article.project_id,
      "status" => to_string(article.status),
      "tags" => article.tags
    }
  end

  defp generate_link_created_events(multi, tenant_id, source_id, target_id, rel_type) do
    multi
    |> EventGenerator.generate_events(:webhook_events, fn %{link: link} ->
      source = AdminRepo.get!(Article, source_id)
      target = AdminRepo.get!(Article, target_id)

      %{
        tenant_id: tenant_id,
        event_type: "article_link.created",
        payload: %{
          "id" => link.id,
          "source_article_id" => link.source_article_id,
          "target_article_id" => link.target_article_id,
          "relationship_type" => to_string(link.relationship_type),
          "source_title" => source.title,
          "target_title" => target.title
        }
      }
    end)
    |> maybe_generate_superseded_event(tenant_id, source_id, target_id, rel_type)
  end

  defp maybe_generate_superseded_event(multi, tenant_id, source_id, target_id, rel_type)
       when rel_type in [:supersedes, "supersedes"] do
    EventGenerator.generate_events(multi, :webhook_events_superseded, fn _changes ->
      source = AdminRepo.get!(Article, source_id)
      target = AdminRepo.get!(Article, target_id)

      %{
        tenant_id: tenant_id,
        event_type: "article.superseded",
        project_id: target.project_id,
        payload: %{
          "superseded_article_id" => target_id,
          "superseded_title" => target.title,
          "superseding_article_id" => source_id,
          "superseding_title" => source.title
        }
      }
    end)
  end

  defp maybe_generate_superseded_event(multi, _tenant_id, _source_id, _target_id, _rel_type),
    do: multi
end
