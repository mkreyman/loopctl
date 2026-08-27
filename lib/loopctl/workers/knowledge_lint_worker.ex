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
  4. **Promotes conflicts** (#601, #606) — `promote_conflicts/1` flags
     high-similarity pairs, bounded at
     `:knowledge_lint_max_conflict_promotions` (500) a night.
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
  7. **Executes recorded conflict dispositions** —
     `Knowledge.execute_conflict_resolutions/2`, itself budget-bounded (~2 min).
  8. **Judges the flagged conflicts** — `judge_redundant_conflicts/1` records a
     verdict on the promoter's pile: `classification: :redundant,
     disposition: :dismiss`, because cosine similarity measures REDUNDANCY and
     cannot see contradiction, so recording what was actually measured is the
     only honest verdict available. It is capped ABOVE the promoter, so the pile
     shrinks by arithmetic rather than by hoping the inflow stops, and it stays
     within the same night as the promoter so a pair flagged tonight never spends
     a night suppressing both its articles from curated answers.

     It runs LAST because it is the only step whose per-item cost is an outbound
     provider call, and it therefore carries the one bound the others do not
     need: a wall-clock budget (`judge_budget_ms/0`), from which this worker's
     own `timeout/1` is derived. A count cap alone bounds attempts, not cost —
     which is how a 2000-call ceiling came to sit inside a 10-minute job and kill
     six consecutive nights once the inflow outgrew the promoter's cap (#761).
  9. **Surfaces all findings** via an immutable audit event
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

  Conflict judging is bounded twice, by a count
  (`:knowledge_lint_max_conflict_judgements`) and by a wall clock
  (`:knowledge_lint_conflict_judge_budget_ms`), because only the second one bounds
  what the step actually spends. EITHER truncation is logged AND recorded in the
  audit event (`conflicts_judge_budget_exhausted`, `conflicts_judge_count_capped`)
  — a truncated night and a night with nothing left to judge are the same `judged`
  count otherwise, and telling them apart is the only way to see the queue stop
  converging. Neither flag is set on a run that drained everything it was offered:
  a bound reported unconditionally says nothing at all.
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
  alias Loopctl.Knowledge.ConflictJudge
  alias Loopctl.Knowledge.ConflictResolution
  alias Loopctl.Knowledge.Consolidation
  alias Loopctl.Knowledge.LinkPruning
  alias Loopctl.Oban.FairShare
  alias Loopctl.SystemConfig
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

  # The bound that actually holds, and the one this step never had (#761). `cap` above
  # counts ATTEMPTS; this counts TIME, which is what a step whose per-item cost is an
  # outbound provider call is really spending. Measured in production 2026-08-27 on the
  # 86k-article tenant: one judgement is ~1.7 s wall, ~0.85 s at concurrency 2, so 20
  # minutes drains ~1,400 pairs a night.
  #
  # A drain of ~1,400 covers `promote_conflicts/1` (at most
  # `@default_max_conflict_promotions`, 500 a night) with room to spare. It does NOT cover
  # the ingestion novelty gate, which no cap bounds and which put 15,246 flags in over four
  # days — ~3,800 a night, above this drain, so while that inflow persists the queue
  # DIVERGES and no value here fixes it: `timeout/1` is clamped below the Lifeline window,
  # which makes ~20 minutes the ceiling rather than a starting point, and raising concurrency
  # is not the lever either (it is deliberately below `ADMIN_POOL_SIZE`, default 3, the pool
  # every authenticated request also checks out of). Bounding the flag inflow is. The reading
  # that says it is needed is `conflicts_judge_candidates` rising run over run with
  # `conflicts_judge_count_capped` or `conflicts_judge_budget_exhausted` set.
  @default_judge_budget_ms :timer.minutes(20)

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
    # The clock the judge's budget is measured against. See `judge_budget_remaining/1`: the
    # judge gets the time this job has LEFT, not a fresh budget beside a reserve nothing
    # enforces.
    started_at = System.monotonic_time(:millisecond)

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
    consolidation = consolidate(tenant_id)
    # Apply AFTER consolidate/1 wrote tonight's report, so the two-run confirmation compares
    # tonight against last night rather than last night against the night before — and ONLY
    # when it did. `consolidate/1` is fail-soft, and on a tenant whose scans deterministically
    # fail (statement timeout, in-flight shed, checkout exit) the two most recent reports are
    # last night and the night before: the agreement gate would silently degrade to "two stale
    # reports agree" and unpublish on evidence nobody re-derived, every night the scan keeps
    # failing.
    applied = apply_consolidation(tenant_id, consolidation)
    resolutions_applied = execute_resolutions(tenant_id)
    # The judge runs AFTER promotion so a pair flagged tonight is also judged tonight and
    # never spends a night suppressing its two articles, and LAST of all the steps because it
    # is the only one whose cost is an outbound call per item. Measured in production
    # 2026-08-27, this tenant: lint 350 ms, prune 2.9 s, promote 232 ms, consolidate 3 s — a
    # combined ten seconds — against ~0.85 s PER PAIR here at concurrency 2. Ordering it last
    # means the cheap, fail-soft work of the night is already committed before the expensive
    # step starts, so a judge that exhausts its budget costs the night nothing but judgements.
    judged = judge_conflicts(tenant_id, judge_budget_remaining(started_at))

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
      # The #616 content gate is the single most likely reason a night applied nothing, and
      # without this counter that night is byte-identical to a clean corpus in both this
      # line and the audit event.
      "KnowledgeLintWorker: tenant=#{tenant_id} issues=#{report.summary.total_issues} " <>
        "orphans_relinked=#{action.relinked} orphans_embedding_enqueued=#{action.embedding_enqueued} " <>
        "conflicts_promoted=#{promoted} conflicts_judged_redundant=#{judged.judged} " <>
        "conflicts_judge_candidates=#{judged.candidates} " <>
        "conflicts_judge_budget_exhausted=#{judged.budget_exhausted} " <>
        "conflicts_judge_count_capped=#{judged.count_capped} " <>
        "links_pruned=#{pruned.pruned} links_prunable_remaining=#{pruned.remaining} " <>
        "resolutions_applied=#{resolutions_applied} " <>
        "duplicates_unpublished=#{applied.applied} duplicate_groups_skipped=#{applied.skipped} " <>
        "duplicate_apply_gate=#{applied.gate} " <>
        "duplicates_unpublish_failed=#{applied.failed} " <>
        "duplicate_groups_uncorroborated=#{applied.uncorroborated} " <>
        consolidation_log(consolidation)
    )

    :ok
  end

  # Hard wall-clock backstop for a shared `:knowledge` queue slot (review #4).
  # Without it, an Oban default of `:infinity` would let a pathological run pin a
  # slot indefinitely (concurrency 3) and starve other tenants' ingestion/review jobs.
  #
  # DERIVED from the judge's budget rather than picked, because the two drifting apart is
  # the failure this replaces (#761). A flat 10 minutes stood here while
  # `judge_redundant_conflicts/1` was allowed 2000 outbound calls at ~0.85 s each — a
  # ~28-minute ceiling inside a 10-minute job, latent for as long as the nightly inflow
  # stayed at the promoter's 500/night cap and fatal the moment it did not. It did not on
  # 2026-08-20: an ingestion burst put 15,246 `potential_conflict` flags in through the
  # novelty gate, which that cap does not bound, and every attempt on all six following
  # nights was killed inside the judge with `Oban.TimeoutError` after 600000ms.
  #
  # `@job_reserve_ms` is what the REST of the night costs, measured in production
  # 2026-08-27 on the 86k-article tenant: ~10 s for lint + prune + promote + consolidate,
  # plus the ~2-minute internal budget of `Knowledge.execute_conflict_resolutions/2`.
  # Rounded up hard, because a reserve that is too small resurrects exactly this bug.
  @job_reserve_ms :timer.minutes(5)

  # And CLAMPED below Oban's Lifeline window (`rescue_after: :timer.minutes(30)`,
  # `Loopctl.ObanConfig.plugins/0`). Lifeline never checks whether a job is still alive: it
  # moves anything left `executing` past that window back to `available`, so a run allowed to
  # outlast it is re-dispatched CONCURRENTLY WITH ITSELF — two nightly passes on one tenant,
  # the same pairs judged and billed twice, and two `apply_consolidation/2` runs against one
  # report. Raising the judge budget past this ceiling therefore raises nothing; the test
  # reads the real plugin option and binds it to this constant so the two cannot drift.
  @lifeline_rescue_after_ms :timer.minutes(30)
  @job_timeout_ceiling_ms @lifeline_rescue_after_ms - :timer.minutes(5)

  @impl Oban.Worker
  def timeout(_job), do: job_timeout_ms()

  # --- Private ---

  defp job_timeout_ms,
    do: min(judge_budget_ms() + @job_reserve_ms, @job_timeout_ceiling_ms)

  # The judge is handed the time the job has LEFT, never a fresh budget. `@job_reserve_ms` is
  # a MEASURED constant and nothing makes the steps before the judge respect it, so a night
  # whose prelude overruns — a slow consolidate, an executor that spends its whole ~2-minute
  # budget — would otherwise start a full-length judging step inside a job that can no longer
  # contain it and die with `Oban.TimeoutError`: #761 again, and now with tonight's
  # unpublishes already committed and an Oban retry about to spend the nightly caps again.
  # `@judge_overshoot_ms` pays for the one in-flight provider call the deadline cannot
  # interrupt (Anthropic `receive_timeout` 25 s).
  @judge_overshoot_ms :timer.seconds(45)

  defp judge_budget_remaining(started_at) do
    elapsed = System.monotonic_time(:millisecond) - started_at

    (job_timeout_ms() - elapsed - @judge_overshoot_ms)
    |> max(0)
    |> min(judge_budget_ms())
  end

  # FAIL-SOFT, like every step that runs after the night has already written state
  # (`consolidate/1`, `apply_consolidation/2`). Both of these now run AFTER the unpublishes,
  # so a raise escaping either would discard the audit event AND hand the night to an Oban
  # retry that re-runs `apply_consolidation/2` from the top, spending
  # `:knowledge_consolidation_max_unpublishes` a second and a third time — a cap that is the
  # operator's only mid-incident lever (#617). Eating the error costs one night of executions
  # or judgements; not eating it costs a tripled cap.
  @no_judgements %{judged: 0, candidates: 0, budget_exhausted: false, count_capped: false}

  defp execute_resolutions(tenant_id) do
    Knowledge.execute_conflict_resolutions(tenant_id)
  rescue
    error -> step_failed(tenant_id, "conflict resolution execution", ExitTag.tag(error), 0)
  catch
    :exit, reason ->
      step_failed(tenant_id, "conflict resolution execution", "exit:" <> ExitTag.tag(reason), 0)
  end

  defp judge_conflicts(tenant_id, budget_ms) do
    judge_redundant_conflicts(tenant_id, budget_ms: budget_ms)
  rescue
    error -> step_failed(tenant_id, "conflict judging", ExitTag.tag(error), @no_judgements)
  catch
    :exit, reason ->
      step_failed(tenant_id, "conflict judging", "exit:" <> ExitTag.tag(reason), @no_judgements)
  end

  defp step_failed(tenant_id, step, tag, zero) do
    Logger.error(
      "KnowledgeLintWorker: tenant=#{tenant_id} #{step} FAILED (#{tag}) — the lint pass and " <>
        "its audit event still complete; the remainder is retried next run."
    )

    zero
  end

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
              # An ASSERTED flag (#730) does NOT block promotion. The pair's
              # `potential_conflict` slot is UNIQUE, so treating an assertion as
              # "already flagged" let any agent permanently pre-empt the system
              # pipeline for two articles of its choosing: the system flag could never
              # be stamped, and curated suppression — which requires `auto_generated`
              # — could therefore never fire for that pair again. An assertion is a
              # CLAIM awaiting review; only a system flag is a system finding, and
              # only a system finding may stand in for one. A legacy markerless row
              # still blocks, exactly as before: this carve-out is scoped to the one
              # provenance a caller can create.
              where:
                pc.tenant_id == parent_as(:rel).tenant_id and
                  pc.relationship_type == :potential_conflict and
                  fragment("COALESCE(?->>'asserted', 'false') <> 'true'", pc.metadata) and
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

      if flag_conflict(tenant_id, c, attrs), do: count + 1, else: count
    end)
  end

  # One candidate's write. Extracted so `promote_conflicts/1` stays inside Credo's
  # complexity and nesting bars, and because the UPGRADE-before-INSERT ordering is the part
  # worth reading on its own.
  #
  # The pair may already carry an ASSERTED row, which the candidate query above now
  # deliberately ignores (#730) — inserting over it would violate
  # `article_links_tenant_src_tgt_rel_index` and be swallowed as "already exists", leaving
  # the pair unpromoted forever. An explicit update is also direction-safe: an assertion
  # stores its pair canonically (src <= tgt) while this candidate carries the `relates_to`
  # edge's own order, so an upsert keyed on the unique target could miss and create a
  # SECOND row for the same pair.
  defp flag_conflict(tenant_id, candidate, attrs) do
    case upgrade_asserted_conflict(tenant_id, candidate) do
      :upgraded ->
        true

      :none ->
        changeset = ArticleLink.changeset(%ArticleLink{tenant_id: tenant_id}, attrs)

        case AdminRepo.insert(changeset) do
          {:ok, _} -> true
          # Lost a race / already exists — skip, stay idempotent.
          {:error, _} -> false
        end
    end
  end

  # The assertion's own fields are PRESERVED, `asserted_by_principal` above all: the system
  # confirming a pair independently does not make its asserter a disinterested judge of it,
  # so `Knowledge.validate_not_self_asserted/2` must keep refusing them afterwards.
  #
  # Stamp system provenance onto an existing ASSERTED flag for this pair, in either
  # direction. Returns `:upgraded` when a row was updated, `:none` when there is none to
  # upgrade (the ordinary path). `jsonb ||` merges, so every assertion field survives and
  # only the two system keys are written.
  defp upgrade_asserted_conflict(tenant_id, candidate) do
    src = candidate.source_article_id
    tgt = candidate.target_article_id
    score = candidate.metadata["similarity_score"]

    {updated, _} =
      from(l in ArticleLink,
        where: l.tenant_id == ^tenant_id,
        where: l.relationship_type == :potential_conflict,
        where: fragment("(?->>'asserted') = 'true'", l.metadata),
        where: fragment("COALESCE(?->>'auto_generated', 'false') <> 'true'", l.metadata),
        where:
          (l.source_article_id == ^src and l.target_article_id == ^tgt) or
            (l.source_article_id == ^tgt and l.target_article_id == ^src),
        update: [
          set: [
            metadata:
              fragment(
                "? || jsonb_build_object('auto_generated', true, 'similarity_score', ?::float, 'promoted_from', 'asserted')",
                l.metadata,
                ^score
              )
          ]
        ]
      )
      |> AdminRepo.update_all([])

    if updated > 0, do: :upgraded, else: :none
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
  #
  # Public with an `opts` seam, for the same reason `judge_and_record/3` is: a test needs to
  # drive the budget and the judge implementation PER CALL, and the alternative —
  # `Application.put_env` — mutates VM-global state that every other test in this `async:
  # true` suite would see. `:budget_ms` and `:cap` default to the configured values, and
  # every other key is passed through to `judge_and_record/3`.
  @spec judge_redundant_conflicts(Ecto.UUID.t(), keyword()) :: %{
          judged: non_neg_integer(),
          candidates: non_neg_integer(),
          budget_exhausted: boolean(),
          count_capped: boolean()
        }
  def judge_redundant_conflicts(tenant_id, opts \\ []) do
    # Deadline FIRST, so the candidate query below — a correlated NOT EXISTS against
    # `conflict_resolutions` ordered on a jsonb cast — is charged to this clock too. The job
    # that contains it charges it either way.
    budget_ms = Keyword.get_lazy(opts, :budget_ms, &judge_budget_ms/0)
    deadline = System.monotonic_time(:millisecond) + budget_ms

    cap =
      Keyword.get_lazy(opts, :cap, fn ->
        Application.get_env(
          :loopctl,
          :knowledge_lint_max_conflict_judgements,
          @default_max_conflict_judgements
        )
      end)

    {unjudged, count_capped} =
      from(l in ArticleLink,
        as: :link,
        where: l.tenant_id == ^tenant_id,
        where: l.relationship_type == :potential_conflict,
        where: fragment("(?->>'auto_generated') = 'true'", l.metadata),
        # NEVER an ASSERTED pair (#730), including one this worker's own promoter has just
        # upgraded to `auto_generated`. This judge exists because cosine similarity
        # measures REDUNDANCY and cannot see contradiction, so `:redundant` is the only
        # honest verdict it can record. An assertion is the opposite case: a caller read
        # both articles and argued, in writing, that they CONTRADICT. Auto-dismissing that
        # as redundancy would destroy the evidence on the same night it was raised — and a
        # dismiss is terminal on record, so nothing would bring the pair back. A human or
        # an orchestrator judges an assertion; this drain judges what a threshold found.
        where: fragment("COALESCE(?->>'asserted', 'false') <> 'true'", l.metadata),
        where: not exists(judged_pair_subquery()),
        # Highest similarity first: the most certainly-redundant pairs are judged before a
        # bounded run runs out of budget. The promoter's own candidate query has no
        # ORDER BY and takes an arbitrary 500; this one is deliberate.
        order_by: [desc: fragment("(?->>'similarity_score')::float", l.metadata)],
        # ONE row more than the cap, so the count bound can say whether it BOUND anything:
        # `candidates` is `cap` on every night bigger than the cap, which reads identically to
        # a night that had exactly that many and drained them. That is the older of the two
        # bounds and the one that held a 15,246-flag backlog at 2000/night while the audit
        # event read as converged (#761).
        limit: ^(cap + 1),
        select: %{
          source_article_id: l.source_article_id,
          target_article_id: l.target_article_id,
          similarity: fragment("(?->>'similarity_score')::float", l.metadata)
        }
      )
      |> AdminRepo.all()
      |> Enum.split(cap)
      |> then(fn {offered, over_cap} -> {offered, over_cap != []} end)

    # CONCURRENT on purpose. Each pair now costs an outbound provider call (see
    # `Loopctl.Knowledge.ConflictJudge`), so a sequential reduce would turn a 450-pair night
    # into ~450 round trips end to end and a full 2000-pair catch-up run into something that
    # cannot finish inside a nightly window at all. `async_stream` gives bounded concurrency
    # with backpressure; the bound is small because it is a shared provider rate limit and a
    # shared DB pool on the other side, not because the work is expensive here — and it is
    # kept BELOW `ADMIN_POOL_SIZE` (default 3) so a nightly run can never hold every
    # AdminRepo connection that authentication also needs.
    #
    # `timeout: :infinity` on the stream with the per-task bound coming from the provider
    # client's own timeout — a stream timeout would kill the task and lose the verdict while
    # the request kept running and got billed.
    #
    # And a COUNT is not a bound on this step (#761). `cap` bounds how many pairs are
    # attempted; it says nothing about what they cost, because the cost per pair is an
    # outbound call whose latency belongs to a provider. `Enum.reduce_while/3` over the
    # stream adds the bound that is actually load-bearing — a wall clock — and it is
    # checked as each result lands, so the granularity is one judgement (~1.7 s). At most
    # `judge_concurrency()` in-flight calls are abandoned when it fires: those are billed
    # and their verdicts lost, which is the price of the step ending on time, and the pairs
    # return at the head of tomorrow's highest-similarity-first queue.
    total = length(unjudged)

    {judged, processed} =
      unjudged
      |> Task.async_stream(
        fn pair -> judge_and_record(tenant_id, pair, opts) end,
        max_concurrency: judge_concurrency(),
        timeout: :infinity,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce_while({0, 0}, fn result, {count, processed} ->
        count =
          case result do
            {:ok, {:ok, _}} -> count + 1
            _other -> count
          end

        processed = processed + 1

        # The clock is only a TRUNCATION while work is LEFT. The check runs after each result
        # including the last, so a night that drained every candidate and crossed the deadline
        # on its way out reported itself truncated — and a flag that is true on a converged
        # night is as unreadable as no flag, which is the whole point of having it.
        if processed < total and System.monotonic_time(:millisecond) >= deadline,
          do: {:halt, {count, processed}},
          else: {:cont, {count, processed}}
      end)

    budget_exhausted = processed < total

    # NEVER silent (#761 acceptance). A truncated night and a night with nothing left to
    # judge are the same number in `judged` alone, and telling them apart is the whole
    # question when the queue stops converging — which is why the COUNT cap gets its own
    # line: it truncates without the clock ever firing.
    if budget_exhausted do
      Logger.warning(
        "KnowledgeLintWorker: tenant=#{tenant_id} conflict judging hit its " <>
          "#{budget_ms}ms budget after #{judged} of #{total} candidates; " <>
          "the remainder is retried next run."
      )
    end

    if count_capped do
      Logger.warning(
        "KnowledgeLintWorker: tenant=#{tenant_id} conflict judging was truncated by its " <>
          "#{cap}-judgement count cap; more pairs are flagged than one night can offer."
      )
    end

    %{
      judged: judged,
      candidates: total,
      budget_exhausted: budget_exhausted,
      count_capped: count_capped
    }
  end

  defp judge_concurrency,
    do: Application.get_env(:loopctl, :knowledge_conflict_judge_concurrency, 2)

  @doc """
  Wall-clock budget for the nightly conflict-judging step, in milliseconds.

  Public because `timeout/1` is DERIVED from it and a test has to be able to read the same
  number both sides of that derivation — a budget larger than the job that contains it is
  precisely the defect (#761) this replaces.
  """
  @spec judge_budget_ms() :: pos_integer()
  def judge_budget_ms do
    Application.get_env(
      :loopctl,
      :knowledge_lint_conflict_judge_budget_ms,
      @default_judge_budget_ms
    )
  end

  # Correlated on the enclosing `as: :link`, TRUE when a `conflict_resolutions` row already
  # exists for the pair in EITHER direction. Mirrors `Knowledge.conflict_unresolved_subquery/0`
  # — the pair is stored canonically (source <= target) but links are not, so both
  # orientations must be checked or a judged pair is judged again every night.
  # "Has this FLAG already been judged?" — which is not "has this PAIR ever been judged".
  # The postdate predicate mirrors `Knowledge.conflict_unresolved_subquery/0` exactly: a
  # verdict settles only a flag that already existed when it was recorded. Without it, a
  # pair judged once and later RE-flagged is skipped by this drain forever while the queue
  # (which does postdate) still shows it as unjudged — the two surfaces disagreeing about
  # the same pair, with the drain's answer being the one that strands it. COALESCEd to
  # `inserted_at` so a verdict written before `annotated_at` existed still settles.
  defp judged_pair_subquery do
    from(r in "conflict_resolutions",
      where: r.tenant_id == parent_as(:link).tenant_id,
      where:
        (r.source_article_id == parent_as(:link).source_article_id and
           r.target_article_id == parent_as(:link).target_article_id) or
          (r.source_article_id == parent_as(:link).target_article_id and
             r.target_article_id == parent_as(:link).source_article_id),
      where:
        fragment(
          "COALESCE(?, ?) >= ?",
          r.annotated_at,
          r.inserted_at,
          parent_as(:link).inserted_at
        ),
      select: 1
    )
  end

  @doc """
  Judge ONE flagged pair and record the verdict, plus a `contradicts` edge when the judge
  says the two articles disagree.

  Public with an `opts` seam so a test can supply a judge implementation per call. The
  alternative — `Application.put_env` — mutates VM-global state that every other test in this
  `async: true` suite would see, which is why this repo forbids it outright.
  """
  @spec judge_and_record(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def judge_and_record(tenant_id, pair, opts \\ [])

  def judge_and_record(tenant_id, %{similarity: similarity} = pair, opts) do
    # `validate_pair_order/1` requires source <= target by UUID string; links carry no such
    # guarantee, so canonicalise here rather than letting the changeset reject half of them.
    {src, tgt} =
      if pair.source_article_id <= pair.target_article_id,
        do: {pair.source_article_id, pair.target_article_id},
        else: {pair.target_article_id, pair.source_article_id}

    verdict = judge_pair(tenant_id, src, tgt, similarity, opts)

    # ONE transaction across both writes. The budget's halt kills whatever the reduce
    # abandons (`Task.async_stream` brutal-kills in-flight tasks), and a kill landing between
    # them would leave a `:contradictory` verdict recorded with no `:contradicts` edge —
    # permanently, since `judged_pair_subquery/0` never offers a judged pair again and
    # `Knowledge.find_contradiction_clusters/2` reads only the edge.
    AdminRepo.transaction(fn ->
      case record_verdict(tenant_id, src, tgt, verdict) do
        {:ok, recorded} ->
          maybe_record_contradiction(tenant_id, src, tgt, verdict)
          recorded

        {:error, changeset} ->
          AdminRepo.rollback(changeset)
      end
    end)
  end

  # Load both bodies and hand them to the judge. A pair whose articles cannot both be loaded
  # (deleted between the flag and the judgement) falls back to the similarity verdict rather
  # than going unjudged — leaving it unjudged would put it back at the head of tomorrow's
  # highest-similarity-first queue forever.
  defp judge_pair(tenant_id, src, tgt, similarity, opts) do
    case load_pair(tenant_id, src, tgt) do
      {:ok, left, right} -> ConflictJudge.judge(tenant_id, left, right, similarity, opts)
      :error -> ConflictJudge.Similarity.verdict(similarity)
    end
  end

  defp load_pair(tenant_id, src, tgt) do
    rows =
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.id in ^[src, tgt],
        select: %{id: a.id, title: a.title, body: a.body}
      )
      |> AdminRepo.all()
      |> Map.new(&{&1.id, &1})

    case {Map.get(rows, src), Map.get(rows, tgt)} do
      {%{} = left, %{} = right} -> {:ok, left, right}
      _ -> :error
    end
  end

  defp record_verdict(tenant_id, src, tgt, verdict) do
    now = DateTime.utc_now()

    attrs = %{
      source_article_id: src,
      target_article_id: tgt,
      # `ConflictResolution`'s enum is exactly the judge's three values, so no mapping —
      # and deliberately no fallback clause, because a value outside the enum must reach
      # the changeset as a validation error rather than be silently coerced to
      # `:redundant`, which is the answer this judge exists to stop assuming.
      classification: verdict.classification,
      # ALWAYS `dismiss`, whatever the classification. `supersede`/`merge` defer to the
      # nightly executor and a `:high` supersede authorizes an unattended retirement — a
      # judge that both classifies a pair and certifies its own verdict as executable is
      # exactly what `Knowledge.annotate_conflict/3` caps agent-role callers to prevent.
      # Deciding which of two contradicting articles is right is not an unattended call.
      disposition: :dismiss,
      confidence: verdict.confidence,
      evidence: verdict.rationale,
      annotated_by: "worker:knowledge_lint",
      annotated_at: now,
      # Dismiss has nothing to execute — mark it done so it never enters the executor's
      # pending set (which would leave it in the same limbo this drain exists to end).
      executed_at: now,
      execution_result: %{
        "action" => "noop",
        "reason" => "auto_judged_#{verdict.classification}"
      }
    }

    %ConflictResolution{tenant_id: tenant_id}
    |> ConflictResolution.changeset(attrs)
    |> AdminRepo.insert(
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :source_article_id, :target_article_id]
    )
  end

  # The missing producer. `find_contradiction_clusters/2` reads `:contradicts` links and,
  # until this existed, could only ever return empty because nothing wrote one. Additive and
  # idempotent: an edge appears, nothing is retired or rewritten, and `on_conflict: :nothing`
  # against the pair's unique index makes a re-judgement a no-op.
  defp maybe_record_contradiction(tenant_id, src, tgt, %{classification: :contradictory}) do
    %ArticleLink{tenant_id: tenant_id}
    |> ArticleLink.changeset(%{
      source_article_id: src,
      target_article_id: tgt,
      relationship_type: :contradicts,
      metadata: %{"auto_generated" => true, "judged_by" => "worker:knowledge_lint"}
    })
    |> AdminRepo.insert(
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :source_article_id, :target_article_id, :relationship_type]
    )
  end

  defp maybe_record_contradiction(_tenant_id, _src, _tgt, _verdict), do: :ok

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
  #
  # Resolved through `SystemConfig` FIRST (#617). These three caps are the only lever that
  # slows or stops the nightly drain, and until now the only way to move one was a deploy —
  # an operator watching an auto-unpublish go wrong had no way to halt it in the minutes
  # that matter. `SystemConfig` is DB-backed, survives restart, propagates to the fleet, and
  # is testable by seeding a row.
  #
  # Explicitly NOT `Application.put_env/3` as the live lever: that is per-NODE, does not
  # survive a restart, and fails open and silently — and mutating VM-global state makes the
  # code untestable in an `async: true` suite. `Application.get_env/3` REMAINS the layer
  # beneath, so a compile-time config (including `config/test.exs`) is still honoured when
  # no DB row exists. Resolution order: DB row -> app config -> module default.
  # Public (`@doc false`) so the resolution ORDER can be asserted directly. It is the
  # operator's only mid-incident lever, and a lever nothing tests is a lever nobody can
  # trust to be there when it is needed.
  @doc false
  @spec applies_cap() :: integer()
  def applies_cap do
    tunable(
      "knowledge_consolidation_max_applies",
      :knowledge_consolidation_max_applies,
      Consolidation.default_max_applies()
    )
  end

  @doc false
  @spec unpublishes_cap() :: integer()
  def unpublishes_cap do
    tunable(
      "knowledge_consolidation_max_unpublishes",
      :knowledge_consolidation_max_unpublishes,
      Consolidation.default_max_unpublishes()
    )
  end

  @doc false
  @spec per_class_cap() :: integer()
  def per_class_cap do
    tunable(
      "knowledge_consolidation_max_per_class",
      :knowledge_consolidation_max_per_class,
      Consolidation.default_max_per_class()
    )
  end

  # `get_int/2`'s own contract is that a missing row, a non-integer row, or ANY error
  # returns the default — so the app-config value is what a fresh install and an unprimed
  # cache both see, exactly as before this indirection existed.
  defp tunable(db_key, app_key, default) do
    SystemConfig.get_int(db_key, coerce_int(Application.get_env(:loopctl, app_key), default))
  end

  # The app-config layer is type-checked rather than trusted: `SystemConfig.get_int/2`
  # requires an INTEGER default and would raise a FunctionClauseError on a `nil` or a
  # `"25"` from a hand-edited config. Inside the nightly's rescue that surfaces as a
  # generic `apply_failed`, which reads as an outage rather than as the config typo it is.
  #
  # Takes the VALUE, not the key, so it is testable without mutating VM-global application
  # state — `Application.put_env/3` in a test is banned here for exactly the reason this
  # whole change routes the live lever through the DB instead.
  @doc false
  @spec coerce_int(term(), integer()) :: integer()
  def coerce_int(value, _default) when is_integer(value), do: value
  def coerce_int(nil, default), do: default

  def coerce_int(other, default) do
    Logger.warning(
      "KnowledgeLintWorker: ignoring non-integer consolidation cap #{inspect(other)}; " <>
        "using #{default}."
    )

    default
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
    do: %{applied: 0, skipped: 0, failed: 0, uncorroborated: 0, gate: gate, error: error}

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
    {:ok, consolidation} = Consolidation.run(tenant_id, max_per_class: per_class_cap())
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
      # Groups the #616 corroboration gate WITHHELD (title collision, bodies do not agree,
      # or the members carry no vectors yet). Without it, a tenant whose every confirmed
      # group is withheld records applied=0 skipped=0 failed=0 gate=open — exactly what a
      # clean corpus records — and only per-group warnings say otherwise.
      "duplicate_groups_uncorroborated" => applied.uncorroborated,
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
        "conflicts_judged_redundant" => judged.judged,
        # And the three numbers that say WHY judged is what it is. Without them a night one
        # of the two bounds truncated and a night with nothing left to judge are
        # indistinguishable in the audit trail, so "the drain is holding the line" above
        # cannot be read at all — the reading that was unavailable for the six nights of
        # #761. Both bounds report: the clock, and the count cap that truncates silently
        # while the clock never fires.
        "conflicts_judge_candidates" => judged.candidates,
        "conflicts_judge_budget_exhausted" => judged.budget_exhausted,
        "conflicts_judge_count_capped" => judged.count_capped,
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
