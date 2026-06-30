defmodule Loopctl.Workers.KnowledgeMocWorker do
  @moduledoc """
  Generates and maintains **Maps of Content** (MOCs) — per-domain index hubs that
  let agents navigate the corpus by domain instead of brute-force search
  (Karpathy llm-wiki rule #7: navigate by index at scale).

  Design principle: the KB does only MECHANICAL work; intelligence lives at
  consumption. So a MOC body is a deterministic, grouped, cross-linked index —
  **no LLM narrative** (which the killed "session memory compiler" idea showed is
  brittle without an eval loop). An agent reads the hub and `knowledge_get`s the
  entries it needs; the smart synthesis happens in the consuming session.

  ## What it does (per tenant)

  1. `tag_facets/2` → tags carrying at least `:knowledge_moc_min_tag_count`
     articles (the structural `hub`/`moc` tags excluded), top
     `:knowledge_moc_max_tags` by count.
  2. For each tag, upsert an `Index: <tag>` hub article:
     - `idempotency_key: "moc:<tag>"` so re-runs UPDATE the same hub rather than
       duplicating; the body is refreshed each run as the corpus grows.
     - `category: reference`, `tags: ["hub", "moc", <tag>]`, published.
     - body = the tag's published members grouped by category, each as
       `title — <id>` (capped per category), other MOCs excluded.
  3. Emit a `knowledge.moc_generated` audit event.

  Scheduled weekly. Additive only (creates/refreshes hubs) — it never mutates
  member articles, so there's no corruption risk.
  """

  use Oban.Worker,
    queue: :knowledge,
    max_attempts: 3,
    unique: [fields: [:worker, :args], period: 300]

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Knowledge
  alias Loopctl.Tenants.Tenant

  @default_min_tag_count 25
  @default_max_tags 50
  @max_members 300
  @max_per_category 40

  # MOCs index TOPICAL domains. The highest-count tags are usually structural —
  # format/source-type descriptors (`pdf`, `document`, `youtube`, …) that say how
  # an article arrived, not what it's about — so a MOC for them is useless noise.
  # Exclude them, plus the per-source provenance-id tags (`yt-…`, `doc-…`, …).
  # Corpus-specific source collections are added via `:knowledge_moc_excluded_tags`.
  @structural_tags ~w(
    hub moc reference document documents doc book books code repo repository
    web web-article webpage url file pdf md markdown html htm xml docx txt text
    epub csv json yaml image png jpg jpeg gif svg video audio youtube newsletter
    manual agent session_log session-log skill ingestion review_finding review-finding
  )

  @excluded_prefixes ~w(yt- doc- repo- url- book- img- file- vid- web- chunk-)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_tenants"}}) do
    from(t in Tenant, where: t.status == :active, select: t.id)
    |> AdminRepo.all()
    |> Enum.each(fn tenant_id ->
      %{"tenant_id" => tenant_id} |> __MODULE__.new() |> Oban.insert()
    end)

    :ok
  end

  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id}}) do
    min_count =
      Application.get_env(:loopctl, :knowledge_moc_min_tag_count, @default_min_tag_count)

    max_tags = Application.get_env(:loopctl, :knowledge_moc_max_tags, @default_max_tags)

    excluded =
      (@structural_tags ++ Application.get_env(:loopctl, :knowledge_moc_excluded_tags, []))
      |> MapSet.new()

    %{facets: facets} = Knowledge.tag_facets(tenant_id, limit: 2000)

    tags =
      facets
      |> Enum.filter(fn %{tag: tag, count: count} ->
        count >= min_count and topical_tag?(tag, excluded)
      end)
      |> Enum.sort_by(fn %{count: count} -> count end, :desc)
      |> Enum.take(max_tags)

    generated =
      Enum.count(tags, fn %{tag: tag, count: count} ->
        upsert_moc(tenant_id, tag, count) == :ok
      end)

    log_audit(tenant_id, generated, length(tags))

    Logger.info(
      "KnowledgeMocWorker: tenant=#{tenant_id} maintained #{generated}/#{length(tags)} MOC hubs"
    )

    :ok
  end

  # --- Private ---

  # A tag earns a MOC only if it's neither a structural/format/source tag nor a
  # per-source provenance id (`yt-…`, `doc-…`, …) — i.e. it names a topic.
  defp topical_tag?(tag, excluded) do
    not MapSet.member?(excluded, tag) and
      not Enum.any?(@excluded_prefixes, &String.starts_with?(tag, &1))
  end

  defp upsert_moc(tenant_id, tag, count) do
    members =
      Knowledge.list_articles(tenant_id,
        tags: [tag],
        match: :any,
        status: :published,
        limit: @max_members
      ).data
      # Never list MOCs inside a MOC.
      |> Enum.reject(fn a -> "moc" in (a.tags || []) end)

    body = build_body(tag, count, members)
    moc_tags = ["hub", "moc", tag]

    attrs = %{
      title: "Index: #{tag}",
      body: body,
      category: :reference,
      status: :published,
      tags: moc_tags,
      idempotency_key: "moc:#{tag}"
    }

    # create_article ensures the hub exists; update then refreshes its body as
    # the corpus grows. `status` is set on CREATE only — re-publishing an
    # already-published article is a no-op the changeset rejects.
    with {:ok, id} <- ensure_hub(tenant_id, attrs),
         {:ok, _} <-
           Knowledge.update_article(
             tenant_id,
             id,
             %{body: body, tags: moc_tags},
             actor_type: "system",
             actor_label: "worker:knowledge_moc"
           ) do
      :ok
    else
      other ->
        Logger.warning("KnowledgeMocWorker: upsert failed for tag=#{tag}: #{inspect(other)}")
        :error
    end
  end

  # create_article returns `{:ok, article}` on a fresh create and
  # `{:ok, :deduplicated, article}` (or another reason tuple) when the
  # idempotency_key already exists — normalize both to the hub id.
  defp ensure_hub(tenant_id, attrs) do
    case Knowledge.create_article(tenant_id, attrs) do
      {:ok, %{id: id}} -> {:ok, id}
      {:ok, _reason, %{id: id}} -> {:ok, id}
      other -> other
    end
  end

  defp build_body(tag, count, members) do
    sections =
      members
      |> Enum.group_by(fn a -> to_string(a.category) end)
      |> Enum.sort_by(fn {category, _} -> category end)
      |> Enum.map_join("\n\n", &render_section/1)

    """
    # Index: #{tag}

    Map of content for the **#{tag}** domain — #{count} articles, grouped by \
    category. Auto-generated; fetch any entry with its id.

    #{sections}
    """
  end

  defp render_section({category, articles}) do
    rows =
      articles
      |> Enum.sort_by(& &1.title)
      |> Enum.take(@max_per_category)
      |> Enum.map_join("\n", fn a -> "- #{a.title} — `#{a.id}`" end)

    overflow =
      if length(articles) > @max_per_category do
        "\n- … +#{length(articles) - @max_per_category} more"
      else
        ""
      end

    "## #{category} (#{length(articles)})\n#{rows}#{overflow}"
  end

  defp log_audit(tenant_id, generated, qualifying) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "knowledge_moc",
      entity_id: tenant_id,
      action: "knowledge.moc_generated",
      actor_type: "system",
      actor_id: nil,
      actor_label: "worker:knowledge_moc",
      new_state: %{"generated" => generated, "qualifying_tags" => qualifying}
    })
  end
end
