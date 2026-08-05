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
  alias Loopctl.Knowledge.ConflictResolution
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

  # The DRAIN for auto-generated `potential_conflict` links, and it is deliberately LARGER
  # than the promotion cap above so the queue converges instead of oscillating. At 500
  # promoted and 2000 judged per night the backlog falls by 1500/night; equal caps would
  # merely hold the line at whatever level it had already reached.
  @default_max_conflict_judgements 2000

  # Similarity at or above this is treated as high-confidence redundancy. Below it the pair
  # is still redundant enough to have been promoted, just less certainly so — the
  # `confidence` field records which, so a future reader can re-judge the weak ones without
  # re-deriving the set.
  @high_confidence_similarity 0.95

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
    # The judge runs AFTER promotion so a pair flagged tonight is also judged tonight and
    # never spends a night suppressing its two articles. It is bounded above the promotion
    # cap, so the same pass also eats into the backlog.
    judged = judge_redundant_conflicts(tenant_id)
    resolutions_applied = Knowledge.execute_conflict_resolutions(tenant_id)
    consolidation = consolidate(tenant_id, report)
    # Apply AFTER consolidate/2 wrote tonight's report, so the two-run confirmation compares
    # tonight against last night rather than last night against the night before.
    applied = apply_consolidation(tenant_id)

    log_audit_event(
      tenant_id,
      report,
      action,
      promoted,
      judged,
      resolutions_applied,
      consolidation
    )

    Logger.info(
      "KnowledgeLintWorker: tenant=#{tenant_id} issues=#{report.summary.total_issues} " <>
        "orphans_relinked=#{action.relinked} orphans_embedding_enqueued=#{action.embedding_enqueued} " <>
        "conflicts_promoted=#{promoted} conflicts_judged_redundant=#{judged} " <>
        "resolutions_applied=#{resolutions_applied} " <>
        "duplicates_unpublished=#{applied.applied} duplicate_groups_skipped=#{applied.skipped} " <>
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

  # ---------------------------------------------------------------------------
  # The automatic judge — the drain this queue never had
  # ---------------------------------------------------------------------------
  #
  # WHAT THE SIGNAL ACTUALLY MEASURES. `potential_conflict` is promoted on cosine
  # similarity >= 0.93. Similarity says "these two say the same thing"; contradiction says
  # "these two disagree." Those are ORTHOGONAL — a flat contradiction scores high, but so
  # does every honest restatement, so a similarity threshold cannot separate them and this
  # class was never measuring disagreement.
  #
  # MEASURED on the hosted corpus 2026-08-05, across all 16,117 flagged pairs:
  #   * 0 identical bodies, 0 shared source_id — so not byte-identical re-captures
  #   * 261 identical NORMALISED titles
  #   * 8,697 (54%) with body lengths within 10% of each other
  #   * a 20-pair sample spanning 0.93–0.99 contained ZERO contradictions; the top matches
  #     differ by a colon ("AWS CodeDeploy: Traffic Control" vs "AWS CodeDeploy Traffic
  #     Control"), a hyphen ("Per Share" vs "Per-Share"), a percent sign ("75–90%" vs
  #     "75%–90%") and a plural ("Formula" vs "Formulas").
  #
  # It is REDUNDANCY — the same knowledge captured twice and worded differently. So the
  # verdict recorded here is `classification: :redundant`, which is what the evidence
  # supports, NOT a fabricated finding about a contradiction nobody evaluated. The schema
  # already carried the right vocabulary (`redundant | complementary | contradictory`); the
  # promoter simply never used it.
  #
  # WHY DISMISS RATHER THAN SUPERSEDE. Dismiss keeps both articles and touches no article
  # row, so a wrong verdict costs nothing and is undone by re-annotating the same pair
  # (the table is a last-write-wins upsert on the canonical pair). Supersede retires an
  # article, and choosing WHICH one to retire needs a judgement about authority that
  # similarity cannot supply. With no human in the loop, the reversible verdict is the only
  # defensible default.
  #
  # WHY THIS EXISTS AT ALL. Before it, nothing in the system ever closed a
  # `potential_conflict`: the count was monotone by construction, and every open one
  # withheld BOTH its articles from curated answers. The suppression window is the backstop
  # for a judge that stalls; this is the judge.
  defp judge_redundant_conflicts(tenant_id) do
    cap =
      Application.get_env(
        :loopctl,
        :knowledge_lint_max_conflict_judgements,
        @default_max_conflict_judgements
      )

    unjudged =
      from(l in ArticleLink,
        as: :link,
        where: l.tenant_id == ^tenant_id,
        where: l.relationship_type == :potential_conflict,
        where: fragment("(?->>'auto_generated') = 'true'", l.metadata),
        where: not exists(judged_pair_subquery()),
        # Highest similarity first: the most certainly-redundant pairs are judged before a
        # bounded run runs out of budget. The promoter's own candidate query has no
        # ORDER BY and takes an arbitrary 500; this one is deliberate.
        order_by: [desc: fragment("(?->>'similarity_score')::float", l.metadata)],
        limit: ^cap,
        select: %{
          source_article_id: l.source_article_id,
          target_article_id: l.target_article_id,
          similarity: fragment("(?->>'similarity_score')::float", l.metadata)
        }
      )
      |> AdminRepo.all()

    Enum.reduce(unjudged, 0, fn pair, count ->
      case insert_redundancy_verdict(tenant_id, pair) do
        {:ok, _} -> count + 1
        {:error, _} -> count
      end
    end)
  end

  # Correlated on the enclosing `as: :link`, TRUE when a `conflict_resolutions` row already
  # exists for the pair in EITHER direction. Mirrors `Knowledge.conflict_unresolved_subquery/0`
  # — the pair is stored canonically (source <= target) but links are not, so both
  # orientations must be checked or a judged pair is judged again every night.
  defp judged_pair_subquery do
    from(r in "conflict_resolutions",
      where: r.tenant_id == parent_as(:link).tenant_id,
      where:
        (r.source_article_id == parent_as(:link).source_article_id and
           r.target_article_id == parent_as(:link).target_article_id) or
          (r.source_article_id == parent_as(:link).target_article_id and
             r.target_article_id == parent_as(:link).source_article_id),
      select: 1
    )
  end

  defp insert_redundancy_verdict(tenant_id, %{similarity: similarity} = pair) do
    # `validate_pair_order/1` requires source <= target by UUID string; links carry no such
    # guarantee, so canonicalise here rather than letting the changeset reject half of them.
    {src, tgt} =
      if pair.source_article_id <= pair.target_article_id,
        do: {pair.source_article_id, pair.target_article_id},
        else: {pair.target_article_id, pair.source_article_id}

    now = DateTime.utc_now()
    sim = similarity || 0.0

    attrs = %{
      source_article_id: src,
      target_article_id: tgt,
      classification: :redundant,
      disposition: :dismiss,
      confidence: if(sim >= @high_confidence_similarity, do: :high, else: :medium),
      evidence:
        "Auto-judged by the nightly lint: cosine similarity #{Float.round(sim, 4)} indicates " <>
          "REDUNDANCY (the same knowledge stated twice), not contradiction. Similarity cannot " <>
          "distinguish agreement from disagreement, so this pair was never evidence of a " <>
          "conflict. Both articles are retained; re-annotate this pair to override.",
      annotated_by: "worker:knowledge_lint",
      annotated_at: now,
      # Dismiss has nothing to execute — mark it done so it never enters the executor's
      # pending set (which would leave it in the same limbo this drain exists to end).
      executed_at: now,
      execution_result: %{"action" => "noop", "reason" => "auto_dismissed_redundant"}
    }

    %ConflictResolution{tenant_id: tenant_id}
    |> ConflictResolution.changeset(attrs)
    |> AdminRepo.insert(
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :source_article_id, :target_article_id]
    )
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
  # FAIL-SOFT like consolidate/2 above, and for the same reason: this is the first thing in
  # the nightly run that WRITES to `articles`, and a raise here must not abort a pass whose
  # other steps already succeeded. A failure costs one night of duplicate cleanup, which is
  # the cheapest thing in the run to lose.
  defp apply_consolidation(tenant_id) do
    Consolidation.apply_confirmed_duplicates(tenant_id)
  rescue
    e ->
      Logger.error(
        "KnowledgeLintWorker: tenant=#{tenant_id} consolidation apply failed " <>
          "(#{ExitTag.tag(e)}); no duplicates unpublished this run."
      )

      %{applied: 0, skipped: 0}
  catch
    :exit, reason ->
      Logger.error(
        "KnowledgeLintWorker: tenant=#{tenant_id} consolidation apply exited " <>
          "(#{"exit:" <> ExitTag.tag(reason)}); no duplicates unpublished this run."
      )

      %{applied: 0, skipped: 0}
  end

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

  defp log_audit_event(
         tenant_id,
         report,
         action,
         promoted,
         judged,
         resolutions_applied,
         consolidation
       ) do
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
        # Both numbers are recorded because the DIFFERENCE is the convergence signal: while
        # judged > promoted the backlog is draining. If a future reading shows them equal
        # over several nights, the drain is merely holding the line and the caps need
        # revisiting — that is not visible from either number alone.
        "conflicts_judged_redundant" => judged,
        "resolutions_applied" => resolutions_applied,
        "consolidation" => consolidation_state(consolidation)
      }
    })
  end
end
