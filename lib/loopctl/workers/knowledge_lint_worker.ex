defmodule Loopctl.Workers.KnowledgeLintWorker do
  @moduledoc """
  Oban worker that runs the knowledge-wiki lint nightly and acts on the findings.

  This is the "nightly refinement" loop that both the Karpathy `llm-wiki`
  pattern (lint-and-act) and the Dan Martell second-brain workflow converge on:
  the lint *engine* already exists (`Loopctl.Knowledge.lint/2`); this worker is
  the orchestration that RUNS it on a schedule and takes a safe, automated
  repair action on the one finding that can be auto-repaired — orphans.

  ## Scheduling

  Configured via the Oban Cron plugin to run once nightly in `all_tenants`
  mode, which fans out one per-tenant job per active tenant (mirroring
  `Loopctl.Workers.ComputeSthWorker`). Lint is inherently per-tenant, so the
  fan-out keeps each tenant's analysis in its own job (independent retries,
  no cross-tenant coupling).

  ## What it does per tenant

  1. Runs `Knowledge.lint/2` (stale, orphan, contradiction, coverage-gap and
     broken-source detection).
  2. **Acts on orphans** — published articles with zero links. For each orphan
     it re-enqueues `Loopctl.Workers.ArticleLinkingWorker`, which re-runs the
     proven pgvector similarity pass against the *current* corpus. This is the
     reason a nightly pass is valuable rather than a no-op: an article orphaned
     in January (no neighbor cleared the similarity threshold at the time) can
     find neighbors that were ingested months later. Re-linking is deterministic,
     cheap, and makes **no** embedding-API calls (orphans missing an embedding
     simply no-op in the linking worker — backfilling those is a separate
     concern, out of scope here).
  3. **Surfaces all findings** via an immutable audit event
     (`knowledge.lint_completed`) carrying the full lint summary, so
     contradictions / coverage gaps / broken sources / stale counts are
     observable in the change feed even though they are not auto-repaired
     (those require human judgment).

  ## Scale safety

  Lint caps each finding array at `max_per_category` (we request the ceiling,
  500) while still reporting the *true* totals in `summary.total_per_category`.
  Orphan re-link enqueues are additionally bounded by
  `:knowledge_lint_max_orphan_relink` (default 500). When the true orphan count
  exceeds what we act on, the gap is logged — never silently dropped — so an
  operator can see that a backlog remains for the next run.
  """

  use Oban.Worker,
    queue: :knowledge,
    max_attempts: 3,
    unique: [fields: [:worker, :args], period: 60]

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Workers.ArticleEmbeddingWorker
  alias Loopctl.Workers.ArticleLinkingWorker

  # Ask lint for the ceiling so we act on as many orphans per run as the engine
  # will return; the true (pre-cap) totals still come back in the summary.
  @lint_max_per_category 500
  @default_max_orphan_relink 500
  # Orphans are, by definition, totally unlinked. Their nearest neighbor often
  # sits just UNDER the global 0.6 link threshold (a near-miss), so re-linking at
  # 0.6 leaves them isolated forever. Re-link orphans at a LOWER threshold so an
  # isolated article connects to its closest relative rather than dangling.
  @default_orphan_link_threshold 0.5
  @default_max_conflict_promotions 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_tenants"}}) do
    tenant_ids =
      from(t in Tenant, where: t.status == :active, select: t.id)
      |> AdminRepo.all()

    for tenant_id <- tenant_ids do
      %{"tenant_id" => tenant_id}
      |> __MODULE__.new()
      |> Oban.insert()
    end

    :ok
  end

  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id}}) do
    {:ok, report} = Knowledge.lint(tenant_id, max_per_category: @lint_max_per_category)

    action = act_on_orphans(tenant_id, report)
    promoted = promote_conflicts(tenant_id)
    resolutions_applied = Knowledge.execute_conflict_resolutions(tenant_id)
    log_audit_event(tenant_id, report, action, promoted, resolutions_applied)

    Logger.info(
      "KnowledgeLintWorker: tenant=#{tenant_id} issues=#{report.summary.total_issues} " <>
        "orphans_relinked=#{action.relinked} orphans_embedding_enqueued=#{action.embedding_enqueued} " <>
        "conflicts_promoted=#{promoted} resolutions_applied=#{resolutions_applied}"
    )

    :ok
  end

  # --- Private ---

  # Orphans split two ways:
  #   * has an embedding -> re-link at the lenient orphan threshold (its nearest
  #     neighbor is usually a near-miss of the default 0.6 cutoff).
  #   * no embedding -> it can NEVER link until it has one, so enqueue the
  #     embedding worker (which chains to linking on success). These are the
  #     articles a plain re-link silently no-ops on.
  defp act_on_orphans(tenant_id, report) do
    max_relink =
      Application.get_env(:loopctl, :knowledge_lint_max_orphan_relink, @default_max_orphan_relink)

    threshold =
      Application.get_env(
        :loopctl,
        :knowledge_lint_orphan_link_threshold,
        @default_orphan_link_threshold
      )

    orphan_ids = report.orphan_articles |> Enum.take(max_relink) |> Enum.map(& &1.article_id)
    true_total = report.summary.total_per_category.orphan_articles

    if true_total > length(orphan_ids) do
      Logger.warning(
        "KnowledgeLintWorker: tenant=#{tenant_id} has #{true_total} orphan articles; " <>
          "acting on #{length(orphan_ids)} this run (cap=#{max_relink}). Remainder retried next run."
      )
    end

    embedded = embedded_ids(tenant_id, orphan_ids)

    {with_embedding, without_embedding} =
      Enum.split_with(orphan_ids, &MapSet.member?(embedded, &1))

    Enum.each(with_embedding, fn id ->
      %{"article_id" => id, "tenant_id" => tenant_id, "threshold" => threshold}
      |> ArticleLinkingWorker.new()
      |> Oban.insert()
    end)

    Enum.each(without_embedding, fn id ->
      %{"article_id" => id, "tenant_id" => tenant_id}
      |> ArticleEmbeddingWorker.new()
      |> Oban.insert()
    end)

    %{relinked: length(with_embedding), embedding_enqueued: length(without_embedding)}
  end

  # Route-the-findings (#4), existing-corpus backstop: the auto-linker stored the
  # cosine `similarity_score` on every ambient `:relates_to` link. Any such link at or
  # above the conflict threshold is a "too similar to coexist" pair that predates the
  # forward detection — promote it to also carry a `:potential_conflict` flag (no new
  # embedding calls). Bounded per run; cycles the corpus over nights. Idempotent: a
  # pair already flagged (either direction) is skipped.
  defp promote_conflicts(tenant_id) do
    threshold = Application.get_env(:loopctl, :knowledge_conflict_threshold, 0.93)

    cap =
      Application.get_env(
        :loopctl,
        :knowledge_lint_max_conflict_promotions,
        @default_max_conflict_promotions
      )

    candidates =
      from(l in ArticleLink,
        as: :rel,
        where: l.tenant_id == ^tenant_id,
        where: l.relationship_type == :relates_to,
        where: fragment("(?->>'similarity_score')::float >= ?", l.metadata, ^threshold),
        where:
          not exists(
            from(pc in ArticleLink,
              where:
                pc.tenant_id == parent_as(:rel).tenant_id and
                  pc.relationship_type == :potential_conflict and
                  ((pc.source_article_id == parent_as(:rel).source_article_id and
                      pc.target_article_id == parent_as(:rel).target_article_id) or
                     (pc.source_article_id == parent_as(:rel).target_article_id and
                        pc.target_article_id == parent_as(:rel).source_article_id))
            )
          ),
        select: %{
          source_article_id: l.source_article_id,
          target_article_id: l.target_article_id,
          metadata: l.metadata
        },
        limit: ^cap
      )
      |> AdminRepo.all()

    Enum.reduce(candidates, 0, fn c, count ->
      attrs = %{
        source_article_id: c.source_article_id,
        target_article_id: c.target_article_id,
        relationship_type: :potential_conflict,
        metadata: %{
          "auto_generated" => true,
          "similarity_score" => c.metadata["similarity_score"],
          "promoted_from" => "relates_to"
        }
      }

      changeset = ArticleLink.changeset(%ArticleLink{tenant_id: tenant_id}, attrs)

      case AdminRepo.insert(changeset) do
        {:ok, _} -> count + 1
        # Lost a race / already exists — skip, stay idempotent.
        {:error, _} -> count
      end
    end)
  end

  defp embedded_ids(_tenant_id, []), do: MapSet.new()

  defp embedded_ids(tenant_id, orphan_ids) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: a.id in ^orphan_ids,
      where: not is_nil(a.embedding),
      select: a.id
    )
    |> AdminRepo.all()
    |> MapSet.new()
  end

  defp log_audit_event(tenant_id, report, action, promoted, resolutions_applied) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "knowledge_lint",
      entity_id: tenant_id,
      action: "knowledge.lint_completed",
      actor_type: "system",
      actor_id: nil,
      actor_label: "worker:knowledge_lint",
      new_state: %{
        "summary" => report.summary,
        "orphans_relinked" => action.relinked,
        "orphans_embedding_enqueued" => action.embedding_enqueued,
        "conflicts_promoted" => promoted,
        "resolutions_applied" => resolutions_applied
      }
    })
  end
end
