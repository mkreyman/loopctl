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
  3. **Consolidates the corpus, report-only** (#584 stage 1) — reuses the lint
     report just computed and runs `Loopctl.Knowledge.Consolidation.run/3`, which
     emits numbered, evidence-carrying proposals for the four observed defect
     classes and persists them as the tenant's report for the day. It writes
     NOTHING to `articles` / `article_links` / `conflict_resolutions`. This runs
     inside the existing nightly pass on purpose: a second scheduler over the same
     corpus is the specific failure #584 names. It is also FAIL-SOFT: a raise or a
     pool exit inside it is recorded in the audit event and never aborts the run
     (see `consolidate/2`).
  4. **Surfaces all findings** via an immutable audit event
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
  alias Loopctl.Embeddings
  alias Loopctl.ExitTag
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.Consolidation
  alias Loopctl.Oban.FairShare
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Workers.ArticleLinkingWorker
  alias Loopctl.Workers.BatchArticleEmbeddingWorker

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

  def perform(%Oban.Job{id: id, args: %{"tenant_id" => tenant_id}}) do
    # US-36.2: fair-share gate on the shared :knowledge queue (do NOT gate the
    # all_tenants dispatcher clause above — it carries no tenant_id). Yield loss-free
    # when this tenant is at/above its fair share of executing slots. `id` excludes
    # THIS (already-executing) job from its own count — see FairShare.
    case FairShare.gate(tenant_id, :knowledge, id) do
      {:snooze, _n} = snooze -> snooze
      :ok -> lint_tenant(tenant_id)
    end
  end

  defp lint_tenant(tenant_id) do
    {:ok, report} = Knowledge.lint(tenant_id, max_per_category: @lint_max_per_category)

    action = act_on_orphans(tenant_id, report)
    promoted = promote_conflicts(tenant_id)
    resolutions_applied = Knowledge.execute_conflict_resolutions(tenant_id)
    consolidation = consolidate(tenant_id, report)
    log_audit_event(tenant_id, report, action, promoted, resolutions_applied, consolidation)

    Logger.info(
      "KnowledgeLintWorker: tenant=#{tenant_id} issues=#{report.summary.total_issues} " <>
        "orphans_relinked=#{action.relinked} orphans_embedding_enqueued=#{action.embedding_enqueued} " <>
        "conflicts_promoted=#{promoted} resolutions_applied=#{resolutions_applied} " <>
        consolidation_log(consolidation)
    )

    :ok
  end

  # Hard wall-clock backstop for a shared `:knowledge` queue slot (review #4).
  # `Knowledge.execute_conflict_resolutions/2` is itself budget-bounded (~2 min),
  # and orphan re-link only ENQUEUES cheap jobs, so a healthy per-tenant run is
  # well under this; without it, an Oban default of `:infinity` would let a
  # pathological run pin a slot indefinitely (concurrency 5) and starve other
  # tenants' ingestion/review jobs.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

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

    # US-37.4 (LOW review): batch the orphan-embedding backfill instead of fanning
    # out one single-text `ArticleEmbeddingWorker` per orphan. A corpus backfill can
    # otherwise issue N per-record provider round-trips — the exact background
    # amplification US-37.4 collapses. Chunk into groups of
    # `Knowledge.embedding_batch_max/0` and enqueue ONE `BatchArticleEmbeddingWorker`
    # per chunk (one provider array call, one admission token + one slot per batch).
    without_embedding
    |> Enum.chunk_every(Knowledge.embedding_batch_max())
    |> Enum.each(fn chunk ->
      %{article_ids: chunk, tenant_id: tenant_id}
      |> BatchArticleEmbeddingWorker.new()
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
        # PROVENANCE (kb-02): only promote relates_to links that a SYSTEM writer
        # authored (ArticleLinkingWorker stamps auto_generated:true + a real cosine
        # similarity_score). Without this, an agent could POST a relates_to link with a
        # forged similarity_score and launder it into a system-stamped potential_conflict
        # here — which would then satisfy validate_potential_conflict_exists and let a
        # fabricated pair be resolved into a supersede. The public link controller now
        # strips these keys from caller input, so a genuine agent link never carries a
        # score; this filter is the second, independent barrier at the promotion site.
        where: fragment("(?->>'auto_generated') = 'true'", l.metadata),
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
        # A capped query with no ORDER BY takes an ARBITRARY `cap` rows — whichever the
        # planner happens to emit first. That made the nightly 500 a random sample of the
        # candidate set rather than the 500 most-similar pairs, so the strongest redundancy
        # signals could sit unpromoted for weeks behind weaker ones. Ordering costs nothing
        # here: `article_links_potential_conflict_idx` already covers this expression.
        order_by: [desc: fragment("(?->>'similarity_score')::float", l.metadata)],
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

  # US-41.1 (review): behind the cutover flag the presence check reads the
  # dimension-tagged side table. `articles.embedding` is NEVER written for a non-1536
  # dimension, so for a 768/1024 tenant this MapSet was always empty: every orphan was
  # classified "not embedded", the relink branch was never taken, and
  # `orphans_embedding_enqueued` grew on every run — a structurally wrong lint report
  # for exactly the tenants this epic serves, and a driver of the re-billing loop.
  defp embedded_ids(tenant_id, orphan_ids) do
    # WRITE-dimension gated (`use_side_table_hash?/1`), not read-flag gated (review):
    # a non-1536 tenant's `articles.embedding` is never written, so the read-flag gate
    # classified every orphan "not embedded" and drove the re-billing loop.
    if Embeddings.use_side_table_hash?(tenant_id) do
      Embeddings.embedded_article_ids(
        tenant_id,
        orphan_ids,
        Embeddings.active_dimension(tenant_id)
      )
    else
      legacy_embedded_ids(tenant_id, orphan_ids)
    end
  end

  defp legacy_embedded_ids(tenant_id, orphan_ids) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: a.id in ^orphan_ids,
      where: not is_nil(a.embedding),
      select: a.id
    )
    |> AdminRepo.all()
    |> MapSet.new()
  end

  # #584 stage 1: REPORT ONLY. Reuses the lint report already computed above (one
  # corpus scan per night, one scheduler) and writes only the consolidation report +
  # its proposal rows.
  #
  # FAIL-SOFT, and that is the whole point of the rescue/catch: by the time this runs,
  # `lint_tenant/1` has ALREADY taken its effectful steps (orphan re-link enqueues,
  # conflict promotions, applied resolutions) and has NOT yet written its audit event.
  # Letting a raise out of the report-only stage — a statement timeout on a large
  # corpus, an in-flight shed, an AdminRepo checkout exit — would skip
  # `log_audit_event/6` entirely, so the change feed would show NO lint for that tenant
  # that night even though state changed, and Oban's retries would redo the effectful
  # steps each time. A tenant whose corpus deterministically times out these scans would
  # lose the pre-existing pass's observability permanently. The failure is recorded in
  # the audit event instead, as a low-cardinality TAG (never the raw error, which carries
  # backend host / database / role).
  defp consolidate(tenant_id, report) do
    max_per_class =
      Application.get_env(
        :loopctl,
        :knowledge_consolidation_max_per_class,
        Consolidation.default_max_per_class()
      )

    {:ok, consolidation} = Consolidation.run(tenant_id, report, max_per_class: max_per_class)
    {:ok, consolidation}
  rescue
    error -> consolidation_failed(tenant_id, ExitTag.tag(error))
  catch
    :exit, reason -> consolidation_failed(tenant_id, "exit:" <> ExitTag.tag(reason))
  end

  defp consolidation_failed(tenant_id, tag) do
    Logger.error(
      "KnowledgeLintWorker: tenant=#{tenant_id} consolidation FAILED (#{tag}) — the lint " <>
        "pass and its audit event still complete; the consolidation report was not written."
    )

    {:error, tag}
  end

  defp consolidation_log({:ok, consolidation}) do
    "consolidation_proposals=#{consolidation.proposal_count} " <>
      "consolidation_persisted=#{consolidation.persisted_count}"
  end

  defp consolidation_log({:error, tag}), do: "consolidation=failed:#{tag}"

  # Counts of PROPOSALS (not articles): `proposal_count` is the true pre-cap total
  # across classes, `persisted_count` the rows actually written (lower only when a class
  # hit its cap). Nothing was applied — stage 1 is report-only.
  defp consolidation_state({:ok, consolidation}) do
    %{
      "status" => "ok",
      "day" => Date.to_iso8601(consolidation.day),
      "proposal_count" => consolidation.proposal_count,
      "persisted_count" => consolidation.persisted_count,
      "by_class" => consolidation.proposals_by_class,
      "truncated" => consolidation.truncated
    }
  end

  defp consolidation_state({:error, tag}), do: %{"status" => "failed", "error" => tag}

  defp log_audit_event(tenant_id, report, action, promoted, resolutions_applied, consolidation) do
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
        "resolutions_applied" => resolutions_applied,
        "consolidation" => consolidation_state(consolidation)
      }
    })
  end
end
