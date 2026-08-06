defmodule Loopctl.Knowledge.Consolidation do
  @moduledoc """
  The nightly consolidation ("dream") pass over a tenant's PUBLISHED corpus (#584, #605).

  It REPORTS on two defect classes, and APPLIES exactly one of them — `:duplicate_capture`,
  and only as `unpublish`, and only where two consecutive runs agree. `:generic_title` is
  report-only. See `apply_confirmed_duplicates/2` for why those three restrictions are the
  whole safety model.

  The pass reconciles the corpus and emits NUMBERED proposals, each naming the
  articles involved and carrying a QUOTED excerpt from each as evidence. It writes
  its findings to `consolidation_reports` / `consolidation_proposals`. The only other
  write it can make is the confirmed-duplicate unpublish above; it never writes
  `article_links` or `conflict_resolutions` (the nightly lint judge owns conflicts).
  There is no human approve/reject stage and there will not be one (#605 supersedes
  #594): a queue whose only consumer is a human nobody staffs is the failure this
  codebase has now hit four separate times (drafts, `potential_conflict`, `:supersede`
  below `:high`, and `:stale_entry`). Auto-apply is gated on REVERSIBILITY instead —
  a class may apply itself when its write can be undone in code, which is checkable
  without accumulating anyone's approvals.

  ## Why it consolidates published ARTICLES, not transcripts

  Session transcripts stay on the machines that produced them. A 2026-08-04 harvest
  found live API keys sitting in raw source material, so shipping transcripts to the
  server is an egress decision to be made deliberately, not a side effect of this
  pass. Capture keeps doing client-side extraction; this pass sees only what is
  already published here.

  ## Where it runs

  Inside the existing nightly `Loopctl.Workers.KnowledgeLintWorker` run (04:00 UTC,
  `all_tenants` fan-out) — deliberately NOT a second scheduler over the same corpus.
  It never runs in a request path: the API endpoint reads the persisted rows.

  ## The two defect classes

  | Class | Signal |
  |---|---|
  | `:duplicate_capture` | two published articles whose titles collide once case/punctuation are normalized away, or whose `idempotency_key`s collide under the same normalization while differing verbatim (tag-format drift — novelty scoring and idempotency are separate paths, so the novelty gate does not catch it) |
  | `:generic_title` | a placeholder title, which collides on per-tenant active-title uniqueness and blocks hub creation |

  `:contradiction_candidate` and `:stale_entry` are RETIRED — see the comments beside
  `title_drift_groups/1` and the proposal-assembly section for why each was withdrawn.
  Both values stay in the schema enum so historical rows load.

  ## Counts and their denominators (#582 discipline)

  `summary.total_proposals` is the TRUE pre-cap count of PROPOSALS (not articles:
  one duplicate group of three articles is one proposal, and one article may appear
  in several proposals). `summary.by_class` is the same unit per class.
  `summary.emitted` is how many proposals the capped arrays actually carry —
  lower exactly when a class hit `max_per_class`, which `summary.truncated` flags and
  which the worker logs. `summary.corpus_size` counts PUBLISHED, SHARED-visibility
  articles owned by this tenant — not its total article count, and not its
  agent-`private`/`owner` ones, which `shared_only/1` keeps out of this whole pass.

  Both remaining classes now derive their own totals from their own scan, so every count
  here has this pass as its denominator. (`:stale_entry` did not — it re-published lint's
  already-capped array under lint's threshold — which is one more reason it is gone.)

  ## Reads never touch the heat index

  Article bodies are read straight through the repo, never `Knowledge.get_article/3`,
  which records a heat-counted `get` event. A whole-corpus nightly pass reading through
  the public path would make the pass itself rank the corpus.

  ## Where the reads run

  Every whole-corpus ENUMERATION here (the corpus count, the two normalization GROUP BYs,
  the placeholder-title regex scan) goes
  through `Loopctl.HeavyRead` on the `:consolidation` endpoint, not straight through
  `AdminRepo`: those scans are unindexable by construction (they group on a
  `regexp_replace` expression) and `AdminRepo`'s pool is 3 connections shared with every
  other admin op, so an all-tenants nightly fan-out on the shared `:knowledge` queue can
  starve it. `HeavyRead` also gives each scan a `SET LOCAL statement_timeout` and the
  per-tenant in-flight shed. `analyze/2` holds ONE gate slot across the whole set
  (`with_slot/3`). The evidence fetch stays on `AdminRepo` — it is keyed by a bounded id
  list, not an enumeration — and so do the report/proposal WRITES.

  ## Why the scan is whole-corpus and stays that way

  It looks like the textbook case for a delta scan — 79,276 published articles read every
  night to surface a few hundred proposals, of which only ~20 were touched that day. It is
  not, and the reason is measurement rather than taste. TIMED on the hosted corpus
  2026-08-05, BEFORE the placeholder-title predicate was folded into the title-drift scan:
  title drift 1,955 ms, idempotency drift 13 ms, placeholder titles 920 ms,
  corpus count 51 ms — ~2.9 s. That predicate re-does the same normalization the standalone
  placeholder scan measures, so until it is re-timed bound the total at **~3.9 s, once a
  night**, on a pool that exists for exactly this. There is no cost problem to solve.

  A delta scan would also cost correctness twice over. `apply_confirmed_duplicates/2`
  applies only what TWO CONSECUTIVE runs propose, so a group whose articles did not change
  between runs would drop out of the second report and could never be confirmed — the delta
  window would have to exceed the run interval just to keep the gate working. And a group
  nobody has touched in a year would never be scanned again at all, stranding the standing
  backlog that is most of what the class finds.

  If this ever does get slow, the cheap fix is an expression index on the normalization
  (the plan is a seq scan plus a 9 MB external-merge sort), NOT a narrower scan.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Embeddings
  alias Loopctl.ExitTag
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ConsolidationProposal
  alias Loopctl.Knowledge.ConsolidationReport
  alias Loopctl.Workers.BatchArticleEmbeddingWorker

  @default_max_per_class 100
  @hard_max_per_class 500
  # Page-depth ceiling. A report holds at most one cap's worth of proposals per class, so
  # this is well past the end of any real page — it exists so an unbounded `offset` cannot
  # reach Postgrex as an out-of-bigint-range integer and 500 the read endpoint.
  @max_offset 100_000
  # Excerpt length (graphemes) of the QUOTED evidence carried per article.
  @excerpt_chars 240
  # Bodies are fetched pre-truncated in SQL so a whole-corpus pass can never pull
  # 100 KB per article into memory.
  @excerpt_source_chars 1000
  # Placeholder titles that block hub creation (the "Untitled Document" 409). ONE
  # definition, referenced by both the query and the endpoint documentation.
  @generic_title_pattern "^(untitled|untitled document|new article|new document|document|draft|no title|untitled note)( [0-9]+)?$"
  # The heavy-read endpoint every whole-corpus enumeration in this module runs under.
  @heavy_endpoint :consolidation

  # The normalized-title grouping key, in ONE place. `title_drift_groups/1` forms groups with
  # it and `pairwise_similarity_by_group/2` re-derives the same groups to score them; if the
  # two ever disagreed the gate would score the wrong sets and silently pass collisions.
  @title_key_sql "btrim(regexp_replace(lower(?), '[^[:alnum:]]+', ' ', 'g'))"

  # How many CONFIRMED duplicate groups one nightly run may apply. Bounded because each
  # apply is a write on the shared admin pool, and because a bug that mis-picks winners
  # should be visible after one night rather than after the whole corpus.
  @default_max_applies 25

  # A GROUP cap is not an ARTICLE cap: one duplicate group can carry many members, so 25
  # groups is an unbounded number of unpublishes. This bounds the thing that is actually
  # irreversible-adjacent — loser articles pulled out of the published set in one night.
  @default_max_unpublishes 100

  # Hard ceilings for the two operator-configurable apply caps, mirroring
  # `@hard_max_per_class`. Both knobs are clamped to `0..ceiling`, and only an INTEGER is
  # clamped: an unclamped negative `:max_applies` reached `limit: ^cap` as a Postgrex error,
  # while Erlang term order puts a `nil` or a `"500"` ABOVE every integer, so `min/2` would
  # resolve a config typo to the ceiling — the largest blast radius available — instead of to
  # the default. `0` is honoured as an explicit PAUSE (`gate: :drain_disabled`) rather than
  # rounded up to 1: an operator halting the drain mid-incident must not still get a night of
  # unpublishes out of it.
  @hard_max_applies 500
  @hard_max_unpublishes 500

  # The classes `analyze/2` still PRODUCES, in the order proposals are numbered in. Distinct
  # from `ConsolidationProposal.classes()`, which is the schema enum and additionally carries
  # the retired values so historical rows load. Assembly iterates THIS list.
  @live_classes [:duplicate_capture, :generic_title]

  # How far apart the two agreeing reports may be, in days. One night's gap is normal (a
  # skipped run); anything wider is not the "two consecutive runs" the gate advertises.
  @max_confirmation_gap 2

  # The signal that formed a duplicate group survives onto the persisted proposal ONLY inside
  # the rationale prose, so the sentence (`duplicate_captures/2`) and the apply-time
  # classifier (`title_drift?/1`) both interpolate the phrase from HERE. They used to be a
  # sentence and a substring literal that nothing pinned together — a copy edit would have
  # turned the one content check on the auto-applying class off without failing anything.
  @title_drift "title drift"
  @idempotency_drift "idempotency-tag drift"

  # Default corroboration threshold, and the fallback for a config value that is not a number
  # in `0.0..1.0`. Measured band on the hosted corpus 2026-08-06: collisions at/below 0.68,
  # genuine duplicates at/above 0.84.
  @default_min_duplicate_similarity 0.80

  # The visibility guard, in ONE place, usable in a `where` AND in a join `on` — see
  # `shared_only/1` for why it must be composed into every scope decision this pass makes.
  defmacrop shared_visibility(metadata) do
    quote do
      fragment(
        "COALESCE(?->>'visibility', 'shared') NOT IN ('private','owner')",
        unquote(metadata)
      )
    end
  end

  @doc "Default cap on duplicate GROUPS one run may apply."
  @spec default_max_applies() :: pos_integer()
  def default_max_applies, do: @default_max_applies

  @doc "Default cap on loser ARTICLES one run may unpublish."
  @spec default_max_unpublishes() :: pos_integer()
  def default_max_unpublishes, do: @default_max_unpublishes

  @doc "Default per-class proposal cap."
  @spec default_max_per_class() :: pos_integer()
  def default_max_per_class, do: @default_max_per_class

  @doc "Hard ceiling for the per-class proposal cap."
  @spec hard_max_per_class() :: pos_integer()
  def hard_max_per_class, do: @hard_max_per_class

  @doc "Page-depth ceiling for `:offset` on the read path."
  @spec max_offset() :: pos_integer()
  def max_offset, do: @max_offset

  @doc "Length (graphemes) of the quoted evidence excerpt carried per article."
  @spec excerpt_chars() :: pos_integer()
  def excerpt_chars, do: @excerpt_chars

  @doc "The placeholder-title regex used by the `:generic_title` class (POSIX, case-folded)."
  @spec generic_title_pattern() :: String.t()
  def generic_title_pattern, do: @generic_title_pattern

  @doc """
  Derives the proposals for a tenant. Pure read — touches nothing.

  Opts: `:max_per_class` (default #{@default_max_per_class}, hard max
  #{@hard_max_per_class}).
  """
  @spec analyze(Ecto.UUID.t(), keyword()) :: {:ok, map()}
  def analyze(tenant_id, opts \\ []) do
    cap =
      opts
      |> Keyword.get(:max_per_class, @default_max_per_class)
      |> max(1)
      |> min(@hard_max_per_class)

    # ONE gate slot for the whole read unit: the scans below are logically one pass, and
    # acquiring per query would let the cheap halves run ungated between the expensive ones.
    {corpus_size, found} =
      HeavyRead.with_slot(tenant_id, heavy_opts(), fn ->
        {corpus_size(tenant_id),
         %{
           duplicate_capture: duplicate_captures(tenant_id, cap),
           generic_title: generic_titles(tenant_id, cap)
         }}
      end)

    by_class = Map.new(found, fn {class, {total, _items}} -> {to_string(class), total} end)

    truncated =
      Map.new(found, fn {class, {total, items}} -> {to_string(class), total > length(items)} end)

    # Drive the ORDER from `@live_classes` — the classes this pass still PRODUCES — and
    # `Map.fetch!` over THAT list, so a dropped producer raises.
    #
    # This used to iterate the schema enum and `Enum.filter(&Map.has_key?(found, &1))` in
    # front of the fetch, which made the "fails loudly" guarantee unreachable: the filter
    # removed exactly the keys `Map.fetch!` would have raised on, so deleting a producer
    # silently shortened the report and its `by_class` instead. A guard whose precondition
    # is established by the line above it is not a guard.
    proposals =
      @live_classes
      |> Enum.flat_map(fn class -> found |> Map.fetch!(class) |> elem(1) end)
      |> Enum.with_index(1)
      |> Enum.map(fn {proposal, number} -> Map.put(proposal, :number, number) end)

    total_proposals = by_class |> Map.values() |> Enum.sum()

    {:ok,
     %{
       proposals: proposals,
       summary: %{
         corpus_size: corpus_size,
         total_proposals: total_proposals,
         emitted: length(proposals),
         by_class: by_class,
         truncated: truncated,
         max_per_class: cap,
         generated_at: DateTime.utc_now()
       }
     }}
  end

  @doc """
  Runs the pass and persists it as the tenant's report for the day.

  The ONLY writes are the report row and its proposal rows. Re-running on the same
  day upserts one report (never two) and re-derives its proposals, dropping the ones
  that no longer apply. A re-derived proposal RESETS `review_status` / `reviewed_by`
  / `reviewed_at`: refreshed machine output must earn review again.

  Opts: `:max_per_class`, `:day` (defaults to today, UTC).
  """
  @spec run(Ecto.UUID.t(), keyword()) :: {:ok, ConsolidationReport.t()}
  def run(tenant_id, opts \\ []) do
    {:ok, analysis} = analyze(tenant_id, opts)
    day = Keyword.get(opts, :day) || Date.utc_today()
    log_truncation(tenant_id, analysis.summary)

    {:ok, report} =
      AdminRepo.transaction(fn ->
        report = upsert_report(tenant_id, day, analysis)
        prune_proposals(report.id, analysis.proposals)
        Enum.each(analysis.proposals, &upsert_proposal(tenant_id, report.id, &1))
        report
      end)

    {:ok, report}
  end

  @doc """
  Applies the `:duplicate_capture` proposals that TWO consecutive runs agree on.

  The only class this pass applies by itself, and the only action it will take: keep the
  richest article of a duplicate group and UNPUBLISH the rest.

  ## Why unpublish and never archive

  `:archived` is TERMINAL for an article — `Article`'s transition table has no
  `{:archived, _}` and there is no unarchive function, so the only way back is a `user+`
  PATCH. `{:published, :draft}` and `{:draft, :published}` are both real transitions, so
  unpublish is the one retraction an unattended pass can undo. A class earns auto-apply by
  being REVERSIBLE, not by being confident.

  ## Why two runs must agree

  This replaces the human approve/reject stage (#605 supersedes #594) with something that
  works without anyone: a proposal applies only if the SAME fingerprint appeared in the
  PREVIOUS report as well. Anything transient — a duplicate created and cleaned up between
  runs, a title edited mid-scan, a half-finished import — is gone by the next night and is
  never acted on. It costs one night of latency and removes the entire class of "acted on a
  state that was already resolving itself", which is most of what a human reviewer catches.

  "Consecutive" means the previous report is at most `#{@max_confirmation_gap}` days older,
  so ONE skipped run is tolerated and a longer outage is not. On a tenant whose scans failed
  for a fortnight the two most recent reports are tonight and a report from before the
  outage, and agreement across that gap is not the transience filter this claims to be. When
  the window is exceeded the whole apply is skipped and the return carries
  `gate: :report_gap`; a tenant with fewer than two reports carries
  `gate: :insufficient_history`. Both are distinct from `gate: :open` with nothing confirmed,
  which is what a clean corpus looks like.

  ## What bounds one night

  Two caps, in different units, each clamped to `0..500` — `0` PAUSES the drain and records
  `gate: :drain_disabled`, and a non-integer falls back to the module default rather than to
  the ceiling. `:max_applies` bounds how many PROPOSALS are considered; `:max_unpublishes`
  bounds how many loser ARTICLES actually leave the published set, and it is the one that
  matters, because a group can carry many members. The EFFECTIVE defaults are the shipped
  `config/config.exs` values (`knowledge_consolidation_max_applies` /
  `_max_unpublishes`, both 500); `#{@default_max_applies}` / `#{@default_max_unpublishes}`
  are only the module fallbacks for a config that omits them.

  A group larger than the remaining budget is drained AS FAR AS the budget goes, not skipped
  whole. The winner is never a candidate for unpublishing, so a part-drained group is
  winner-plus-leftovers — the shape the next scan re-derives — never the winnerless state a
  whole-group rule was written to avoid. Skipping whole made any group with more losers than
  the cap permanently unappliable, and with the cap itself ceilinged at 500 the "raise the
  cap" remedy was unreachable: the backlog converged to a floor, which is the failure this
  pass exists to fix. The budget is charged on the LIVE loser count at write time and only
  for articles that actually LEFT the published set — a rejected unpublish is counted in
  `failed`, never spent.

  It is deliberately NOT a confidence score. Confidence is the machine grading its own
  homework; agreement across two independent observations of a moving corpus is evidence.

  ## Why the winner is recomputed here, not read from the proposal

  The corpus moves between the scan and the write, so the winner is picked from the LIVE
  rows: every article in the group is re-fetched and re-checked as still published, and a
  group left with fewer than two live published members is skipped, not forced. Reading a
  winner chosen hours ago would be applying a decision to a corpus that no longer matches it.

  What is NOT re-derived here is the COLLISION: the normalized title / idempotency key is
  not recomputed at apply time. Collision freshness rests entirely on the two-run agreement
  gate — a group broken up by a rename drops out of tonight's report and can never be
  confirmed — which is why the worker calls this only after tonight's report was written
  (`Loopctl.Workers.KnowledgeLintWorker`).
  ## What a TITLE collision must additionally clear

  Agreement filters transience, not wrongness: a title two unrelated sources share collides
  deterministically, so both runs agree. A TITLE-signal group is applied only when its live
  members also corroborate in CONTENT — every member scored at the active embedding
  dimension, worst pair at or above `#{@default_min_duplicate_similarity}` (tunable). One
  that cannot is REPORTED, counted in `uncorroborated`, and has its missing vectors
  enqueued so the withhold clears itself. The idempotency signal is exempt (`corroborated?/3`).
  """
  @spec apply_confirmed_duplicates(Ecto.UUID.t(), keyword()) :: %{
          applied: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          uncorroborated: non_neg_integer(),
          gate: :open | :report_gap | :insufficient_history | :drain_disabled
        }
  def apply_confirmed_duplicates(tenant_id, opts \\ []) do
    cap =
      clamp_cap(
        Keyword.get(opts, :max_applies, @default_max_applies),
        @default_max_applies,
        @hard_max_applies
      )

    unpublish_cap =
      clamp_cap(
        Keyword.get(opts, :max_unpublishes, @default_max_unpublishes),
        @default_max_unpublishes,
        @hard_max_unpublishes
      )

    if min(cap, unpublish_cap) == 0 do
      log_gate_blocked(tenant_id, :drain_disabled)
      %{applied: 0, skipped: 0, failed: 0, uncorroborated: 0, gate: :drain_disabled}
    else
      run_confirmed_duplicates(tenant_id, cap, unpublish_cap)
    end
  end

  # Only an integer is clamped. A `nil` or a `"500"` from a hand-rolled env read sorts ABOVE
  # every integer in Erlang term order, so `min/2` would hand a config typo the ceiling — the
  # largest blast radius available — rather than the default it meant to fall back to.
  defp clamp_cap(value, _default, hard_max) when is_integer(value),
    do: value |> max(0) |> min(hard_max)

  defp clamp_cap(value, default, _hard_max) do
    Logger.warning(
      "Consolidation: ignoring non-integer apply cap #{inspect(value)}; using #{default}."
    )

    default
  end

  defp run_confirmed_duplicates(tenant_id, cap, unpublish_cap) do
    case confirmed_duplicate_proposals(tenant_id, cap) do
      {:error, reason} ->
        log_gate_blocked(tenant_id, reason)
        %{applied: 0, skipped: 0, failed: 0, uncorroborated: 0, gate: reason}

      {:ok, proposals} ->
        # Scored ONCE for the whole batch, then consulted per group AFTER its liveness
        # re-check — so a group that dissolved between the scan and now still reports
        # `skipped` (the accurate reason) rather than being relabelled uncorroborated.
        scored = score_groups(tenant_id, proposals)

        proposals
        |> Enum.reduce(
          %{applied: 0, skipped: 0, failed: 0, uncorroborated: 0, gate: :open},
          &tally_apply(tenant_id, &1, &2, unpublish_cap, scored)
        )
    end
  end

  # The ONLY heavy read on the apply path, and it runs BEFORE the reduce — so a statement
  # timeout or a `HeavyRead` shed would escape past `tally_apply/5`'s per-group rescue and
  # cost the whole night's drain, deterministically, every night. A failure degrades to NO
  # evidence instead: title-drift groups are withheld one by one (fail-closed, counted in
  # `uncorroborated`) and idempotency-drift groups still apply.
  defp score_groups(tenant_id, proposals) do
    pairwise_similarity_by_group(tenant_id, Enum.flat_map(proposals, & &1.article_ids))
  rescue
    e -> log_scoring_failed(tenant_id, ExitTag.tag(e))
  catch
    :exit, reason -> log_scoring_failed(tenant_id, "exit:" <> ExitTag.tag(reason))
  end

  defp log_scoring_failed(tenant_id, tag) do
    Logger.error(
      "Consolidation: tenant=#{tenant_id} duplicate similarity scoring failed (#{tag}); " <>
        "every title-drift group is withheld this run."
    )

    %{}
  end

  # "The gate was shut" and "the gate was open and confirmed nothing" both used to return an
  # empty list, so `applied: 0, skipped: 0` in the audit event was byte-identical for a fresh
  # install, a tenant mid-outage, and a genuinely clean corpus. The reason tag is what lets an
  # auditor tell a quiet night from a blocked one without reading the reports table.
  defp log_gate_blocked(tenant_id, reason) do
    Logger.info(
      "Consolidation: tenant=#{tenant_id} duplicate apply gate CLOSED (#{reason}); " <>
        "nothing applied this run."
    )
  end

  # `:failed` counts LOSER ARTICLES left published — the counter that separates "nothing was
  # confirmed" from "everything was confirmed and every write was rejected". Without it both
  # nights record applied=0/skipped=0 and the audit event, which is the surface an auditor
  # reads, cannot tell them apart.
  #
  # The rescue/catch is here rather than only at the worker's blanket one because this reduce
  # is NOT transactional: each group's unpublishes commit on their own, so a raise escaping
  # to the worker discarded the tally of groups that had ALREADY committed and reported zero
  # unpublishes that really happened. A crashed group applied nothing, so it counts as one
  # failure and the reduce carries on.
  #
  # The remaining budget is spent INSIDE `apply_duplicate_group/3`, after the live re-fetch,
  # and only `acc.applied` is charged. Two reasons, both of which cost the pass real drain:
  # `acc.failed` counts loser articles that STAYED published, and this cap counts articles
  # that LEAVE the published set; and the proposal's `article_ids` is a scan-time snapshot, so
  # charging its length skipped groups for budget they would never have spent (the same reason
  # the winner is recomputed from live rows).
  defp tally_apply(tenant_id, proposal, acc, unpublish_cap, scored) do
    case apply_duplicate_group(tenant_id, proposal, unpublish_cap - acc.applied, scored) do
      {:ok, applied, failed} ->
        %{acc | applied: acc.applied + applied, failed: acc.failed + failed}

      :skip ->
        %{acc | skipped: acc.skipped + 1}

      :uncorroborated ->
        %{acc | uncorroborated: acc.uncorroborated + 1}
    end
  rescue
    e -> group_failed(tenant_id, proposal, ExitTag.tag(e), acc)
  catch
    :exit, reason -> group_failed(tenant_id, proposal, "exit:" <> ExitTag.tag(reason), acc)
  end

  # `:failed` is counted in LOSER ARTICLES everywhere else, so a crashed group contributes
  # its loser count — every member but the winner — rather than a flat 1. Mixing units in one
  # field makes the number unreadable on exactly the night it matters: a systematic failure
  # across 25 groups of four would have reported 25 while 75 articles stayed published.
  defp group_failed(tenant_id, proposal, tag, acc) do
    losers = losers(proposal)

    Logger.error(
      "Consolidation: tenant=#{tenant_id} duplicate_capture proposal ##{proposal.number} " <>
        "could not be applied (#{tag}); #{losers} loser article(s) left published."
    )

    %{acc | failed: acc.failed + losers}
  end

  # Every member but the winner, from the SCAN-time id set — a crashed group never reached
  # the live re-fetch, so this is the only count it has. Floored at 1 so a malformed
  # single-member group still counts as one failure rather than as nothing.
  defp losers(proposal), do: max(length(proposal.article_ids) - 1, 1)

  # Proposals present in BOTH the newest report and the one before it, matched on
  # `fingerprint` — which is derived from the class plus the sorted article-id set, so it is
  # stable across runs precisely when the same group is still being found.
  #
  # The previous report must be ADJACENT (`@max_confirmation_gap` days): the gate the
  # moduledoc advertises is "tonight agreed with last night", and on a tenant whose scans
  # failed for a fortnight the two most recent reports are tonight and a report from before
  # the outage — agreement across that gap is not the transience filter this claims to be.
  defp confirmed_duplicate_proposals(tenant_id, cap) do
    case recent_reports(tenant_id) do
      [newest, previous] ->
        if Date.diff(newest.day, previous.day) <= @max_confirmation_gap do
          {:ok, confirmed_against(tenant_id, newest, previous, cap)}
        else
          {:error, :report_gap}
        end

      _fewer_than_two_reports ->
        # First ever run, or only one report so far: nothing has been confirmed twice, so
        # nothing applies. The pass is silent rather than eager on a fresh install.
        {:error, :insufficient_history}
    end
  end

  defp confirmed_against(tenant_id, newest, previous, cap) do
    previous_fingerprints =
      from(p in ConsolidationProposal,
        where: p.tenant_id == ^tenant_id and p.report_id == ^previous.id,
        where: p.proposal_class == :duplicate_capture,
        select: p.fingerprint
      )
      |> AdminRepo.all()

    # Ordered by a per-report hash of the fingerprint, NOT by proposal number. A group whose
    # unpublish is rejected every night keeps being re-derived and keeps its low number, so a
    # number-ordered cap handed the same 25 losers every slot forever and no other confirmed
    # group was ever attempted. The hash re-shuffles nightly (the report id is new each run)
    # while staying deterministic within one run.
    from(p in ConsolidationProposal,
      where: p.tenant_id == ^tenant_id and p.report_id == ^newest.id,
      where: p.proposal_class == :duplicate_capture,
      where: p.fingerprint in ^previous_fingerprints,
      order_by: fragment("md5(? || ?::text)", p.fingerprint, ^newest.id),
      limit: ^cap
    )
    |> AdminRepo.all()
  end

  defp recent_reports(tenant_id) do
    from(r in ConsolidationReport,
      where: r.tenant_id == ^tenant_id,
      order_by: [desc: r.day],
      limit: 2,
      select: %{id: r.id, day: r.day}
    )
    |> AdminRepo.all()
  end

  defp apply_duplicate_group(tenant_id, proposal, budget, scored) do
    live =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.id in ^proposal.article_ids,
        where: a.status == :published,
        select: %{
          id: a.id,
          body_len: fragment("length(coalesce(?, ''))", a.body),
          updated_at: a.updated_at
        }
      )
      |> shared_only()
      |> AdminRepo.all()

    # Re-verification, not trust. The group must STILL be a group: fewer than two live
    # published members means it resolved itself between the scan and now, and applying
    # would unpublish the last copy of something. No budget left is the other skip.
    if length(live) < 2 or budget < 1 do
      :skip
    else
      case corroborated?(proposal, live, scored) do
        :ok ->
          apply_live_group(tenant_id, proposal, live, budget)

        {:withheld, entry, unscored} ->
          log_uncorroborated(tenant_id, proposal, live, entry, unscored)
          backfill_missing_embeddings(tenant_id, unscored)
          :uncorroborated
      end
    end
  end

  # A group withheld for MISSING evidence would otherwise be withheld on this and every
  # subsequent night: nothing else in this pass embeds an article and the lint worker's
  # backfill covers link ORPHANS only, so an un-embedded member (the corpus has had 80 since
  # June) is a producer with no consumer — the shape #605 exists to close. The withhold
  # therefore enqueues the vectors it lacked, on the batched worker every other bulk path
  # uses. Best-effort and crash-proof; a tenant with no embedding key (mandatory BYO) simply
  # has the job discarded.
  defp backfill_missing_embeddings(_tenant_id, []), do: :ok

  defp backfill_missing_embeddings(tenant_id, ids) do
    ids
    |> Enum.chunk_every(Knowledge.embedding_batch_max())
    |> Enum.each(fn chunk ->
      %{article_ids: chunk, tenant_id: tenant_id}
      |> BatchArticleEmbeddingWorker.new()
      |> Oban.insert()
    end)

    :ok
  rescue
    e -> log_backfill_failed(tenant_id, ExitTag.tag(e))
  catch
    :exit, reason -> log_backfill_failed(tenant_id, "exit:" <> ExitTag.tag(reason))
  end

  defp log_backfill_failed(tenant_id, tag) do
    Logger.warning(
      "Consolidation: tenant=#{tenant_id} could not enqueue the embedding backfill for a " <>
        "withheld duplicate group (#{tag}); it will be retried next run."
    )

    :ok
  end

  defp apply_live_group(tenant_id, proposal, live, budget) do
    [winner | all_losers] =
      Enum.sort_by(live, fn a ->
        {-a.body_len, -DateTime.to_unix(a.updated_at, :microsecond), a.id}
      end)

    # Drained as far as the budget goes, not skipped whole: the winner is never a candidate
    # here, so what is left behind is winner-plus-leftovers — the group the next scan
    # re-derives — never a winnerless set. Skipping whole made a group with more losers
    # than the cap unappliable on EVERY run, with no reachable remedy once the cap itself
    # is ceilinged.
    losers = Enum.take(all_losers, budget)
    applied = Enum.count(losers, &unpublish_duplicate(tenant_id, &1))

    Logger.info(
      "Consolidation: tenant=#{tenant_id} applied duplicate_capture proposal " <>
        "##{proposal.number} — kept #{winner.id}, unpublished #{applied} of " <>
        "#{length(all_losers)} duplicate(s) (budget #{budget}). Reversible via publish."
    )

    {:ok, applied, length(losers) - applied}
  end

  # A per-article failure stays per-article, and says why. `Knowledge.unpublish_article/3`
  # can return a THREE-element `{:error, :unprocessable_entity, msg}` — an article archived
  # or superseded by another actor between the SELECT above and the locked fetch inside the
  # transition — so a `case` matching only 2-tuples raised a CaseClauseError out of the whole
  # apply, losing every remaining confirmed group for that tenant to the worker's blanket
  # rescue. The rescue/catch keeps a raise or a checkout exit equally per-article, so the
  # losers already unpublished in this group stay counted. The reason is logged as a
  # low-cardinality TAG (never the raw message), and every failure is also counted into the
  # `failed` tally the audit event carries — the log alone cannot tell a systematically
  # failing apply from a night with nothing to apply.
  defp unpublish_duplicate(tenant_id, loser) do
    case Knowledge.unpublish_article(tenant_id, loser.id,
           actor_type: "system",
           actor_label: "worker:consolidation"
         ) do
      {:ok, _} -> true
      other -> log_unpublish_failure(tenant_id, loser, unpublish_error_tag(other))
    end
  rescue
    e -> log_unpublish_failure(tenant_id, loser, ExitTag.tag(e))
  catch
    :exit, reason -> log_unpublish_failure(tenant_id, loser, "exit:" <> ExitTag.tag(reason))
  end

  defp log_unpublish_failure(tenant_id, loser, tag) do
    Logger.warning(
      "Consolidation: tenant=#{tenant_id} could not unpublish duplicate #{loser.id} " <>
        "(#{tag}); left published."
    )

    false
  end

  defp unpublish_error_tag({:error, reason, _message}) when is_atom(reason), do: to_string(reason)
  defp unpublish_error_tag({:error, reason}) when is_atom(reason), do: to_string(reason)
  # Everything else the callee can return is a changeset (a rejected transition or a failed
  # validation). Tagged, never inspected: the log stays low-cardinality either way.
  defp unpublish_error_tag(_other), do: "invalid"

  @doc """
  Reads a persisted report and its proposals. Never recomputes.

  Evidence is re-checked against the live corpus on the way out: an entry whose article has
  since been hard-deleted or archived is redacted to its id (`"redacted" => true`), so the
  stored excerpt never outlives the article it quotes. A DRAFT still counts as live — that
  is what this pass's own unpublish leaves behind, and redacting it would erase the evidence
  for the very action the pass took.

  Opts: `:day` (defaults to the tenant's most recent report), `:class`, `:limit`
  (default 50, max #{@hard_max_per_class}), `:offset` (clamped to #{@max_offset}).
  """
  @spec latest(Ecto.UUID.t(), keyword()) :: {:ok, map()}
  def latest(tenant_id, opts \\ []) do
    case fetch_report(tenant_id, Keyword.get(opts, :day)) do
      nil ->
        {:ok, %{report: nil, proposals: [], total_count: 0}}

      report ->
        base =
          from(p in ConsolidationProposal,
            where: p.tenant_id == ^tenant_id,
            where: p.report_id == ^report.id
          )

        base =
          case Keyword.get(opts, :class) do
            nil -> base
            class -> where(base, [p], p.proposal_class == ^class)
          end

        limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(@hard_max_per_class)
        # Clamped at BOTH ends. A report carries at most one cap's worth of proposals per
        # class, so any offset past @max_offset is already past the end — while an
        # unclamped one reaches Postgrex as an arbitrary-precision integer and raises
        # DBConnection.EncodeError (a 500) for anything over a bigint.
        offset = opts |> Keyword.get(:offset, 0) |> max(0) |> min(@max_offset)

        proposals =
          base
          |> order_by([p], asc: p.number)
          |> limit(^limit)
          |> offset(^offset)
          |> AdminRepo.all()

        {:ok,
         %{
           report: report,
           proposals: redact_stale_evidence(tenant_id, proposals),
           total_count: AdminRepo.aggregate(base, :count, :id)
         }}
    end
  end

  # --- Detection ---

  defp published_base(tenant_id) do
    from(a in Article, where: a.tenant_id == ^tenant_id, where: a.status == :published)
    |> shared_only()
  end

  @doc false
  # Excludes agent-PRIVATE articles from everything this pass does. Composed into EVERY
  # place that decides whether an article of this tenant is in scope — the scans
  # (`published_base/1`), the evidence fetch (`evidence_map/2`), the apply-time live
  # re-check (`apply_duplicate_group/3`), BOTH sides of the corroboration self-join
  # (`pairwise_similarity_by_group/2`, via the shared `shared_visibility/1` macro) and the
  # read-time redaction liveness (`live_evidence_ids/2`) — because a guard that lives in
  # only some of them is a guard the next reader adds one more path around.
  #
  # Two distinct harms, and the quieter one is worse. The LOUD one: `:duplicate_capture`
  # auto-applies (#608), so without this the pass could unpublish one agent's private memory
  # on the strength of a title it shares with another agent's. The QUIET one: every proposal
  # carries a QUOTED #{@excerpt_chars}-character excerpt of each article's body into a report
  # any orchestrator key can read — so an unguarded scan republishes private bodies into a
  # shared surface whether or not anything is ever applied.
  #
  # The pass runs as the SYSTEM. It holds no agent identity, so it can never be the owner
  # that `Knowledge`'s read paths let through; "not visible to this caller" is total here,
  # not conditional. Same `COALESCE(..., 'shared')` spelling as those paths
  # (`knowledge.ex:5902` and friends) so an article with no `visibility` key stays in scope.
  defp shared_only(query), do: where(query, [a], shared_visibility(a.metadata))

  defp heavy_opts, do: HeavyRead.opts(@heavy_endpoint)

  defp heavy_all(query, tenant_id), do: HeavyRead.all(tenant_id, query, heavy_opts())

  defp corpus_size(tenant_id) do
    HeavyRead.one(
      tenant_id,
      from(a in published_base(tenant_id), select: count(a.id)),
      heavy_opts()
    )
  end

  # Two format-drift signals, merged and de-duplicated by the article set they name.
  #
  # The merge is a ROUND-ROBIN interleave, not a sort on the reason string. Sorting put
  # every "idempotency-tag" group ahead of every "title" group, so a tenant with at least
  # `cap` idempotency-drift groups emitted ZERO title-drift proposals — one of the two
  # signals starved entirely rather than the cap being shared between them, and
  # `summary.truncated` carries one boolean per CLASS, so nothing said a whole signal was
  # missing. Interleaving keeps both signals represented in every run and stays
  # deterministic (each side is sorted by its article-id set first).
  defp duplicate_captures(tenant_id, cap) do
    by_ids = fn {_reason, ids} -> Enum.sort(ids) end
    idempotency = Enum.sort_by(idempotency_drift_groups(tenant_id), by_ids)
    idempotency_keys = MapSet.new(idempotency, by_ids)

    # A group BOTH signals name is labelled by the IDEMPOTENCY one. The dedup keeps whichever
    # entry it meets first and the interleave meets the title entry first, so a re-import that
    # drifted in its tag format AND (being one capture) carries the same title kept the weaker
    # label — and was then held to the embedding gate the idempotency signal is exempt from
    # (`corroborated?/3`), forever on a tenant with no vectors.
    titles =
      title_drift_groups(tenant_id)
      |> Enum.sort_by(by_ids)
      |> Enum.map(fn {reason, ids} ->
        if MapSet.member?(idempotency_keys, Enum.sort(ids)),
          do: {@idempotency_drift, ids},
          else: {reason, ids}
      end)

    groups = titles |> interleave(idempotency) |> Enum.uniq_by(by_ids)

    selected = Enum.take(groups, cap)
    evidence_by_id = evidence_map(tenant_id, Enum.flat_map(selected, fn {_r, ids} -> ids end))

    items =
      Enum.map(selected, fn {reason, ids} ->
        build_proposal(:duplicate_capture, ids, evidence_by_id,
          severity: "warning",
          rationale:
            "#{length(ids)} published articles are the same capture under #{reason}. " <>
              "The novelty gate does not catch this: novelty scoring and idempotency are separate paths.",
          suggested_action:
            "Keep the richest article and UNPUBLISH the rest — do not archive them. " <>
              "`:archived` is TERMINAL for an article: `Article`'s transition table has no " <>
              "`{:archived, _}` and there is no unarchive function, so the only way back is a " <>
              "`user+` PATCH carrying an explicit status. `{:published, :draft}` and " <>
              "`{:draft, :published}` are both real transitions, so unpublish is the " <>
              "reversible primitive and the only one an unattended pass may ever apply."
        )
      end)

    {length(groups), items}
  end

  defp interleave([], rest), do: rest
  defp interleave(rest, []), do: rest
  defp interleave([a | as], [b | bs]), do: [a, b | interleave(as, bs)]

  # Titles that collide once case and punctuation are normalized away. The exact
  # active-title uniqueness check cannot see these — that is why they got published.
  #
  # The separator class is the UNICODE-AWARE `[^[:alnum:]]`, never `[^a-z0-9]`. The
  # ASCII-only class deletes every non-Latin codepoint, so a title collapses onto
  # whatever incidental ASCII it carries — "日本語ガイド v2" and "中文指南 v2" both become
  # "v2", and "Паттерн Retry" and "Обзор Retry" both become "retry". Unrelated articles
  # then group as "the same capture under title drift", a deterministic false positive in
  # the ONE class that applies itself (`apply_confirmed_duplicates/2`) — so under the ASCII
  # class this normalization is what would decide to unpublish two unrelated non-Latin
  # articles, twice running, and the two-run agreement gate would agree with itself because
  # the bug is deterministic. ASCII behaviour is identical under both classes
  # ("Retry  Pattern!!" -> "retry pattern").
  #
  # (This comment used to call `:duplicate_capture` "the class #584 names as the likely first
  # auto-apply candidate", and read the risk as poisoning a human calibration signal. #605
  # retired that framing: archive is TERMINAL for an article, so the class earned auto-apply
  # by being restricted to the REVERSIBLE unpublish, not by being ranked first. The
  # consequence of a false positive got smaller and more immediate, not larger and deferred.)
  #
  # The EMPTY normalized key is still excluded, and that exclusion is still load-bearing:
  # a title made only of symbols or emoji ("🚀", "!!!") normalizes to the empty string
  # under either class, and without the guard those all land in one group.
  #
  # PLACEHOLDER keys are excluded for the same reason, one step up: "Untitled Document" and
  # "untitled document!" survive the case-sensitive active-title unique index, normalize to
  # one key, and would group as "the same capture under title drift" — so the one class that
  # applies itself would unpublish UNRELATED articles whose only shared property is a missing
  # title, and the two-run gate would agree with itself because the grouping is deterministic.
  # A shared placeholder title is evidence of a missing title, not of a duplicate capture;
  # `generic_titles/2` reports exactly this set, under the class that applies nothing.
  defp title_drift_groups(tenant_id) do
    from(a in published_base(tenant_id),
      where: fragment(unquote(@title_key_sql <> " <> ''"), a.title),
      where: fragment(unquote(@title_key_sql <> " !~ ?"), a.title, ^@generic_title_pattern),
      group_by: fragment(unquote(@title_key_sql), a.title),
      having: count(a.id) > 1,
      select: %{ids: fragment("array_agg(?::text ORDER BY ?)", a.id, a.inserted_at)}
    )
    |> heavy_all(tenant_id)
    |> Enum.map(fn %{ids: ids} -> {@title_drift, ids} end)
  end

  # A title match is not evidence of duplication, and this is the THIRD time that has bitten
  # this one function. The empty-key guard closed it for symbol-only titles; the placeholder
  # guard closed it for "Untitled Document"; the unicode-aware separator class closed it for
  # non-Latin titles collapsing onto incidental ASCII. Each fix removed one way for unrelated
  # articles to share a normalized key, and each left the underlying premise standing.
  #
  # Measured on the hosted corpus 2026-08-06, on the 290 groups that were one night away from
  # auto-unpublishing: three of them were not duplicates at all.
  #
  #   cos 0.56  "Changelog" / "CHANGELOG" / "ChangeLog"  -> a WordPress SEO plugin, the Elixir
  #                                                         oauth2 library, and a WordPress theme
  #   cos 0.64  "options" / "Options"                    -> Bootstrap-select vs the AtomJS mixin
  #   cos 0.68  "Whoever can spend the most ..."         -> two different write-ups
  #
  # None is a placeholder, none is empty, none is non-Latin: they are ordinary
  # filename-derived titles that unrelated sources happen to share. Every GENUINE duplicate in
  # that same set — all of it title-case drift — sat at 0.84 or above, so the two populations
  # do not overlap. Without this gate the pass would have unpublished the oauth2 changelog as
  # a duplicate of a WordPress theme's, and the two-run agreement gate would have confirmed it,
  # because the collision is deterministic and agreement only filters TRANSIENCE.
  #
  # So the gate stops patching the normalization and corroborates the CLAIM instead: a
  # title-drift group may only survive if its members are also similar in content. The
  # threshold sits in the empty band between the two measured populations.
  #
  # It applies to the TITLE signal only. `idempotency_drift_groups/1` matches on a key the
  # WRITER supplied for exactly this purpose, which is real evidence of one capture written
  # twice; a title is an accident of whatever the source file was called.
  #
  # FAILS CLOSED on missing evidence, and the withhold is SELF-CLEARING: an article with no
  # embedding at the active dimension (the corpus has had 80 such articles since June) drops
  # its whole group rather than letting it pass on a partial sample, and the missing vectors
  # are enqueued (`backfill_missing_embeddings/2`) so the next run can decide instead of
  # withholding the same group forever.
  # An IDEMPOTENCY-drift group is exempt. Its members collide on a key the WRITER supplied to
  # mark one capture, which is direct evidence of one capture written twice; a title is an
  # accident of whatever the source file happened to be called. Gating the idempotency signal
  # on vectors would also make the whole class depend on embeddings, and a tenant with no
  # embedding key (mandatory BYO) has none at all.
  #
  # Scored over the LIVE members, never the scan-time id set, so what is checked is the group
  # that would actually be unpublished.
  defp corroborated?(proposal, live, scored) do
    if title_drift?(proposal) do
      # Sorted so the entry a group resolves to is deterministic, and looked up by ANY live
      # member rather than by the smallest id: the batch is scored once over the union of
      # every confirmed proposal's SCAN-time ids, so the smallest member of THIS group may
      # have been unpublished by an earlier group in the same reduce.
      ids = live |> Enum.map(& &1.id) |> Enum.sort()
      judge_similarity(Enum.find_value(ids, &Map.get(scored, &1)), ids)
    else
      :ok
    end
  end

  # FAILS CLOSED on missing evidence, checked against THIS group's scored MEMBER set — never
  # against a pair COUNT, which was counted over the whole batch while the live ids are one
  # proposal's, so a shared article or a mid-run unpublish made the two denominators disagree
  # and rejected a genuine group. One unscored member withholds the whole group rather than
  # letting it be judged on the pairs that happen to carry vectors, which could be exactly the
  # two that genuinely match. Within one entry every embedded member is paired with every
  # other, so full member coverage IS full pair coverage; `min_sim` may span another
  # proposal's ids under the same title, which can only lower it.
  defp judge_similarity(nil, ids), do: {:withheld, nil, ids}

  defp judge_similarity(%{scored: scored_ids, min_sim: min_sim} = entry, ids) do
    case Enum.reject(ids, &MapSet.member?(scored_ids, &1)) do
      [] -> if min_sim >= min_duplicate_similarity(), do: :ok, else: {:withheld, entry, []}
      unscored -> {:withheld, entry, unscored}
    end
  end

  # The two withholds have different remedies, so they say different things: a low cosine is
  # a verdict, missing vectors are a gap this run just enqueued.
  defp log_uncorroborated(tenant_id, proposal, live, entry, unscored) do
    detail =
      case {entry, unscored} do
        {_entry, [_ | _] = missing} ->
          "#{length(missing)} member(s) unscored at the active dimension; backfill enqueued"

        {%{min_sim: sim, pairs: pairs}, []} ->
          "min cosine #{Float.round(sim, 4)} across #{pairs} scored pair(s), threshold " <>
            "#{min_duplicate_similarity()}"
      end

    Logger.warning(
      "Consolidation: tenant=#{tenant_id} WITHHELD duplicate_capture proposal " <>
        "##{proposal.number} from auto-apply — #{length(live)} live members share a " <>
        "normalized title but their bodies do not corroborate it (#{detail}). Reported, " <>
        "not applied. A shared title is not evidence of a duplicate capture."
    )
  end

  # The rationale is the only place the forming signal survives onto the persisted proposal
  # row, so both sites interpolate the phrase from the same attribute and the test is for the
  # EXEMPTION, never for the gate. A rationale this cannot classify (reworded, truncated,
  # non-binary) is GATED: a copy edit can only make this pass more conservative, never
  # silently turn off the one content check on the class that writes to `articles`.
  defp title_drift?(%{rationale: rationale}) when is_binary(rationale),
    do: not String.contains?(rationale, @idempotency_drift)

  defp title_drift?(_proposal), do: true

  # Restricted to the CANDIDATE ids, never the whole corpus: the self-join is over the few
  # hundred articles that already collided on a normalized title, so this adds a small join
  # rather than a second 79k-row scan.
  #
  # Keyed by EVERY scored member, so a caller can resolve its group from any live id it still
  # has. The grouping expression is the SAME normalized title that formed the group
  # (`@title_key_sql`, referenced from both sites so they cannot drift), and each entry
  # carries the member set it scored so the caller can tell a low cosine from a missing one.
  defp pairwise_similarity_by_group(_tenant_id, []), do: %{}

  defp pairwise_similarity_by_group(tenant_id, ids) do
    tenant_id
    |> title_pairs(ids)
    |> score_pairs(Embeddings.active_dimension(tenant_id))
    |> heavy_all(tenant_id)
    |> index_by_member()
  end

  defp title_pairs(tenant_id, ids) do
    from(a1 in published_base(tenant_id),
      # `a2` binds tenant_id to the PASSED tenant_id, not transitively to `a1`'s. HeavyRead
      # runs on a BYPASSRLS pool and its guard requires every base-table source to carry its
      # own conjunctive equality — a transitive one is not checkable by inspecting the query.
      # It carries the visibility guard for the same reason `a1` does (`shared_only/1`).
      join: a2 in Article,
      on:
        a2.tenant_id == ^tenant_id and a2.status == :published and a1.id < a2.id and
          shared_visibility(a2.metadata) and
          fragment(unquote(@title_key_sql <> " = " <> @title_key_sql), a1.title, a2.title),
      where: a1.id in ^ids and a2.id in ^ids
    )
  end

  defp score_pairs(query, dim) do
    from([a1, a2] in query,
      join: e1 in "article_embeddings",
      on: e1.article_id == a1.id and e1.dim == ^dim and e1.tenant_id == a1.tenant_id,
      join: e2 in "article_embeddings",
      on: e2.article_id == a2.id and e2.dim == ^dim and e2.tenant_id == a2.tenant_id,
      group_by: fragment(unquote(@title_key_sql), a1.title),
      select: %{
        min_sim: min(fragment("1 - (? <=> ?)", e1.embedding, e2.embedding)),
        pairs: count(a1.id),
        members:
          fragment("array_agg(DISTINCT ?::text) || array_agg(DISTINCT ?::text)", a1.id, a2.id)
      }
    )
  end

  defp index_by_member(rows) do
    rows
    |> Enum.flat_map(fn %{min_sim: sim, pairs: pairs, members: members} ->
      entry = %{min_sim: to_float(sim), pairs: pairs, scored: MapSet.new(members)}
      Enum.map(members, &{&1, entry})
    end)
    |> Map.new()
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(_other), do: -1.0

  # Live-tunable, because the band between the two populations is a property of a tenant's
  # corpus rather than of the algorithm. Clamped and type-checked for the same reason
  # `clamp_cap/3` is, in the other direction: a number sorts BELOW every atom and binary in
  # Erlang term order, so a `nil` or a `"0.8"` from a hand-rolled env read makes
  # `min_sim >= threshold` false for every pair on every night — title-drift auto-apply stops
  # permanently while the run still reports `gate: :open`. A value outside `0.0..1.0` is
  # equally inert (cosine cannot exceed 1).
  defp min_duplicate_similarity do
    :loopctl
    |> Application.get_env(
      :knowledge_consolidation_min_duplicate_similarity,
      @default_min_duplicate_similarity
    )
    |> clamp_similarity()
  end

  defp clamp_similarity(value) when is_float(value) or is_integer(value),
    do: value |> max(0.0) |> min(1.0) |> to_float()

  defp clamp_similarity(value) do
    Logger.warning(
      "Consolidation: ignoring non-numeric duplicate similarity threshold " <>
        "#{inspect(value)}; using #{@default_min_duplicate_similarity}."
    )

    @default_min_duplicate_similarity
  end

  # The same idempotency key written under two different tag FORMATS (#583) — the
  # normalized keys collide while the verbatim keys differ. Same Unicode-aware separator
  # class and same empty-key guard as `title_drift_groups/1`, for the same reasons.
  #
  # But NOT the same case handling, and the asymmetry is deliberate. A TITLE is prose, so
  # "Retry Policy" and "retry policy" are the same title written twice. An `idempotency_key`
  # is an OPAQUE token chosen by the writer, and case can be the only thing distinguishing
  # two of them — `session:AB12` and `session:ab12` are different keys, not one key under
  # format drift. Folding case here is therefore a collision rather than a normalization,
  # and this class now AUTO-APPLIES (#608): a deterministic false grouping is confirmed by
  # the two-run agreement gate on night two and the loser is unpublished. Separators and
  # punctuation are still stripped, which is the actual drift #583 described.
  defp idempotency_drift_groups(tenant_id) do
    from(a in published_base(tenant_id),
      where: not is_nil(a.idempotency_key),
      where:
        fragment(
          "btrim(regexp_replace(?, '[^[:alnum:]]+', ' ', 'g')) <> ''",
          a.idempotency_key
        ),
      group_by:
        fragment("btrim(regexp_replace(?, '[^[:alnum:]]+', ' ', 'g'))", a.idempotency_key),
      having: count(a.id) > 1 and count(a.idempotency_key, :distinct) > 1,
      select: %{ids: fragment("array_agg(?::text ORDER BY ?)", a.id, a.inserted_at)}
    )
    |> heavy_all(tenant_id)
    |> Enum.map(fn %{ids: ids} -> {@idempotency_drift, ids} end)
  end

  # `:contradiction_candidate` WAS a class here. It is not any more, and the reason is
  # ownership rather than value.
  #
  # `Loopctl.Workers.KnowledgeLintWorker.judge_redundant_conflicts/1` now resolves exactly
  # these pairs automatically, recording `classification: :redundant, disposition: :dismiss`
  # — capped ABOVE the promotion rate so the queue converges. Proposing them here as well
  # put two subsystems on one pile: one resolving it, the other re-reporting it nightly.
  # That is the "second scheduler over the same corpus" failure #584 named, arrived at from
  # the other direction.
  #
  # MEASURED on the hosted corpus 2026-08-05, in the run that settled this: of 16,340
  # proposals emitted, 15,588 were `:contradiction_candidate` — 95% of the report was a
  # re-derivation of the set the judge drains, truncated at the per-class cap and
  # re-derived identically the next night. The remaining classes (390 duplicate_capture,
  # 361 stale_entry — itself since retired — and 1 generic_title) are consolidation's actual
  # work and were being crowded out of the report by it.
  #
  # If a future change wants consolidation to own conflicts again, MOVE the judge here
  # rather than adding a second proposer: the invariant is one writer per pile, not one
  # location.

  # Same Unicode-aware normalization as the drift groups: under the ASCII-only class
  # "設計ドキュメント Draft" normalized to "draft" and was flagged as a placeholder title.
  # The ASCII-only `@generic_title_pattern` is anchored, so it still matches exactly the
  # placeholder titles against an `[[:alnum:]]`-normalized key.
  defp generic_titles(tenant_id, cap) do
    ids =
      from(a in published_base(tenant_id),
        where:
          fragment(
            "btrim(regexp_replace(lower(?), '[^[:alnum:]]+', ' ', 'g')) ~ ?",
            a.title,
            ^@generic_title_pattern
          ),
        order_by: [asc: a.inserted_at, asc: a.id],
        select: a.id
      )
      |> heavy_all(tenant_id)

    selected = Enum.take(ids, cap)
    evidence_by_id = evidence_map(tenant_id, selected)

    items =
      Enum.map(selected, fn id ->
        build_proposal(:generic_title, [id], evidence_by_id,
          severity: "warning",
          rationale:
            "The title is a placeholder. Placeholder titles collide on the per-tenant " <>
              "active-title uniqueness check and block hub creation with a 409.",
          suggested_action:
            "Retitle the article from its content (the excerpt below is its opening)."
        )
      end)

    {length(ids), items}
  end

  # `:stale_entry` WAS a class here. It is not any more, and the reason is that age is
  # not a defect signal.
  #
  # #605 settled that the class can never earn an apply path: "stale" is a time threshold,
  # and auto-archiving on age would silently delete the corpus, irreversibly. A class with
  # no reachable consumer is the queue-with-no-consumer shape this codebase has now been
  # bitten by four times — and #605's own rule for it is "do not create the queue", never
  # "auto-approve unvetted writes".
  #
  # Nothing is lost by removing it. `Knowledge.lint/2` computes stale articles itself and
  # publishes them on `GET /api/v1/knowledge/lint` (the `knowledge_lint` tool) with a
  # caller-chosen `stale_days`, which is strictly MORE than this class offered: consolidation
  # re-published lint's already-capped array under a fixed 90-day threshold. It was a second
  # rendering of one signal, occupying a per-class cap slot in the report that carries the
  # classes something can act on.
  #
  # MEASURED on the hosted corpus 2026-08-05: 361 stale entries, re-derived identically every
  # night, against zero recorded actions taken on any of them for the corpus's whole lifetime.
  #
  # This is why `analyze/2` takes no lint report any more. If a future change wants staleness
  # back in this pass, it needs a CORRECTNESS signal (contradicted by a newer article, source
  # URL gone, superseded) — not a longer threshold.

  # --- Proposal assembly ---

  defp build_proposal(class, article_ids, evidence_by_id, opts) do
    %{
      proposal_class: class,
      article_ids: article_ids,
      evidence: Enum.map(article_ids, &Map.get(evidence_by_id, &1, blank_evidence(&1))),
      rationale: Keyword.fetch!(opts, :rationale),
      suggested_action: Keyword.fetch!(opts, :suggested_action),
      severity: Keyword.fetch!(opts, :severity),
      fingerprint: fingerprint(class, article_ids)
    }
  end

  # Stable across runs: the class plus the sorted article-id set. Re-deriving the same
  # finding upserts the same row instead of duplicating it.
  defp fingerprint(class, article_ids) do
    payload = to_string(class) <> "|" <> Enum.join(Enum.sort(article_ids), ",")
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  # Every evidence entry carries the SAME key set, whichever branch produced it — the full
  # one from `evidence_map/2`, this blank, or a redaction. A caller reading
  # `entry["idempotency_key"]` should get `nil` for an unresolvable article, not a
  # KeyError-shaped absence that varies by which article in one response it asked about.
  defp blank_evidence(article_id) do
    %{
      "article_id" => article_id,
      "title" => nil,
      "idempotency_key" => nil,
      "excerpt" => ""
    }
  end

  # Bodies come straight from AdminRepo (never `Knowledge.get_article/3`, which records
  # a heat-counted read) and are truncated in SQL before they reach the VM. Bounded by a
  # concrete id list, so this is not an enumeration and stays off the heavy-read pool.
  #
  # PUBLISHED-scoped as defence in depth: this is the BODY-QUOTING path, and the whole
  # pass is documented to operate on the published corpus. An id that is not published
  # falls back to `blank_evidence/1` rather than persisting an archived article's excerpt
  # into `consolidation_proposals.evidence` and serving it from the API.
  defp evidence_map(_tenant_id, []), do: %{}

  defp evidence_map(tenant_id, article_ids) do
    ids = Enum.uniq(article_ids)

    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: a.status == :published,
      where: a.id in ^ids,
      select: %{
        id: a.id,
        title: a.title,
        idempotency_key: a.idempotency_key,
        body: fragment("left(?, ?)", a.body, ^@excerpt_source_chars)
      }
    )
    |> shared_only()
    |> AdminRepo.all()
    |> Map.new(fn row ->
      {row.id,
       %{
         "article_id" => row.id,
         "title" => row.title,
         "idempotency_key" => row.idempotency_key,
         "excerpt" => excerpt(row.body)
       }}
    end)
  end

  # Evidence is a COPY — title, idempotency key and a truncated body excerpt — taken
  # when the proposal was derived, and `article_ids` deliberately carries
  # no FK to `articles`. So nothing in the article lifecycle reaches into it: the
  # IRREVERSIBLE hard delete (`Knowledge.BulkOps`) removes the row, and archive removes it
  # from every other read surface, while the excerpt sits in
  # `consolidation_proposals.evidence` — and prior-day reports are addressable forever via
  # `?day=`, so the copy outlives the article indefinitely. This module states its own
  # motivation as keeping sensitive source material off the server; a hard delete that
  # does not remove the quoted body contradicts it.
  #
  # The copy is therefore RE-CHECKED at read time against the live corpus, and any entry
  # whose article no longer resolves is redacted down to its id. Read-time is the right
  # seam: it also covers the article that was archived after the pass ran, and it needs no
  # reaper for reports nobody reads.
  defp redact_stale_evidence(_tenant_id, []), do: []

  defp redact_stale_evidence(tenant_id, proposals) do
    live = live_evidence_ids(tenant_id, Enum.flat_map(proposals, & &1.article_ids))

    Enum.map(proposals, fn proposal ->
      %{proposal | evidence: Enum.map(proposal.evidence, &redact_entry(&1, live))}
    end)
  end

  defp redact_entry(%{"article_id" => id} = entry, live) do
    if MapSet.member?(live, id) do
      entry
    else
      %{
        "article_id" => id,
        "title" => nil,
        "idempotency_key" => nil,
        "excerpt" => "",
        "redacted" => true
      }
    end
  end

  defp redact_entry(entry, _live), do: entry

  # Liveness for redaction is "the article still exists and is recoverable" — NOT "still
  # published". A draft counts: the only write this pass makes is the reversible unpublish,
  # so scoping this to `:published` made the pass redact the evidence for its own decision,
  # erasing the quoted excerpt that says WHY the article was unpublished on the morning an
  # operator goes looking for it. Archive and hard delete are the one-way doors this
  # redaction exists for, and they still redact.
  #
  # `shared_only/1` is composed here for the same reason it is composed into the three scan
  # predicates: an article that turned private AFTER the scan is a readability change, and
  # without it a quoted body kept being served to any orchestrator key from a prior-day
  # report forever. Turning private redacts exactly like archiving.
  defp live_evidence_ids(_tenant_id, []), do: MapSet.new()

  defp live_evidence_ids(tenant_id, article_ids) do
    ids = Enum.uniq(article_ids)

    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: a.status != :archived,
      where: a.id in ^ids,
      select: a.id
    )
    |> shared_only()
    |> AdminRepo.all()
    |> MapSet.new()
  end

  defp excerpt(nil), do: ""

  defp excerpt(body) do
    normalized = body |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(normalized) > @excerpt_chars do
      String.slice(normalized, 0, @excerpt_chars) <> "…"
    else
      normalized
    end
  end

  # --- Persistence (the ONLY writes this module makes) ---

  defp upsert_report(tenant_id, day, analysis) do
    summary = analysis.summary

    %ConsolidationReport{tenant_id: tenant_id}
    |> ConsolidationReport.changeset(%{
      day: day,
      generated_at: summary.generated_at,
      corpus_size: summary.corpus_size,
      proposal_count: summary.total_proposals,
      persisted_count: summary.emitted,
      proposals_by_class: summary.by_class,
      truncated: summary.truncated,
      max_per_class: summary.max_per_class
    })
    |> AdminRepo.insert!(
      on_conflict:
        {:replace,
         [
           :generated_at,
           :corpus_size,
           :proposal_count,
           :persisted_count,
           :proposals_by_class,
           :truncated,
           :max_per_class,
           :updated_at
         ]},
      conflict_target: [:tenant_id, :day],
      returning: true
    )
  end

  # A proposal the machine no longer derives is withdrawn, not left standing.
  defp prune_proposals(report_id, proposals) do
    keep = Enum.map(proposals, & &1.fingerprint)

    from(p in ConsolidationProposal,
      where: p.report_id == ^report_id,
      where: p.fingerprint not in ^keep
    )
    |> AdminRepo.delete_all()
  end

  # The review-state reset lives HERE, in the same on_conflict clause that refreshes
  # the machine-derived columns: a re-derived proposal is a new claim and must be
  # reviewed again, with no earlier human's name carried onto it.
  defp upsert_proposal(tenant_id, report_id, proposal) do
    %ConsolidationProposal{tenant_id: tenant_id}
    |> ConsolidationProposal.changeset(%{
      report_id: report_id,
      number: proposal.number,
      proposal_class: proposal.proposal_class,
      article_ids: proposal.article_ids,
      evidence: proposal.evidence,
      rationale: proposal.rationale,
      suggested_action: proposal.suggested_action,
      severity: proposal.severity,
      fingerprint: proposal.fingerprint,
      review_status: :pending,
      reviewed_by: nil,
      reviewed_at: nil
    })
    |> AdminRepo.insert!(
      on_conflict:
        {:replace,
         [
           :number,
           :proposal_class,
           :article_ids,
           :evidence,
           :rationale,
           :suggested_action,
           :severity,
           :review_status,
           :reviewed_by,
           :reviewed_at,
           :updated_at
         ]},
      conflict_target: [:report_id, :fingerprint]
    )
  end

  # Over-cap is never a silent drop: the class, the cap, and the TRUE total are logged.
  #
  # The message must NOT promise the remainder next run. Every class derives its
  # selection deterministically (the drift groups by article-id set, the conflict pairs by
  # sorted id, the placeholder titles oldest-first) and the pass consumes nothing, so a
  # re-run re-derives the SAME leading N. The overflow surfaces only as the emitted
  # proposals stop being derived — i.e. once they are actioned at the source.
  defp log_truncation(tenant_id, summary) do
    Enum.each(summary.truncated, fn
      {class, true} ->
        Logger.warning(
          "Consolidation: tenant=#{tenant_id} class=#{class} has " <>
            "#{Map.fetch!(summary.by_class, class)} proposals; emitting " <>
            "#{summary.max_per_class} this run (cap=max_per_class). The remainder stays " <>
            "hidden until these are actioned at the source — a re-run re-derives the same " <>
            "leading #{summary.max_per_class}."
        )

      {_class, false} ->
        :ok
    end)
  end

  defp fetch_report(tenant_id, nil) do
    from(r in ConsolidationReport,
      where: r.tenant_id == ^tenant_id,
      order_by: [desc: r.day],
      limit: 1
    )
    |> AdminRepo.one()
  end

  defp fetch_report(tenant_id, %Date{} = day) do
    AdminRepo.get_by(ConsolidationReport, tenant_id: tenant_id, day: day)
  end
end
