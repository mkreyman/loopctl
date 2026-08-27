defmodule Loopctl.Knowledge.DraftConsumer do
  @moduledoc """
  The automatic consumer for articles left in `status: :draft`.

  ## The leak this closes

  A draft is invisible: no read path serves one, so an agent cannot distinguish a held
  draft from a capture that never happened. Measured in production 2026-08-27, **113
  articles sat in `:draft`, growing ~11 a night** (10, 11, 5, 17, 20, 10, 13, 9, 10, 7
  over ten days) with **zero automatic consumers**. A holding area with no drain is not a
  safety mechanism, it is a landfill — the same argument
  `Loopctl.Workers.DraftDuplicateSweepWorker` makes about its own half of the queue.

  ## Why the default is PUBLISH, and why the gate's job is annotation rather than gatekeeping

  Owner decision, 2026-08-27: **there is no human approver and there never will be.** That
  settles the asymmetry the whole design turns on.

    * holding is **TOTAL LOSS** — an agent never sees a draft, so a held article is
      indistinguishable from one that was never captured at all;
    * publishing is **RECOVERABLE** — an agent can read a caveat, the redundancy is
      recorded as a link, and `Knowledge.unpublish_article/3` is the exact inverse of the
      `publish_article/3` this takes.

  So reversibility replaces approval, and **there are no terminal acts here**.

  ## Why it ASSESSES rather than reading a stamp

  loopctl#765 specifies disposing of drafts by their `metadata.proposal_novelty` stamp.
  That mechanism does not exist for these rows: all 113 carry EMPTY metadata, because they
  were created directly as drafts by an orchestrator key (`article.created`) and never went
  through `Knowledge.propose_article/3`'s novelty branch. Only ONE of the 113 carries an
  embedding, either — publishing enqueues one, being created as a draft does not.

  So the per-item cost is a real embedding call, and the assessment is made here through the
  EXISTING seam, `Loopctl.Knowledge.ProposalGate.assess/3` (the
  `ProposalAssessorBehaviour`), rather than in a second novelty implementation that would
  drift from the one the write path uses.

  A draft is therefore embedded TWICE across the night: once synchronously here to assess
  it, and once asynchronously by the embedding worker that `publish_article/3` enqueues,
  which is what writes the STORED vector and chains on to `ArticleLinkingWorker`. The gate
  returns a verdict and neighbours, never the vector, so the second call is the price of
  reusing it. It is paid on a bounded handful of drafts a night (`default_max_publishes/0`),
  inside a job whose clock this step is carved out of.

  ## What happens to each draft

    * `:novel` → **published**. The common case and the default.
    * `:low_novelty` / `:duplicate` → **published AND linked** to its nearest published
      neighbour with a `relates_to` edge carrying the cosine `similarity_score` and
      `auto_generated: true` — the SAME edge `ArticleLinkingWorker` derives from the stored
      vector once the publish's embedding lands, written tonight instead of whenever that
      queue drains, under that worker's own project scope and a STRICTER visibility one
      (`linkable?/3`), so this step adds no edge class the graph did not already have.
      What the edge buys is a RECORD, not a retraction, and the honest reading of where it
      ends is: `KnowledgeLintWorker.promote_conflicts/1` flags a pair at or above the
      conflict threshold `:potential_conflict`, which SUPPRESSES both its articles from
      curated answers until the pair is judged; the judge reaches it in similarity order,
      which against a standing backlog is nights away rather than tonight; and its verdict
      is `:redundant` / `dismiss`, which is TERMINAL and retires neither article.
      Consolidation's `:duplicate_capture` retraction reaches colliding TITLES and
      idempotency keys, not semantic near-duplicates, so it does not retract this pair
      either. Both articles stay published with the redundancy on the record for a human or
      an orchestrator. Under the owner decision that is the accepted cost of the default —
      a recorded duplicate is recoverable, a held article is not — and it is the cost of
      PUBLISHING one, not of the edge: the auto-linker writes the same pair either way.
    * assessment genuinely **unavailable** → the draft is **left alone and counted**. TWO
      shapes reach this, and only the first announces itself. `:unknown` (provider down, no
      BYO key, heavy read shed) is `ProposalGate` falling open by contract, so it means
      "not assessed", never "not a duplicate". The second shape is `comparison:
      :unavailable` on an ORDINARY-LOOKING verdict: a search that cannot run returns an
      empty neighbour list, an empty list scores as maximally novel, so a total search
      failure and a genuinely novel draft produce the identical `:novel`. That is not
      theoretical — a tenant whose configured embedding model returns a length this
      instance cannot index gets an empty result for every query, permanently, which would
      publish its entire draft pile having compared nothing. Publishing on either would
      publish unassessed drafts through an outage, and dropping them would be the loss this
      worker exists to stop.

  ## What it must NOT do: archive

  loopctl#765 item 4 proposes archiving the twin of a near-duplicate on the premise that
  archive is a soft delete and therefore reversible. **The premise is false.**
  `Loopctl.Knowledge.Article`'s `@valid_transitions` carries no `{:archived, _}` entry and
  there is no unarchive function, so `:archived` is TERMINAL: only a `user`-role PATCH
  carrying an explicit status brings a row back. Non-destructive and reversible are
  different properties (#605/#606), and an unattended writer may only have the second. It is
  why the consolidation pass retracts with `unpublish` and never `archive` (#608), and it is
  why nothing here merges bodies or discards one.

  ## Not every draft is an abandoned capture

  A `:draft` row is not one thing, so `draft_scope/1` excludes three classes that were put
  there DELIBERATELY and are not this step's to undo.

  **A RETRACTION.** Consolidation's retraction of a confirmed duplicate produces a draft —
  and so does `Knowledge.unpublish_article/3` (and `bulk_unpublish/3`), the `role: :user`
  lever an operator reaches for to pull a wrong or sensitive article back out of the corpus.
  Republishing either is wrong: against consolidation it is a nightly fight — publish,
  retract, publish — burning an embedding call each way forever, and against a human it
  silently reverts a human-gated act inside 24 hours. So a draft carrying
  `articles.consolidation_retracted_at` is never a candidate, and neither is one the
  `audit_log` records as `article.unpublished` BY ANY ACTOR.

  Neither of those two records is durable on its own. The column exists only from migration
  `20260818055453` onward and only consolidation stamps it; the `audit_log` is
  range-partitioned and its partitions are DROPped past `:audit_retention_days`, so a human
  retraction older than retention would be republished — and a `user+` PATCH to
  `status: :draft` is a retraction that writes `article.updated` and no `article.unpublished`
  at all. A THIRD record closes both: a draft carrying an EMBEDDING was PUBLISHED once,
  because `maybe_enqueue_embedding/3` enqueues only at `status: :published` and ingestion only
  under `publish: true`, and that row outlives every audit partition. It also splits the queue
  cleanly: `DraftDuplicateSweepWorker` sweeps the EMBEDDED drafts (retractions), this step
  drains the unembedded ones (captures that were never published) — 112 of the 113 measured.

  **A MERGE.** `Knowledge.execute_conflict_resolutions/2` lands its LLM-synthesised merge as
  a draft, and CLAUDE.md's KB-content carve-out rests on that draft never being
  auto-published: it is exactly what separates an agent-role key RECORDING a merge verdict
  from the same key authorising unattended synthesised text into the corpus. So a merge draft
  is excluded by TWO records: `metadata.merged_from`, and the executor's own
  `conflict_resolutions.execution_result->>'draft_id'`. The second is what makes it hold —
  `metadata` is CAST and whole-map-replaced by an agent-role `PATCH /api/v1/knowledge/:id`
  (the `previous_title` and `stories.lifecycle_entered_at` lesson), so a marker living only
  there is one ordinary request away from auto-publishing the synthesised text; the
  executor's row is not caster-writable. That does leave a merge draft with no AUTOMATIC
  exit, against #765's rule that no state has a human as its only exit. The carve-out is the
  narrower rule and governs: the exit is an orchestrator publishing or deleting the draft,
  and it is never this step.

  **A HOLD THAT IS STILL FRESH.** `POST /api/v1/knowledge` with `draft: true`, and ingestion
  with `publish: false`, are advertised opt-ins into staging; publishing one the same night
  makes the opt-in unobservable. There is no approver to wait for, so the reconciliation is a
  FLOOR rather than a veto, and there are TWO of them.

  A draft carrying `articles.staged_draft_at` was staged because a caller ASKED for it, and
  is held for a week from that stamp. Everything else — a capture nobody came back for, a
  proposal the novelty gate drafted on behalf of a caller who asked to PUBLISH — is held for
  48h from creation, which leaves whoever staged it two nightly runs to publish or delete it
  and still drains everything abandoned past that. Either floor costs the drain nothing:
  inflow ages into the pool at the rate it arrives.

  The marker is a COLUMN and not a `metadata` key, for the `stories.lifecycle_entered_at`
  reason this scope already relies on twice — `metadata` is cast and whole-map-replaced by an
  agent-role `PATCH`, so a marker living there would let one ordinary request silently
  shorten the hold its caller asked for. And it is a longer floor rather than the VETO it may
  look like it should be: a veto is a state whose only exit is a human, and holding is total
  loss here, so the marker buys the stager a longer window and never a permanent one.

  ## What bounds one night

  A **WALL CLOCK** (`:budget_ms`), because the per-item cost is an outbound provider call
  and a count bounds attempts rather than cost — #761, in this same job, for six consecutive
  nights. `:max_publishes` bounds the candidate QUERY only, and `0` PAUSES the drain
  (`gate: :drain_disabled`) without a deploy, through the
  `knowledge_draft_consumer_max_publishes` `SystemConfig` row.

  The cap sits deliberately ABOVE the producer rate, and the number that matters is the NET
  drain: ~11 drafts a night arrive against a cap of 30, so the backlog falls by ~19 a night
  and the 113 standing drafts measured on 2026-08-27 clear in about SIX nights, not the four
  that 113/30 gives by dropping inflow out of the denominator. A cap at or below the producer
  rate is not a drain at all.

  The return carries `offered` and `budget_exhausted` so a truncated night and a night with
  nothing to do are never the same numbers; the worker puts both in its log line and in the
  `knowledge.lint_completed` audit event. `published + unassessed + skipped + failed` is
  what was PROCESSED, so it falls below `offered` exactly when the clock fired.

  ## Overlap with `DraftDuplicateSweepWorker`

  That worker ARCHIVES a draft whose nearest published neighbour clears 0.95. This one
  PUBLISHES the same draft and links it. They disagree, and running nightly against its
  weekly schedule means this one reaches the capture-path backlog first. That is the owner
  decision applied — the sweep predates it — not an oversight; it is called out here because
  a reader arriving from that moduledoc will expect the two to agree.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings.TextBudget
  alias Loopctl.ExitTag
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.ProposalGate
  alias Loopctl.Llm

  @actor_label "worker:draft_consumer"

  # How many drafts one nightly run may OFFER. Bounds the candidate query, never the step:
  # each item costs an outbound embedding call, so the bound that holds is the wall clock
  # below (#761). Chosen ABOVE the measured producer rate (~11 a night) so the backlog
  # actually falls: at 30 the NET drain is ~19 a night, so the 113 standing drafts clear in
  # about six nights. `0` is honoured as an explicit operator PAUSE.
  @default_max_publishes 30
  @hard_max_publishes 500

  # How much of the cap is spent OLDEST-first. Not the whole of it: there is no per-draft
  # attempt counter here, so a purely oldest-first window stalls at zero the moment `cap`
  # permanently unconsumable drafts reach the head — a project the embedding path refuses, a
  # body no `ShrinkLadder` rung fits, a changeset the publish rejects. Those are re-offered
  # at equal priority every night forever, nothing behind them is ever seen, and the audit
  # event reads exactly like a provider having a bad night. A fifth of the cap therefore goes
  # to the NEWEST drafts, which keeps the drain strictly positive whatever the head does
  # without giving up the backlog-first bias the rest of the window exists for.
  @backlog_share 0.8

  # A draft younger than this is HELD. `draft: true` and ingestion's `publish: false` are
  # advertised opt-ins into staging, and a drain that runs tonight makes them unobservable.
  # See the moduledoc: a floor, not a veto — there is no approver to wait for.
  @min_draft_age_hours 48

  # The floor for a draft that carries `articles.staged_draft_at` — a stage the caller
  # ASKED for, rather than one inferred from the row being young. A WEEK, so a deliberate
  # stage survives a full cycle of whatever attention it was staged for, where an
  # abandoned capture waits two nightly runs.
  #
  # It is a longer FLOOR and deliberately not a veto, which is the whole reason the marker
  # is safe to add: holding is TOTAL LOSS (no read path serves a draft, and there is no
  # human approver — owner decision 2026-08-27), so a marker that exempted a draft from
  # the drain outright would be a state whose only exit is a human, which is what #765
  # forbids. The marker buys the stager a longer window, never a permanent one.
  @staged_draft_age_hours 24 * 7

  # Fallback wall clock. `Loopctl.Workers.KnowledgeLintWorker` always passes `:budget_ms` —
  # the time ITS job has left (`draft_budget_remaining/1`) — so this applies only to a direct
  # call, and it is deliberately not larger than the reserve that worker carves out for this
  # step. `test/loopctl/workers/knowledge_lint_worker_test.exs` binds the two so they cannot
  # drift into a budget bigger than the job containing it.
  @default_budget_ms :timer.minutes(2)

  @type tally :: %{
          published: non_neg_integer(),
          linked: non_neg_integer(),
          link_failed: non_neg_integer(),
          unassessed: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          offered: non_neg_integer(),
          budget_exhausted: boolean(),
          gate: :open | :drain_disabled | :no_embedding_key
        }

  @doc "Default cap on drafts one run may offer to the consumer."
  @spec default_max_publishes() :: pos_integer()
  def default_max_publishes, do: @default_max_publishes

  @doc "Fallback wall-clock budget (ms) when no `:budget_ms` is given."
  @spec default_budget_ms() :: pos_integer()
  def default_budget_ms, do: @default_budget_ms

  @doc "The actor label every publish and every link this step writes is attributed to."
  @spec actor_label() :: String.t()
  def actor_label, do: @actor_label

  @doc """
  Assess every eligible draft and publish it, linking a near-duplicate to its neighbour.

  ## Options

    * `:max_publishes` — candidate-query cap; `0` pauses the drain. Defaults to
      `default_max_publishes/0`, clamped to `#{@hard_max_publishes}`.
    * `:budget_ms` — wall clock for the whole drain. Defaults to `default_budget_ms/0`.
    * `:proposal_assessor` — the `ProposalAssessorBehaviour` implementation, PER CALL. The
      config layer underneath is untouched and still resolves to `ProposalGate` in
      production and to the Mox mock in tests; the opt exists because a test must drive one
      call's assessor without `Application.put_env`, which mutates VM-global state every
      other test in this `async: true` suite would see. Mirrors
      `Loopctl.Knowledge.Consolidation.extractor/1` and `ConflictJudge.impl/1` exactly.
  """
  @spec consume(Ecto.UUID.t(), keyword()) :: tally()
  def consume(tenant_id, opts \\ []) do
    cap = clamp_cap(Keyword.get(opts, :max_publishes, @default_max_publishes))

    cond do
      cap == 0 ->
        Logger.info(
          "DraftConsumer: tenant=#{tenant_id} drain is PAUSED by its cap (0); drafts stay held."
        )

        tally(:drain_disabled)

      # BEFORE the candidate query, not after the drain. Embedding is mandatory-BYO, so on a
      # keyless tenant every `ProposalGate` assessment falls open on `{:error, :no_api_key}` —
      # and each one appends an `llm.blocked_no_api_key` row to the hash-chained audit_log
      # (`Llm.record_blocked/2`). That cause never self-heals, so offering anyway writes `cap`
      # audit rows a night, forever, for an outcome known in advance to be zero publishes.
      # Stopping here costs the operator nothing they were going to get, and says so once.
      #
      # Scoped to `ProposalGate` because it is ITS fall-open being pre-empted: another
      # `ProposalAssessorBehaviour` may not need a tenant embedding key at all, and a
      # pre-check that assumed one would silently stop a drain that would have worked.
      assessor(opts) == ProposalGate and not embedding_key?(tenant_id) ->
        # Guarded on there being something HELD, the condition the removed
        # `log_provider_unconfigured/2` carried: a keyless tenant with an empty queue has
        # nothing stuck, and a nightly warning asserting otherwise is how a real one gets muted.
        if held_drafts?(tenant_id) do
          Logger.warning(
            "DraftConsumer: tenant=#{tenant_id} has no embedding key (mandatory BYO), so no " <>
              "draft can be assessed at all; the drain is stopped and every draft stays held. " <>
              "This is a configuration state, not a provider that failed."
          )
        end

        tally(:no_embedding_key)

      true ->
        drain(tenant_id, candidates(tenant_id, cap), opts)
    end
  end

  @doc """
  The novelty assessor this step calls.

  See the `:proposal_assessor` option on `consume/2` for why the seam is per-call.
  """
  @spec assessor(keyword()) :: module()
  def assessor(opts \\ []) do
    Keyword.get(
      opts,
      :proposal_assessor,
      Application.get_env(:loopctl, :proposal_assessor, ProposalGate)
    )
  end

  # --- Private ---

  # A NEGATIVE cap is a pause, not a licence: `0` and below both stop the drain rather than
  # wrapping round to "unbounded". A non-integer falls back to the default rather than
  # raising inside the nightly's rescue, where it would surface as an outage instead of the
  # config typo it is (the `coerce_int/2` lesson).
  defp clamp_cap(value) when is_integer(value) and value <= 0, do: 0
  defp clamp_cap(value) when is_integer(value), do: min(value, @hard_max_publishes)

  defp clamp_cap(other) do
    Logger.warning(
      "DraftConsumer: ignoring non-integer cap #{inspect(other)}; using #{@default_max_publishes}."
    )

    @default_max_publishes
  end

  # ONE constructor for every tally, so no fail-soft path can ship a map missing a key the
  # worker's summary line interpolates — the `empty_tally/2` lesson, which once cost a
  # fail-soft rescue a KeyError one line after it had swallowed the original error.
  defp tally(gate) do
    %{
      published: 0,
      linked: 0,
      link_failed: 0,
      unassessed: 0,
      skipped: 0,
      failed: 0,
      offered: 0,
      budget_exhausted: false,
      gate: gate
    }
  end

  # OLDEST FIRST for `@backlog_share` of the cap: a capped run must drain the standing backlog
  # rather than skim tonight's arrivals off the top, which at a cap above the producer rate
  # would leave the 113 oldest drafts held forever while the queue looked healthy. The
  # remainder is taken NEWEST first so a permanently unconsumable head cannot take the drain
  # to zero — see `@backlog_share`.
  #
  # INTERLEAVED, never appended. The cap bounds the QUERY; the bound that actually cuts the
  # night is the wall clock in `drain/3`, which truncates the TAIL. Appended, the reserve was
  # the first thing a slow unconsumable head discarded — a head that fails in ~5s an item
  # spends the whole 2-minute budget inside the backlog slice — so the one slice that exists
  # to keep the drain positive was exactly the one that never ran.
  defp candidates(tenant_id, cap) do
    oldest = candidate_ids(tenant_id, max(trunc(cap * @backlog_share), 1), :asc)
    newest = candidate_ids(tenant_id, cap - length(oldest), :desc)
    Enum.uniq(interleave(newest, oldest))
  end

  defp interleave([], rest), do: rest
  defp interleave(rest, []), do: rest
  defp interleave([a | as], [b | bs]), do: [a, b | interleave(as, bs)]

  defp held_drafts?(tenant_id), do: tenant_id |> draft_scope() |> AdminRepo.exists?()

  defp candidate_ids(_tenant_id, limit, _direction) when limit <= 0, do: []

  defp candidate_ids(tenant_id, limit, direction) do
    tenant_id
    |> draft_scope()
    |> order_by([draft: a], [{^direction, a.inserted_at}])
    |> limit(^limit)
    |> select([draft: a], a.id)
    |> AdminRepo.all()
  end

  # The ONE definition of "a draft this step may touch", composed into both the candidate
  # query and the per-item live re-fetch. Two hand-copied predicate lists is how the offer
  # and the write come to disagree about the same row.
  defp draft_scope(tenant_id) do
    from(a in Article,
      as: :draft,
      where: a.tenant_id == ^tenant_id,
      where: a.status == :draft,
      # TENANT scope only. A `:system` canonical is shared-corpus content that no per-tenant
      # nightly pass owns, and publishing one on a tenant's behalf is not this step's call.
      where: a.scope == :tenant,
      # SHARED visibility only, the same filter `Consolidation.shared_only/1` applies for the
      # same reason: this step ships the article's own bytes to an embedding provider, and an
      # agent's `private`/`owner` memory must not leave on a pass it never asked for. Such a
      # draft stays held, which for a row only its owner could ever read is not the loss the
      # moduledoc is about.
      where:
        fragment("COALESCE(?->>'visibility', 'shared') NOT IN ('private','owner')", a.metadata),
      # A MERGE is staged on purpose. `execute_conflict_resolutions/2` lands LLM-synthesised
      # text as a draft, and the KB-content carve-out that lets an agent-role key record a
      # merge verdict at all rests on that draft never being auto-published. TWO records,
      # because `metadata` is cast and whole-map-replaced by an agent-role PATCH: the marker
      # the executor wrote there, and the executor's own `conflict_resolutions` row, which no
      # caller can cast.
      where: fragment("? -> 'merged_from' IS NULL", a.metadata),
      where:
        not exists(
          from(cr in "conflict_resolutions",
            where: cr.tenant_id == parent_as(:draft).tenant_id,
            where:
              fragment("? ->> 'draft_id' = ?::text", cr.execution_result, parent_as(:draft).id),
            select: 1
          )
        ),
      # A FRESH HOLD is staged on purpose too — `draft: true` and ingestion's `publish: false`
      # are advertised opt-ins, and a drain that runs tonight makes them unobservable. A floor,
      # not a veto: two nightly runs to publish or delete it, then it drains like the rest.
      #
      # TWO floors, because the opt-in is now RECORDED rather than guessed at. A draft
      # carrying `staged_draft_at` was staged because a caller asked for it, and gets the
      # longer `@staged_draft_age_hours` window measured from the stamp; everything else —
      # an abandoned capture, a gate-drafted proposal whose caller asked to publish — keeps
      # the 48h floor measured from creation. The marker is a COLUMN precisely so an
      # ordinary `PATCH` (which casts and whole-map-replaces `metadata`) cannot silently
      # shorten a hold the caller asked for. Neither branch is a veto: see
      # `@staged_draft_age_hours`.
      where:
        (is_nil(a.staged_draft_at) and a.inserted_at <= ago(@min_draft_age_hours, "hour")) or
          (not is_nil(a.staged_draft_at) and
             a.staged_draft_at <= ago(@staged_draft_age_hours, "hour")),
      # The RETRACTION guard, in its THREE independent records. See the moduledoc. The audit
      # clause is deliberately NOT narrowed to `worker:consolidation`:
      # `Knowledge.unpublish_article/3` and `bulk_unpublish/3` are the `role: :user`
      # retraction lever, and republishing what a human just pulled reverts a human-gated act
      # unattended. `tenant_id` is constrained inside the subquery so the correlated NOT
      # EXISTS can use `audit_log_tenant_entity_idx`, whose leading column it is.
      #
      # `Loopctl.Workers.DraftDuplicateSweepWorker.load_embedded_drafts/2` spells the SAME
      # rule for its own candidates. It was narrowed to `worker:consolidation` while this
      # one was not, which put the narrower guard in front of the TERMINAL action of the
      # pair; both are unnarrowed now. Change them together.
      #
      # Neither the column nor the audit row is durable ALONE — the column is stamped only by
      # consolidation and only since 20260818055453, and `AuditPartitionWorker` DROPs the
      # audit partition past `:audit_retention_days`, which also leaves a `user+` PATCH to
      # `status: :draft` (an `article.updated`, never an `article.unpublished`) with no record
      # here at all. An EMBEDDING is the third and the durable one: it exists only because the
      # row was PUBLISHED once (`maybe_enqueue_embedding/3` enqueues at `:published` only,
      # ingestion only under `publish: true`), and it survives every partition drop. Existence
      # at ANY dimension, and the legacy column too — currency is not the question.
      #
      # THE RESIDUAL, stated deliberately rather than left to be rediscovered as a bug.
      # One retraction escapes all three records: a published article that never got an
      # embedding (its tenant had no BYO key at the time, or the job failed permanently),
      # retracted by a human, aged past `:audit_retention_days`, and predating
      # 20260818055453. It has no evidence of ever having been published, so this scope
      # offers it and it is republished ONCE.
      #
      # Once, and not repeatedly: `publish_article/3` goes through `transition_article/5`,
      # whose `maybe_enqueue_embedding/3` fires at `:published`, so the republish writes
      # the durable record that was missing and any later retraction is spared. And the
      # keyless case cannot fire at all while it is keyless — `consume/2` stops at the
      # `:no_embedding_key` gate before this query runs — so it needs a tenant that
      # acquired a key after the fact.
      #
      # Failing CLOSED on it is not available. The only rule that would catch it is "hold
      # anything older than the audit horizon with no positive evidence", which is exactly
      # what `DraftDuplicateSweepWorker` does — it can, because its action is terminal and
      # holding costs it nothing. Here holding IS the loss: every draft in the standing
      # backlog crosses that horizon eventually, carrying no `article.unpublished` row and
      # no embedding, so that rule would strand the whole capture-path pile permanently,
      # which is the total loss this step exists to prevent. A bounded single republish of
      # a rare row is the smaller cost, and it is recoverable — `unpublish_article/3` puts
      # it back, and this time the record survives.
      where: is_nil(a.consolidation_retracted_at),
      where: is_nil(a.embedding),
      where:
        not exists(
          from(e in ArticleEmbedding,
            where: e.tenant_id == parent_as(:draft).tenant_id,
            where: e.article_id == parent_as(:draft).id,
            select: 1
          )
        ),
      where:
        not exists(
          from(al in "audit_log",
            where: al.tenant_id == parent_as(:draft).tenant_id,
            where: al.entity_id == parent_as(:draft).id,
            where: al.entity_type == "article",
            where: al.action == "article.unpublished",
            select: 1
          )
        )
    )
  end

  # SEQUENTIAL, deliberately, where the conflict judge is concurrent. `Task.async_stream/3`
  # LINKS its tasks, so every failure mode of the work has to be made total INSIDE the task
  # or one raise takes the night's audit event with it — the defect the #766 review caught.
  # A capped handful of items at ~2 s each fits the 2-minute reserve with room to spare, so
  # concurrency buys nothing here and the hazard is simply not taken on.
  defp drain(tenant_id, ids, opts) do
    # Deadline taken before the first item and checked BEFORE each one, never after. A
    # post-item check is unconditionally committed to item #1, so a budget of exactly 0 — the
    # state a night whose prelude overran arrives in, and `draft_budget_remaining/1` floors at
    # 0 — would still buy a full provider call and a publish out of a reserve already spent.
    # Checking at the head also keeps the flag honest for free: a night that processed its
    # LAST candidate and only then crossed the deadline never reaches another check, so a
    # DRAINED night is never reported as truncated.
    budget_ms = Keyword.get(opts, :budget_ms, @default_budget_ms)
    deadline = System.monotonic_time(:millisecond) + budget_ms
    offered = length(ids)

    result =
      Enum.reduce_while(ids, %{tally(:open) | offered: offered}, fn id, acc ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:halt, %{acc | budget_exhausted: true}}
        else
          {:cont, tally_draft(tenant_id, id, acc, opts)}
        end
      end)

    log_truncation(tenant_id, budget_ms, result)
    result
  end

  # Per-item containment, exactly like `Consolidation.tally_retitle/4`: this reduce is not
  # transactional, so a raise escaping it would discard the tally of the drafts ALREADY
  # published and report zero writes that really happened.
  defp tally_draft(tenant_id, id, acc, opts) do
    case consume_draft(tenant_id, id, opts) do
      :published ->
        %{acc | published: acc.published + 1}

      :published_linked ->
        %{acc | published: acc.published + 1, linked: acc.linked + 1}

      :published_link_failed ->
        %{acc | published: acc.published + 1, link_failed: acc.link_failed + 1}

      :unassessed ->
        %{acc | unassessed: acc.unassessed + 1}

      :skip ->
        %{acc | skipped: acc.skipped + 1}

      {:failed, tag} ->
        draft_failed(tenant_id, id, tag, acc)
    end
  rescue
    e -> draft_failed(tenant_id, id, ExitTag.tag(e), acc)
  catch
    :exit, reason -> draft_failed(tenant_id, id, "exit:" <> ExitTag.tag(reason), acc)
  end

  defp draft_failed(tenant_id, id, tag, acc) do
    Logger.error(
      "DraftConsumer: tenant=#{tenant_id} draft #{id} could not be consumed (#{tag}); " <>
        "it stays held and is offered again next run."
    )

    %{acc | failed: acc.failed + 1}
  end

  defp consume_draft(tenant_id, id, opts) do
    case live_draft(tenant_id, id) do
      {:ok, draft} ->
        assess_and_publish(tenant_id, draft, opts)

      :gone ->
        Logger.info(
          "DraftConsumer: tenant=#{tenant_id} draft #{id} is no longer an eligible draft; skipped."
        )

        :skip
    end
  end

  # Re-derivation, not trust — the twin of `Consolidation.live_placeholder/2`. Between the
  # candidate query and the provider call a human may have published, archived or retitled
  # the draft, or consolidation may have stamped it; spending an embedding call and then a
  # publish on a row that has moved is the failure this re-read costs one indexed lookup to
  # avoid. The body comes back PRE-TRUNCATED from SQL at the same cap the gate's own
  # `TextBudget.initial/1` would apply, so this can never pull 30 x 100 KB bodies into memory
  # to hand the gate bytes it would immediately discard.
  defp live_draft(tenant_id, id) do
    tenant_id
    |> draft_scope()
    |> where([draft: a], a.id == ^id)
    |> select([draft: a], %{
      id: a.id,
      title: a.title,
      project_id: a.project_id,
      body: fragment("substring(? from 1 for ?)", a.body, ^TextBudget.initial_chars())
    })
    |> AdminRepo.one()
    |> case do
      nil -> :gone
      draft -> {:ok, draft}
    end
  end

  defp assess_and_publish(tenant_id, draft, opts) do
    attrs = %{"title" => draft.title, "body" => draft.body, "project_id" => draft.project_id}

    case assessor(opts).assess(tenant_id, attrs, []) do
      %{verdict: :unknown} ->
        unassessed(tenant_id, draft, "gate_unavailable")

      # BEFORE any usable verdict is read. An assessment whose comparison did not happen
      # carries a verdict derived from an EMPTY neighbour list, and that verdict is
      # `:novel` — character for character the one a genuinely novel draft gets. Publishing
      # on it publishes unassessed, which is precisely what the `:unknown` clause above
      # refuses; the two differ only in whether the gate could name its own failure as a
      # fall-open. `ProposalGate`'s moduledoc says why the verdict is deliberately left
      # alone there instead of being moved to `:unknown` — doing that would change the
      # create path, whose contract is that a write is never blocked.
      %{comparison: :unavailable} ->
        unassessed(tenant_id, draft, "comparison_unavailable")

      %{verdict: :novel} ->
        publish(tenant_id, draft, :novel, nil)

      %{verdict: verdict} = assessment when verdict in [:low_novelty, :duplicate] ->
        publish(tenant_id, draft, verdict, neighbour(tenant_id, assessment, draft))

      other ->
        # An implementation that answers outside the behaviour's four verdicts. Treated as
        # NOT ASSESSED rather than defaulted to novel: publishing on a verdict nobody
        # produced is exactly the unassessed publish the `:unknown` branch refuses.
        unassessed(tenant_id, draft, "unrecognised_verdict:#{verdict_tag(other)}")
    end
  end

  defp unassessed(tenant_id, draft, reason) do
    Logger.info(
      "DraftConsumer: tenant=#{tenant_id} draft #{draft.id} was not assessed (#{reason}); " <>
        "it stays held and is offered again next run."
    )

    :unassessed
  end

  # NAMES the off-contract answer. `ExitTag.tag/1` has no map clause, so every one of these
  # flattened to the literal "unknown" — the same tag every unexplained failure gets, in the
  # one branch that exists to make an off-contract implementation diagnosable. The verdict and
  # the key set only, never the value: an assessment carries neighbour titles.
  defp verdict_tag(%{verdict: verdict}), do: inspect(verdict)
  defp verdict_tag(other) when is_map(other), do: "no_verdict_key:" <> inspect(Map.keys(other))
  defp verdict_tag(_other), do: "not_a_map"

  # The nearest LINKABLE neighbour the gate scored, or `nil`. The whole list is walked, not
  # just its head: `ProposalGate.assess/3` passes no project or visibility filter, so in a
  # multi-project tenant the top neighbour being out of scope is ordinary, and judging the
  # head alone threw away an in-scope pair at rank 2 that the auto-linker links anyway.
  # `nil` means no candidate survived (or a malformed assessment carried none); the draft is
  # still published — that is the default, and withholding it would be the total loss — it
  # simply carries no annotation, and `link/4` counts that separately.
  defp neighbour(tenant_id, %{neighbors: neighbors}, %{id: draft_id, project_id: project_id})
       when is_list(neighbors) do
    Enum.find_value(neighbors, fn
      %{id: id, similarity_score: score} when is_binary(id) and id != draft_id ->
        if linkable?(tenant_id, id, project_id), do: %{id: id, similarity_score: score}

      _other ->
        nil
    end)
  end

  defp neighbour(_tenant_id, _assessment, _draft), do: nil

  # The scope this step's edge is held to. The PROJECT half mirrors the auto-linker exactly —
  # `ArticleLinkingWorker` passes `project_or_global: article.project_id` and never links out
  # of a project, while `ProposalGate.assess/3` carries no such filter (it scopes the vector
  # read for egress only), so without it the annotation would be an edge class the graph has
  # never held. A `nil` project is GLOBAL on both sides, exactly as
  # `maybe_filter_by_project_or_global/2` reads it. The VISIBILITY half is deliberately
  # STRICTER than the auto-linker, which passes no `:visibility_agent_id` at all
  # (`VectorSearch.maybe_filter_by_visibility(query, nil)` is a no-op): it delays nothing this
  # step owes, since that worker may still derive the same edge from the stored vector, and it
  # keeps an unattended writer out of another agent's `private`/`owner` memory tonight.
  defp linkable?(tenant_id, neighbour_id, project_id) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: a.id == ^neighbour_id,
      where: a.status == :published,
      where:
        fragment("COALESCE(?->>'visibility', 'shared') NOT IN ('private','owner')", a.metadata),
      select: %{project_id: a.project_id}
    )
    |> AdminRepo.one()
    |> case do
      nil ->
        false

      %{project_id: neighbour_project} ->
        is_nil(project_id) or is_nil(neighbour_project) or neighbour_project == project_id
    end
  end

  defp publish(tenant_id, draft, verdict, neighbour) do
    case Knowledge.publish_article(tenant_id, draft.id,
           actor_type: "system",
           actor_label: @actor_label
         ) do
      {:ok, _article} ->
        link(tenant_id, draft, verdict, neighbour)

      # The row moved between the live re-fetch and the write, or the transition is no longer
      # legal (someone else published or archived it). A SKIP, never a failure: nothing is
      # wrong and nothing is owed.
      {:error, :not_found} ->
        :skip

      {:error, :unprocessable_entity, _message} ->
        :skip

      other ->
        {:failed, publish_error_tag(other)}
    end
  end

  # ONE clause on purpose. The case above has already taken every non-changeset error
  # `Knowledge.publish_article/3` declares, so the residual is exactly a rejected changeset —
  # a catch-all here is unreachable and dialyzer says so. A shape outside that spec raises
  # into `tally_draft/4`'s per-item rescue, which counts it and names its class, rather than
  # being flattened to a uselessly generic tag. Keys only, never the changeset: an error
  # message can carry backend host, database and role.
  defp publish_error_tag({:error, %Ecto.Changeset{errors: errors}}),
    do: inspect(Keyword.keys(errors))

  defp link(_tenant_id, _draft, :novel, _neighbour), do: :published

  # `:published_link_failed`, never `:published`: a near-duplicate published with no
  # annotation is the outcome this step exists to make impossible, and it must not read like a
  # novel publish in the nightly audit event. Two causes reach here and the line names both —
  # every scored neighbour was out of `linkable?/3`'s scope (routine in a multi-project
  # tenant), or the assessment carried none at all (an implementation contradicting itself).
  defp link(tenant_id, draft, _verdict, nil) do
    Logger.warning(
      "DraftConsumer: tenant=#{tenant_id} draft #{draft.id} assessed as a near-duplicate but " <>
        "no scored neighbour was linkable (another project, private/owner, or none scored); " <>
        "published WITHOUT an annotation."
    )

    :published_link_failed
  end

  # The annotation, and the only thing that separates this step from a bulk publish. It is
  # shaped as the auto-linker's own edge — `auto_generated: true` plus the cosine
  # `similarity_score`, inside `linkable?/3`'s scope — because
  # `KnowledgeLintWorker.promote_conflicts/1` reads exactly that shape, and because the
  # asynchronous `ArticleLinkingWorker` that `publish_article/3` chains to derives the SAME
  # edge from the stored vector once it lands. So this write moves the annotation to tonight;
  # it does not create a pair the graph would not otherwise have held.
  #
  # What it does NOT do is retract anything, and the moduledoc says where it really ends: the
  # promoted pair suppresses both articles from curated answers until the judge reaches it in
  # similarity order, and the judge's `:redundant` / `dismiss` is terminal and retires
  # neither. Publishing a near-duplicate is the owner-decided default; the edge is the record
  # of it, not a remedy for it.
  #
  # `on_conflict: :nothing` against the pair's unique index, so a re-run is a no-op.
  defp link(tenant_id, draft, verdict, %{id: neighbour_id, similarity_score: score}) do
    attrs = %{
      source_article_id: draft.id,
      target_article_id: neighbour_id,
      relationship_type: :relates_to,
      metadata: %{
        "auto_generated" => true,
        "similarity_score" => score,
        "linked_by" => @actor_label,
        "novelty_verdict" => to_string(verdict)
      }
    }

    %ArticleLink{tenant_id: tenant_id}
    |> ArticleLink.changeset(attrs)
    |> AdminRepo.insert(
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :source_article_id, :target_article_id, :relationship_type]
    )
    |> case do
      {:ok, _link} ->
        :published_linked

      {:error, changeset} ->
        # The article IS published — recoverable, visible, and the auto-linker still gets its
        # chance. Counted separately all the same: a near-duplicate published with no
        # annotation is the one outcome this step is supposed to make impossible, and it must
        # not hide inside `published`.
        Logger.warning(
          "DraftConsumer: tenant=#{tenant_id} published draft #{draft.id} but could not link " <>
            "it to #{neighbour_id} (#{inspect(Keyword.keys(changeset.errors))}); the " <>
            "annotation is left to the auto-linker."
        )

        :published_link_failed
    end
  end

  defp processed(%{published: p, unassessed: u, skipped: s, failed: f}), do: p + u + s + f

  # NEVER silent (#761 acceptance). Without this line and the `offered` counter beside it, a
  # night the clock cut short and a night with nothing left to consume report the same
  # `published`, and the difference is the whole question when the backlog stops falling.
  defp log_truncation(tenant_id, budget_ms, %{budget_exhausted: true} = result) do
    Logger.warning(
      "DraftConsumer: tenant=#{tenant_id} hit its #{budget_ms}ms budget after " <>
        "#{processed(result)} of #{result.offered} draft(s); the remainder is retried next run."
    )
  end

  defp log_truncation(_tenant_id, _budget_ms, _result), do: :ok

  # The EMBEDDING key, never `Llm.has_api_key?/1` (which answers for Anthropic extraction):
  # this step's per-item cost is an embedding call and `{:error, :no_api_key}` from that
  # provider is the one `:unknown` cause that is PERMANENT, self-inflicted and
  # operator-fixable, which `ProposalGate` folds into the same fall-open every transient
  # failure gets. Reading the wrong one of the pair both suppressed the warning on the tenant
  # that needs it and emitted it on a tenant that does not — the #620 shape, one step over.
  #
  # Self-guarded: a repo blip reading the tenant's LLM settings must not turn a runnable night
  # into a skipped one, so an unreadable answer assumes a key and lets the drain proceed with
  # the per-item fall-open still behind it.
  defp embedding_key?(tenant_id) do
    Llm.has_embedding_key?(tenant_id)
  rescue
    _e -> true
  catch
    :exit, _reason -> true
  end
end
