defmodule Loopctl.Workers.KnowledgeLintWorker do
  @moduledoc """
  Oban worker that runs the knowledge-wiki lint nightly and acts on the findings.

  This is the "nightly refinement" loop that both the Karpathy `llm-wiki`
  pattern (lint-and-act) and the Dan Martell second-brain workflow converge on:
  the lint *engine* already exists (`Loopctl.Knowledge.lint/2`); this worker is
  the orchestration that RUNS it on a schedule and takes the automated repair
  actions that are safe to take unattended.

  What makes a repair safe here is REVERSIBILITY, not confidence (#605). Every
  automated write below can be undone in code — a re-linked orphan, a conflict
  verdict re-annotated, an unpublished duplicate re-published. No step archives
  an article or waits on a human verdict that will never arrive.

  ONE step deletes, and the exception is deliberate: link pruning (#611) removes
  `relates_to` rows. An undo would be meaningless there and a soft-delete column
  would be worse, because such an edge is a DERIVED ARTIFACT rather than a record
  — a pure function of two embeddings and a threshold, which
  `ArticleLinkingWorker` recomputes from the same vectors. `LinkPruning` will only
  touch a row that carries its own derivation (`auto_generated` plus a
  `similarity_score`), so a hand-made link is structurally out of reach. Read that
  as the rule it is: *regenerable* is the property that licenses a delete, and it
  is narrower than "we can rebuild something like it".

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
  3. **Prunes the `relates_to` graph to top-K degree** (#611 stage 0) via
     `Loopctl.Knowledge.LinkPruning`. A similarity threshold is not a bound: above
     0.6 the linking worker admitted every kNN candidate, and the hosted corpus
     reached 1,402,699 edges over 79,276 articles with 56% of articles carrying
     21+. At that density any node reaches most of the corpus in two hops, so the
     graph relates nearly everything to everything and distinguishes nothing.
     Union-kNN (an edge survives if it is in EITHER endpoint's top-K) guarantees
     every article keeps its own K nearest, which is also why the prune can never
     create an orphan. An edge at or above the conflict threshold is ranked but spared
     until step 4's promoter has flagged the pair, so the promoter keeps every candidate
     it has not reached yet. Bounded per run, worst-first, and FAIL-SOFT.
  4. **Promotes, judges and executes conflicts**, in that order and in one pass
     (#601, #606). `promote_conflicts/1` flags high-similarity pairs;
     `judge_redundant_conflicts/1` then records a verdict on them —
     `classification: :redundant, disposition: :dismiss`, because cosine
     similarity measures REDUNDANCY and cannot see contradiction, so recording
     what was actually measured is the only honest verdict available;
     `Knowledge.execute_conflict_resolutions/2` carries out the recorded
     dispositions. The judge is deliberately capped ABOVE the promoter, so the
     pile shrinks by arithmetic rather than by hoping the inflow stops. The judge
     runs after the promoter within the same night so a pair flagged tonight
     never spends a night suppressing both its articles from curated answers.
  5. **Consolidates the corpus** (#584, #605) — runs
     `Loopctl.Knowledge.Consolidation.run/2`, which emits numbered,
     evidence-carrying proposals for the two live defect classes and persists them
     as the tenant's report for the day. It scans the corpus itself and takes no
     input from the lint report above. It writes nothing to `article_links` or
     `conflict_resolutions`; the ONLY article write it can make is the reversible
     confirmed-duplicate unpublish in step 6. This runs inside the existing
     nightly pass on purpose: a second scheduler over the same corpus is the
     specific failure #584 names. It is also FAIL-SOFT: a raise or a pool exit
     inside it is recorded in the audit event and never aborts the run
     (see `consolidate/1`).
  6. **Applies the confirmed duplicates** — `apply_confirmed_duplicates/2`
     unpublishes the losers of each `:duplicate_capture` group that TONIGHT's
     report and the PREVIOUS one both propose. It runs after step 5 on purpose,
     so the two-run comparison is tonight-against-last-night. Unpublish, never
     archive: `:archived` is terminal for an article and nothing unattended may
     take a one-way door.
  7. **Surfaces all findings** via an immutable audit event
     (`knowledge.lint_completed`) carrying the full lint summary, so coverage
     gaps / broken sources / stale counts are observable in the change feed even
     though nothing repairs them — each would need a correctness signal this
     pass does not have.

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
  alias Loopctl.Knowledge.LinkPruning
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
    # Ordering the prune against its neighbours is a matter of cost, not correctness, and both
    # halves of that are structural rather than positional. Union-kNN keeps every article's own
    # top-K, so an article holding at least one edge holds it at rank 1 and the prune cannot
    # create an orphan. And a `relates_to` edge at or above the conflict threshold is RANKED but
    # SPARED while the pair carries no `:potential_conflict` edge, so the prune cannot take a
    # candidate out from under `promote_conflicts/1` below — which is capped at 500/night
    # against a much larger backlog, so a pair deleted before it was reached would be lost to
    # conflict detection permanently. The spare lifts once the pair is flagged: it is no longer
    # promoter input, and an unconditional exemption would make it permanently unprunable.
    pruned = prune_links(tenant_id)
    promoted = promote_conflicts(tenant_id)
    # The judge runs AFTER promotion so a pair flagged tonight is also judged tonight and
    # never spends a night suppressing its two articles. It is bounded above the promotion
    # cap, so the same pass also eats into the backlog.
    judged = judge_redundant_conflicts(tenant_id)
    resolutions_applied = Knowledge.execute_conflict_resolutions(tenant_id)
    consolidation = consolidate(tenant_id)
    # Apply AFTER consolidate/1 wrote tonight's report, so the two-run confirmation compares
    # tonight against last night rather than last night against the night before — and ONLY
    # when it did. `consolidate/1` is fail-soft, and on a tenant whose scans deterministically
    # fail (statement timeout, in-flight shed, checkout exit) the two most recent reports are
    # last night and the night before: the agreement gate would silently degrade to "two stale
    # reports agree" and unpublish on evidence nobody re-derived, every night the scan keeps
    # failing.
    applied = apply_consolidation(tenant_id, consolidation)

    log_audit_event(tenant_id, report, %{
      action: action,
      pruned: pruned,
      promoted: promoted,
      judged: judged,
      resolutions_applied: resolutions_applied,
      consolidation: consolidation,
      applied: applied
    })

    Logger.info(
      "KnowledgeLintWorker: tenant=#{tenant_id} issues=#{report.summary.total_issues} " <>
        "orphans_relinked=#{action.relinked} orphans_embedding_enqueued=#{action.embedding_enqueued} " <>
        "conflicts_promoted=#{promoted} conflicts_judged_redundant=#{judged} " <>
        "links_pruned=#{pruned.pruned} links_prunable_remaining=#{pruned.remaining} " <>
        "resolutions_applied=#{resolutions_applied} " <>
        "duplicates_unpublished=#{applied.applied} duplicate_groups_skipped=#{applied.skipped} " <>
        "duplicate_apply_gate=#{applied.gate} " <>
        "duplicates_unpublish_failed=#{applied.failed} " <>
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

  # Runs ONLY on a report written tonight — see the call site in `lint_tenant/1` for why a
  # failed `consolidate/1` must not fall through to an apply against two stale reports.
  #
  # FAIL-SOFT like `consolidate/1` below, and for the same reason: this is the first thing in
  # the nightly run that WRITES to `articles`, and a raise here must not abort a pass whose
  # other steps already succeeded. A failure costs one night of duplicate cleanup, which is
  # the cheapest thing in the run to lose.
  #
  # Per-group failures are contained inside `apply_confirmed_duplicates/2` itself (that
  # reduce is not transactional, so an escaping raise would discard the tally of groups
  # whose unpublishes had already committed). What reaches this rescue is a failure BEFORE
  # any write — the confirmed-set SELECT — so a zero tally here is true; it carries an
  # `:error` tag so the audit event still separates it from a night with nothing to apply.
  # FAIL-SOFT for the same reason `consolidate/1` is: by the time this runs the pass has
  # already taken effectful steps and has not yet written its audit event, so letting a
  # statement timeout or a pool exit out of here would lose the whole night's record.
  # A failed prune is reported as `remaining: -1` — distinguishable from "nothing left to
  # prune" (0), because a zero here would read as a converged graph.
  defp prune_links(tenant_id) do
    case LinkPruning.prune(tenant_id) do
      {:ok, result} -> result
      # NOT a bare `{:ok, _} =` match: `prune/2` returns `{:error, _}` when a batch rolls back
      # before anything committed, and a MatchError there would reach the rescue below as a
      # made-up exception class rather than the reason the prune actually failed.
      {:error, reason} -> prune_failed(tenant_id, ExitTag.tag(reason))
    end
  rescue
    e -> prune_failed(tenant_id, ExitTag.tag(e))
  catch
    :exit, reason -> prune_failed(tenant_id, "exit:" <> ExitTag.tag(reason))
  end

  defp prune_failed(tenant_id, tag) do
    Logger.error(
      "KnowledgeLintWorker: tenant=#{tenant_id} relates_to link pruning failed (#{tag}); " <>
        "the graph keeps its current degree this run."
    )

    %{pruned: 0, remaining: -1}
  end

  defp apply_consolidation(_tenant_id, {:error, _tag}), do: empty_tally(:scan_failed)

  defp apply_consolidation(tenant_id, {:ok, _report}) do
    Consolidation.apply_confirmed_duplicates(tenant_id,
      max_applies: applies_cap(),
      max_unpublishes: unpublishes_cap()
    )
  rescue
    e -> apply_failed(tenant_id, ExitTag.tag(e))
  catch
    :exit, reason -> apply_failed(tenant_id, "exit:" <> ExitTag.tag(reason))
  end

  # Both caps were previously unreachable from here — `apply_confirmed_duplicates/2` accepted
  # them as opts and the worker passed none, so the nightly was pinned to the module defaults
  # whatever an operator configured. That is why draining the standing backlog required
  # calling the context directly, which is not a thing a self-maintaining pass should need.
  defp applies_cap do
    Application.get_env(
      :loopctl,
      :knowledge_consolidation_max_applies,
      Consolidation.default_max_applies()
    )
  end

  defp unpublishes_cap do
    Application.get_env(
      :loopctl,
      :knowledge_consolidation_max_unpublishes,
      Consolidation.default_max_unpublishes()
    )
  end

  defp apply_failed(tenant_id, tag) do
    Logger.error(
      "KnowledgeLintWorker: tenant=#{tenant_id} consolidation apply failed " <>
        "(#{tag}); no duplicates unpublished this run."
    )

    empty_tally(:apply_failed, tag)
  end

  # ONE constructor for every zero tally this worker synthesises, so no fail-soft path can
  # ship a map missing `:gate`: `lint_tenant/1` interpolates `applied.gate` in its summary
  # line, so a map without the key raised a KeyError one line after the rescue had swallowed
  # the original error — cancelling the fail-soft it exists for and making Oban re-run every
  # effectful step of the night. Sharing the constructor is what lets the reachable
  # `:scan_failed` path guard the `:apply_failed` one, which needs a repo-level failure to
  # provoke.
  defp empty_tally(gate, error \\ nil),
    do: %{applied: 0, skipped: 0, failed: 0, gate: gate, error: error}

  # Writes the consolidation report + its proposal rows and nothing else. The APPLY is a
  # separate step (`apply_consolidation/2`, above) on purpose: this one must run first so
  # the two-run agreement gate compares tonight against last night. It scans the corpus
  # itself and takes no input from the lint report above — `:stale_entry` was the only
  # class that needed one, and #605 retired it.
  #
  # FAIL-SOFT, and that is the whole point of the rescue/catch: by the time this runs,
  # `lint_tenant/1` has ALREADY taken its effectful steps (orphan re-link enqueues,
  # conflict promotions, applied resolutions) and has NOT yet written its audit event.
  # Letting a raise out of this stage — a statement timeout on a large
  # corpus, an in-flight shed, an AdminRepo checkout exit — would skip
  # `log_audit_event/8` entirely, so the change feed would show NO lint for that tenant
  # that night even though state changed, and Oban's retries would redo the effectful
  # steps each time. A tenant whose corpus deterministically times out these scans would
  # lose the pre-existing pass's observability permanently. The failure is recorded in
  # the audit event instead, as a low-cardinality TAG (never the raw error, which carries
  # backend host / database / role).
  defp consolidate(tenant_id) do
    max_per_class =
      Application.get_env(
        :loopctl,
        :knowledge_consolidation_max_per_class,
        Consolidation.default_max_per_class()
      )

    {:ok, consolidation} = Consolidation.run(tenant_id, max_per_class: max_per_class)
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
  # hit its cap). A proposal counted here may or may not have been applied tonight, since
  # applying also requires last night's report to have agreed — so the APPLY carries its own
  # tally in this same event, which is the surface an auditor reads. All four keys are load-
  # bearing together: `duplicates_unpublished` alone reads 0 both on a quiet night and on a
  # night where every confirmed group was attempted and every write was rejected, so
  # `duplicates_unpublish_failed` (loser articles left published) and `apply_error` (the
  # apply never got past its SELECT) are what tell those apart. Each individual unpublish
  # also writes its own audit event through `Knowledge.unpublish_article/3`
  # (`actor_label: "worker:consolidation"`).
  defp consolidation_state({:ok, consolidation}, applied) do
    %{
      "status" => "ok",
      "day" => Date.to_iso8601(consolidation.day),
      "proposal_count" => consolidation.proposal_count,
      "persisted_count" => consolidation.persisted_count,
      "by_class" => consolidation.proposals_by_class,
      "truncated" => consolidation.truncated,
      "duplicates_unpublished" => applied.applied,
      "duplicate_groups_skipped" => applied.skipped,
      "duplicates_unpublish_failed" => applied.failed,
      # WHY nothing was applied, when nothing was. `:open` with zeroes is a clean corpus;
      # `:report_gap` / `:insufficient_history` mean the agreement gate refused to run,
      # `:drain_disabled` means an operator set a cap to 0, and `:apply_failed` means it ran
      # and crashed. All of them used to be the same three zeroes. Read with `.gate`, never a
      # defaulted `Map.get`: an `:open` default would record a crashed run as a clean night,
      # which is the exact distinction this key exists for.
      "duplicate_apply_gate" => to_string(applied.gate),
      "apply_error" => Map.get(applied, :error)
    }
  end

  # No report tonight means no apply ran at all (`apply_consolidation/2` is gated on the
  # `{:ok, _}`), so there are no counts to record here — but `duplicate_apply_gate` is
  # recorded anyway. It is the key an auditor parses to learn WHY nothing applied, and an
  # absent key on exactly the nights the pass failed is the one answer it must not give.
  defp consolidation_state({:error, tag}, applied),
    do: %{
      "status" => "failed",
      "error" => tag,
      "duplicate_apply_gate" => to_string(applied.gate)
    }

  # The per-step results arrive as ONE map rather than nine positionals. That is not only
  # arity hygiene: every step this worker gains adds a parameter here, and a positional list
  # that long silently accepts two same-typed counts swapped at the call site.
  defp log_audit_event(tenant_id, report, %{
         action: action,
         pruned: pruned,
         promoted: promoted,
         judged: judged,
         resolutions_applied: resolutions_applied,
         consolidation: consolidation,
         applied: applied
       }) do
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
        # Same convergence reading as the pair above, for the graph. `links_prunable_remaining`
        # is what a capped run could not reach; 0 means nothing DELETABLE is left, which is
        # weaker than "at target degree" — an edge spared as conflict-promoter input is
        # over-degree and uncounted. A -1 means the prune FAILED and is deliberately not 0 — a
        # zero there would read as drained, which is the one wrong conclusion available.
        "links_pruned" => pruned.pruned,
        "links_prunable_remaining" => pruned.remaining,
        "resolutions_applied" => resolutions_applied,
        "consolidation" => consolidation_state(consolidation, applied)
      }
    })
  end
end
