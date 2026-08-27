defmodule Loopctl.Knowledge.Consolidation do
  @moduledoc """
  The nightly consolidation ("dream") pass over a tenant's PUBLISHED corpus (#584, #605).

  It REPORTS on two defect classes and APPLIES both, each with the write its own
  reversibility licenses and neither without two consecutive runs agreeing:
  `:duplicate_capture` as `unpublish` (`apply_confirmed_duplicates/2`), `:generic_title` as a
  retitle from the article's own content, with the previous title recorded on the article's
  own `previous_title` COLUMN — where a caller `PATCH` cannot erase it, unlike `metadata`
  (`apply_confirmed_generic_titles/2`). Those two functions carry the whole safety model
  between them.

  `:generic_title` was report-only until it was not: it was re-derived every night for weeks
  with nothing on the other end, which is the queue-with-no-consumer shape #605 names and
  this pass keeps re-finding. A class earns an automatic consumer by being REVERSIBLE — not
  by being confident, and not by finding a human to approve it.

  The pass reconciles the corpus and emits NUMBERED proposals, each naming the
  articles involved and carrying a QUOTED excerpt from each as evidence. It writes
  its findings to `consolidation_reports` / `consolidation_proposals`. The only other
  writes it can make are the two confirmed applies above — an `unpublish`, and a `title`
  (plus that article's regenerated `slug`, its `previous_title` undo record, and one
  provenance marker on its metadata); it never writes
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

  Both are applied by `Loopctl.Workers.KnowledgeLintWorker`'s nightly run, in that order.

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
  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Embeddings
  alias Loopctl.Embeddings.ShrinkLadder
  alias Loopctl.ExitTag
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ConsolidationProposal
  alias Loopctl.Knowledge.ConsolidationReport
  alias Loopctl.Knowledge.ContentExtractorRouter
  alias Loopctl.Llm
  alias Loopctl.SystemConfig
  alias Loopctl.Workers.BatchArticleEmbeddingWorker

  @default_max_per_class 100
  @hard_max_per_class 500

  # The most members one duplicate group may carry onto a proposal (#617). See
  # `cap_members/1` for why truncating is safe and why it must be deterministic.
  @max_group_members 50
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

  # The SAME pattern, compiled once for the apply-time re-check (`title_group_key/1`),
  # which runs in Elixir rather than in Postgres. Anchors, alternation and `[0-9]+` mean
  # exactly the same thing in POSIX ERE and in PCRE, so the two evaluations agree; it is
  # derived from the one string above so they cannot drift.
  @generic_title_regex Regex.compile!(@generic_title_pattern)
  # The heavy-read endpoint every whole-corpus enumeration in this module runs under.
  @heavy_endpoint :consolidation

  # The normalized-title grouping key, in ONE place. `title_drift_groups/1` forms groups with
  # it and `pairwise_similarity_by_group/2` re-derives the same groups to score them; if the
  # two ever disagreed the gate would score the wrong sets and silently pass collisions.
  @title_key_sql "btrim(regexp_replace(lower(?), '[^[:alnum:]]+', ' ', 'g'))"

  # The idempotency-key twin, referenced by `idempotency_drift_groups/1` (which DERIVES the
  # groups) and by `still_colliding/5` (which RE-CHECKS them at apply time) so the two cannot
  # drift apart — the same pinning `@title_key_sql` gets, for the same reason. Deliberately
  # NOT `lower()`-ed: an `idempotency_key` is an opaque writer-chosen token where case can be
  # the only thing separating two of them, so folding it is a collision, not a normalization.
  @idempotency_key_sql "btrim(regexp_replace(?, '[^[:alnum:]]+', ' ', 'g'))"

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

  # How many confirmed PLACEHOLDER TITLES one nightly run may offer to the retitle step.
  # This bounds the candidate QUERY, not the step: each item costs an outbound LLM call, so
  # the bound that actually holds is the wall clock below (#761 — a count caps attempts and
  # says nothing about what they cost). Clamped exactly like the two apply caps, with `0`
  # honoured as an explicit operator PAUSE (`gate: :drain_disabled`) — and a pause matters
  # more here than on the unpublish drain, because this is the one nightly step that spends
  # a tenant's provider budget.
  @default_max_retitles 25
  @hard_max_retitles 500

  # Fallback wall clock for the retitle step. `Loopctl.Workers.KnowledgeLintWorker` always
  # passes `:budget_ms` — the time ITS job has left (`retitle_budget_remaining/1`) — so this
  # applies only to a direct call. It is deliberately not larger than the reserve the worker
  # carves out for this step; `test/loopctl/workers/knowledge_lint_worker_test.exs` binds the
  # two so they cannot drift into a budget bigger than the job containing it.
  @default_retitle_budget_ms :timer.minutes(2)

  # Bytes of body handed to the extractor to derive a title from. Fetched pre-truncated in
  # SQL, like `@excerpt_source_chars`, so this path cannot pull a 100 KB body per article —
  # and because every one of these bytes LEAVES for the provider, a smaller prefix is a
  # smaller egress. An opening 4 KB is what the title has to be derivable from; if it is not,
  # the step abstains, which is the intended outcome rather than a loss.
  @title_source_chars 4_000

  # `articles.title` is validated at 500 characters, so a longer generation is rejected by
  # the changeset anyway; refusing it here makes the abstention legible instead of arriving
  # as a write failure.
  @max_generated_title_chars 500

  # The classes `analyze/2` still PRODUCES, in the order proposals are numbered in. Distinct
  # from `ConsolidationProposal.classes()`, which is the schema enum and additionally carries
  # the retired values so historical rows load. Assembly iterates THIS list.
  @live_classes [:duplicate_capture, :generic_title]

  # How far apart the two agreeing reports may be, in days. One night's gap is normal (a
  # skipped run); anything wider is not the "two consecutive runs" the gate advertises.
  @max_confirmation_gap 2

  # The signal that formed a duplicate group survives onto the persisted proposal ONLY inside
  # the rationale prose, so the sentence (`duplicate_captures/2`) and the apply-time
  # classifier (`drift_signal/1`) both interpolate the phrase from HERE. They used to be a
  # sentence and a substring literal that nothing pinned together — a copy edit would have
  # turned the one content check on the auto-applying class off without failing anything.
  @title_drift "title drift"
  @idempotency_drift "idempotency-tag drift"

  # Default corroboration threshold, and the fallback for a config value that is not a number
  # in `0.0..1.0`. Measured band on the hosted corpus 2026-08-06: collisions at/below 0.68,
  # genuine duplicates at/above 0.84.
  @default_min_duplicate_similarity 0.80

  # The percent knob's DB key, named once because both the read and its documentation
  # refer to it. Absence is answered by `SystemConfig.fetch_int/1` (`:error`), NOT by a
  # sentinel default: a sentinel makes a row STORING that value indistinguishable from no
  # row at all, so an operator who set `-1` silently got the app-layer threshold while the
  # log said nothing.
  @min_similarity_pct_key "knowledge_consolidation_min_duplicate_similarity_pct"

  # What a threshold at or above 1.0 resolves to. Cosine similarity cannot exceed 1.0, so
  # this is "no pair may ever corroborate" — an operator hard-disabling the auto-applying
  # class, honoured as written instead of quietly replaced by the default.
  @disabled_similarity 2.0

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

  @doc "Default cap on placeholder-title articles one run may offer to the retitle step."
  @spec default_max_retitles() :: pos_integer()
  def default_max_retitles, do: @default_max_retitles

  @doc "Fallback wall-clock budget (ms) for the retitle step when no `:budget_ms` is given."
  @spec default_retitle_budget_ms() :: pos_integer()
  def default_retitle_budget_ms, do: @default_retitle_budget_ms

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
    cap = clamp_per_class(Keyword.get(opts, :max_per_class, @default_max_per_class))

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

    by_class = Map.new(found, fn {class, {total, _items, _cut}} -> {to_string(class), total} end)

    # `truncated` answers "did this class see the whole picture", so MEMBER truncation
    # (`cap_members/1`, which drops members from inside a group without changing either
    # count) has to flip it too. Group-level `total > length(items)` alone reported `false`
    # while a proposal silently omitted members and its evidence array came up short.
    truncated =
      Map.new(found, fn {class, {total, items, members_cut}} ->
        {to_string(class), total > length(items) or members_cut}
      end)

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
        prune_proposals(tenant_id, report.id, analysis.proposals)
        Enum.each(analysis.proposals, &upsert_proposal(tenant_id, report.id, &1))
        report
      end)

    {:ok, report}
  end

  @doc """
  Applies the `:duplicate_capture` proposals that TWO consecutive runs agree on.

  The only class this pass applies by itself, and the only action it will take: keep the
  OLDEST article of a duplicate group and UNPUBLISH every later one. Age, not length, is
  the winner rule — see `apply_live_group/4` for why (age is the one input a later writer
  cannot manufacture).

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

  The COLLISION is re-derived here too (`still_colliding/5`): the grouping signal that
  FORMED the group — normalized title, or normalized idempotency key — is recomputed over
  the live rows, and a group that has dissolved, split, or lost any live member to another
  key is skipped WHOLE rather than applied to what is left. The two-run agreement gate
  still runs in front of it (which is why the worker calls this only after tonight's report
  was written, `Loopctl.Workers.KnowledgeLintWorker`), but agreement confirms a specific id
  set; it cannot notice that a human retitled three of the five members this morning.
  ## What a collision must additionally clear

  Agreement filters transience, not wrongness. A title two unrelated sources share collides
  deterministically, so both runs agree; and an `idempotency_key` is caller-supplied data,
  so two writers can collide on one deterministically too. EVERY group — whichever signal
  formed it — is therefore applied only when its live members also corroborate in CONTENT:
  every member scored wherever this tenant's vectors live (`score_source/1`), under the same
  normalized key that formed the group, worst pair at or above
  `#{@default_min_duplicate_similarity}` (tunable). One that cannot is REPORTED, counted in
  `uncorroborated`, and has its missing vectors enqueued so the withhold clears itself; a
  group withheld because the scoring READ failed enqueues nothing (`corroborated?/3`).
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
      log_gate_blocked(tenant_id, :duplicate_capture, :drain_disabled)
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

  # The READ cap's twin of `clamp_cap/3`, and it needs the same type check for the same
  # reason (#617). `analyze/2` used to pipe the raw opt through `max(1) |> min(hard)`,
  # but a number sorts BELOW every atom and binary in Erlang term order — so a `nil`, an
  # `:all`, or a `"100"` from a hand-rolled config read survived `max(1)` and came out of
  # `min/2` as `@hard_max_per_class`. A malformed value resolved to the LARGEST blast
  # radius available; a typo silently bought five times the intended report. It now falls
  # back to the default and says so, exactly like the apply caps.
  #
  # The floor is 1 rather than `clamp_cap/3`'s 0 because this is the pure-read derivation:
  # `0` here means "emit no proposals at all", which is not a pause an operator can
  # meaningfully want from a report, whereas `0` on an APPLY cap is a real mid-incident
  # halt.
  defp clamp_per_class(value) when is_integer(value),
    do: value |> max(1) |> min(@hard_max_per_class)

  defp clamp_per_class(value) do
    Logger.warning(
      "Consolidation: ignoring non-integer :max_per_class #{inspect(value)}; using " <>
        "#{@default_max_per_class}."
    )

    @default_max_per_class
  end

  defp run_confirmed_duplicates(tenant_id, cap, unpublish_cap) do
    case confirmed_proposals(tenant_id, :duplicate_capture, cap) do
      {:error, reason} ->
        log_gate_blocked(tenant_id, :duplicate_capture, reason)
        %{applied: 0, skipped: 0, failed: 0, uncorroborated: 0, gate: reason}

      {:ok, proposals} ->
        # Scored ONCE for the whole batch, then consulted per group AFTER its liveness
        # re-check — so a group that dissolved between the scan and now still reports
        # `skipped` (the accurate reason) rather than being relabelled uncorroborated.
        scored = score_groups(tenant_id, proposals)

        result =
          proposals
          |> Enum.reduce(
            %{applied: 0, skipped: 0, failed: 0, uncorroborated: 0, gate: :open},
            &tally_apply(tenant_id, &1, &2, unpublish_cap, scored)
          )

        log_permanent_withhold(tenant_id, result)
        result
    end
  end

  # ONCE PER RUN, not once per withheld proposal. A tenant with no BYO embedding key has
  # no vectors AT ALL, so every confirmed group withholds for missing evidence — emitting
  # this from the per-group backfill path meant one identical sentence per proposal, and a
  # tenant with a standing backlog buried its own nightly log under a message that says
  # the same thing every time. The trigger is unchanged: something must actually have been
  # withheld. Self-guarded for the same reason the backfill path is — this runs AFTER the
  # per-group rescue, so a repo blip while reading the tenant's LLM settings must not
  # discard a completed run's tally.
  defp log_permanent_withhold(tenant_id, %{uncorroborated: withheld}) when withheld > 0 do
    if Llm.has_embedding_key?(tenant_id) do
      :ok
    else
      # WARNING, not info: once per run this is not noise, and it is the one line that
      # explains why a tenant's auto-apply drain reports `gate: :open` and never moves. At
      # info it sat below the level a deployment actually reads.
      Logger.warning(
        "Consolidation: tenant=#{tenant_id} has no embedding key (mandatory BYO), so its " <>
          "#{withheld} withheld duplicate_capture group(s) can never be corroborated and " <>
          "stay withheld permanently — BOTH signals, since an idempotency_key is " <>
          "caller-supplied and corroborates nothing on its own. No backfill was enqueued: " <>
          "this is a configuration state, not a transient gap. Nothing is unpublished " <>
          "while withheld."
      )
    end

    :ok
  rescue
    _e -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp log_permanent_withhold(_tenant_id, _result), do: :ok

  # The ONLY heavy read on the apply path, and it runs BEFORE the reduce — so a statement
  # timeout or a `HeavyRead` shed would escape past `tally_apply/5`'s per-group rescue and
  # cost the whole night's drain, deterministically, every night. A failure degrades to
  # `:unavailable` instead, which withholds every group one by one (fail-closed, counted in
  # `uncorroborated`) rather than raising out of the run.
  #
  # `:unavailable` is NOT an empty score map, and the distinction is the whole point: an
  # empty map says "these members have no vectors", which routes the group into
  # `backfill_missing_embeddings/2` — so a shed on this read would answer a DB outage by
  # enqueueing an embedding job per member of every confirmed group, against the same
  # degraded database, and log it as missing vectors.
  #
  # Scored per SIGNAL, in separate queries. The two classes group under different keys
  # (normalized title vs normalized idempotency key), and a pair query grouped by the wrong
  # one scores the wrong sets: an idempotency group's members usually have DIFFERENT titles,
  # so under the title key each would sit alone, produce no pair, and withhold forever.
  #
  # Each id appears ONCE per query, and `pair_candidates/3` binds the list TWICE
  # (`a1.id in ^ids and a2.id in ^ids`) — so an undeduplicated list approaches Postgres's
  # 65,535 bind-parameter limit, where a Postgrex encode failure is rescued into
  # `:unavailable` and withholds EVERY group for that tenant, deterministically, every
  # night.
  # CHUNKED over the proposals, because neither the bind count nor the self-join width may
  # scale with the apply cap: at `max_applies: 500` groups x 50 members an unchunked list
  # is ~50,000 bind parameters against that ceiling — and the whole thing runs inside a 10s
  # statement timeout whose failure rescues to `:unavailable`. Raising the cap to drain a
  # backlog faster is exactly what would trip it, so the failure would arrive precisely when
  # the pass was asked to do more work.
  #
  # Chunking by GROUP rather than by id keeps each query's pairs whole: a group split
  # across two queries would have its members scored against different pools, and
  # `min_sim` is a per-group minimum. The merged map is keyed by `{signal, member id}`, and
  # a member shared between groups of the SAME signal resolves to the same entry either way.
  @score_groups_per_query 25

  defp score_groups(tenant_id, proposals) do
    proposals
    |> Enum.group_by(&drift_signal/1)
    |> Enum.reduce(%{}, fn {signal, class_proposals}, acc ->
      Map.merge(acc, score_signal(tenant_id, signal, class_proposals))
    end)
  rescue
    e -> log_scoring_failed(tenant_id, ExitTag.tag(e))
  catch
    :exit, reason -> log_scoring_failed(tenant_id, "exit:" <> ExitTag.tag(reason))
  end

  defp score_signal(tenant_id, signal, proposals) do
    proposals
    |> Enum.chunk_every(@score_groups_per_query)
    |> Enum.reduce(%{}, fn chunk, acc ->
      ids = chunk |> Enum.flat_map(& &1.article_ids) |> Enum.uniq()

      Map.merge(acc, pairwise_similarity_by_group(tenant_id, ids, signal))
    end)
  end

  defp log_scoring_failed(tenant_id, tag) do
    Logger.error(
      "Consolidation: tenant=#{tenant_id} duplicate similarity scoring failed (#{tag}); " <>
        "every duplicate group is withheld this run."
    )

    :unavailable
  end

  # "The gate was shut" and "the gate was open and confirmed nothing" both used to return an
  # empty list, so `applied: 0, skipped: 0` in the audit event was byte-identical for a fresh
  # install, a tenant mid-outage, and a genuinely clean corpus. The reason tag is what lets an
  # auditor tell a quiet night from a blocked one without reading the reports table.
  defp log_gate_blocked(tenant_id, class, reason) do
    Logger.info(
      "Consolidation: tenant=#{tenant_id} #{class} apply gate CLOSED (#{reason}); " <>
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
  # CLASS-PARAMETERIZED, and shared by both applying classes (`:duplicate_capture` and
  # `:generic_title`). One gate, one window, one vocabulary — a second copy would be free to
  # drift into a different definition of "two consecutive runs agreed", which is the only
  # thing standing in for the human approver that does not exist.
  defp confirmed_proposals(tenant_id, class, cap) do
    case recent_reports(tenant_id) do
      [newest, previous] ->
        if Date.diff(newest.day, previous.day) <= @max_confirmation_gap do
          {:ok, confirmed_against(tenant_id, class, newest, previous, cap)}
        else
          {:error, :report_gap}
        end

      _fewer_than_two_reports ->
        # First ever run, or only one report so far: nothing has been confirmed twice, so
        # nothing applies. The pass is silent rather than eager on a fresh install.
        {:error, :insufficient_history}
    end
  end

  defp confirmed_against(tenant_id, class, newest, previous, cap) do
    previous_fingerprints =
      from(p in ConsolidationProposal,
        where: p.tenant_id == ^tenant_id and p.report_id == ^previous.id,
        where: p.proposal_class == ^class,
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
      where: p.proposal_class == ^class,
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
          inserted_at: a.inserted_at,
          title_key: fragment(unquote(@title_key_sql), a.title),
          idempotency_key: a.idempotency_key,
          idempotency_key_norm: fragment(unquote(@idempotency_key_sql), a.idempotency_key)
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
      still_colliding(tenant_id, proposal, live, budget, scored)
    end
  end

  # The group must still be a group ON ITS OWN GROUNDS, not merely alive (#617).
  #
  # The liveness re-check above proves every member is still published; it does NOT prove
  # they still collide. A proposal persists across nights, and the ONE remedy a human has
  # for a false grouping is to retitle the articles — which is exactly what was done to 23
  # articles on 2026-08-06 to stop three unrelated `Changelog` documents being auto-
  # unpublished. Those articles were all still live, so liveness alone would have applied
  # the stale group on grounds that no longer existed. It was saved only because a fresh
  # derivation drops the group before it reaches apply, i.e. by a step OUTSIDE this
  # function. That is a correct outcome resting on an accident of ordering, so the
  # premise is now re-checked where it is used.
  #
  # A group that no longer collides AS ONE WHOLE is skipped, not applied to what survives.
  # Not just a SPLIT (two keys of >= 2): a group of five whose members were retitled down
  # to two is a two-member group nothing has ever confirmed — the two-run gate agreed on
  # the five-id fingerprint — and applying it completes a partial human remedy the same
  # night the remedy was made. So the surviving subgroup must be the WHOLE live set;
  # anything less is re-derived fresh and re-confirmed over two nights, which is cheap and
  # is the only thing that produces a fingerprint matching what the group now is.
  #
  # And the live set must itself be the whole confirmed set, MINUS only what this pass
  # retired. Retitling SPLITS a group, so the subgroup check catches it; archiving a
  # member, deleting it or marking it private SHRINKS the group without splitting it, and
  # the survivors still share one title — so comparing the subgroup against `live` alone
  # would apply a two-member fingerprint no report ever carried, on the night an operator
  # remedied the group by hiding its members.
  #
  # The one shrink that is NOT that is this pass's own part-drain (#614): `unpublish` is
  # the only write it makes, so a member it retired is a still-shared DRAFT, and the group
  # left behind is winner-plus-leftovers — the same group converging on the outcome that
  # WAS confirmed. `drained_by_this_pass?/2` is what tells the two apart.
  #
  # The predicate re-checked is the one that FORMED the group — `drift_signal/1` is the same
  # classifier `corroborated?/3` scores under, so the two cannot disagree about what a group
  # is. Re-checking titles on an idempotency-drift group would reject every one of them:
  # those members collide on a writer-supplied key and have no reason to share a title.
  defp still_colliding(tenant_id, proposal, live, budget, scored) do
    {signal, key_fun} =
      case drift_signal(proposal) do
        :title -> {"normalized title", &title_group_key/1}
        :idempotency -> {"normalized idempotency key", &idempotency_group_key/1}
      end

    confirmed = Enum.uniq(proposal.article_ids)

    case colliding_subgroups(live, key_fun) do
      [members] when length(members) == length(live) ->
        whole_group(tenant_id, proposal, members, confirmed, {budget, scored})

      other ->
        log_dissolved(tenant_id, proposal, live, other, signal)
        :skip
    end
  end

  defp whole_group(tenant_id, proposal, live, confirmed, {budget, scored}) do
    departed = confirmed -- Enum.map(live, & &1.id)

    if departed == [] or drained_by_this_pass?(tenant_id, departed) do
      corroborate(tenant_id, proposal, live, budget, scored)
    else
      log_shrunk(tenant_id, proposal, live, departed)
      :skip
    end
  end

  # Every departed member is a still-shared DRAFT, i.e. exactly what this pass's own
  # `unpublish` leaves behind. An archived, deleted or now-private member is a shrink by a
  # hand that never confirmed the smaller group, so the remainder is re-derived instead.
  defp drained_by_this_pass?(tenant_id, ids) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id and a.id in ^ids and a.status == :draft
    )
    |> shared_only()
    |> AdminRepo.aggregate(:count)
    |> Kernel.==(length(ids))
  end

  defp log_shrunk(tenant_id, proposal, live, departed) do
    Logger.info(
      "Consolidation: tenant=#{tenant_id} skipped duplicate_capture proposal " <>
        "##{proposal.number} — #{length(departed)} confirmed member(s) left the group by " <>
        "something other than this pass's own unpublish (archived, deleted or made " <>
        "private), so its #{length(live)} survivor(s) are a group nothing has confirmed. " <>
        "The next scan re-derives what is left and the two-run gate re-confirms it."
    )
  end

  # Members still sharing one normalized key, in subgroups of at least two. A member whose
  # key no longer qualifies at all (blank, or — for titles — a placeholder) is dropped
  # BEFORE grouping, mirroring the deriving query's `where`: it is no longer a member the
  # scan would find, and the caller then sees a subgroup shorter than `live` and skips.
  #
  # The idempotency derivation's other `having` term — `count(idempotency_key, :distinct)
  # > 1` — is deliberately NOT re-checked. It is a condition on the WHOLE group, and
  # `cap_members/1` may hand this only the oldest 50, so re-evaluating it here asks a
  # different question and could answer "no" forever for a group the derivation keeps
  # re-deriving. It is also structurally guaranteed: `articles_tenant_idempotency_key_idx`
  # is UNIQUE on `(tenant_id, idempotency_key)`, so two live members of one tenant cannot
  # carry the byte-identical key and distinctness follows from there being two of them.
  defp colliding_subgroups(live, key_fun) do
    live
    |> Enum.reject(&(key_fun.(&1) == :ineligible))
    |> Enum.group_by(key_fun)
    |> Map.values()
    |> Enum.filter(&(length(&1) > 1))
  end

  # `:ineligible` for anything `title_drift_groups/1`'s `where` would have excluded — a key
  # that normalizes to nothing, and a PLACEHOLDER title. Placeholders are excluded there
  # because "Draft"/"Untitled" collide with each other for reasons that have nothing to do
  # with being the same capture; `generic_titles/2` is the class that owns them. Without
  # this, a group retitled to two placeholders would re-collide here and auto-unpublish on
  # a signal the scan deliberately refuses to raise.
  defp title_group_key(%{title_key: key}) when is_binary(key) do
    cond do
      String.trim(key) == "" -> :ineligible
      Regex.match?(@generic_title_regex, key) -> :ineligible
      true -> key
    end
  end

  defp title_group_key(_member), do: :ineligible

  # `idempotency_drift_groups/1` requires a non-nil key that does not normalize to the
  # empty string. Without this, every member whose key was cleared since the scan would
  # share the `nil` key and re-form a "group" out of articles that now have no idempotency
  # signal at all.
  defp idempotency_group_key(%{idempotency_key: nil}), do: :ineligible

  defp idempotency_group_key(%{idempotency_key_norm: key}) when is_binary(key) do
    if String.trim(key) == "", do: :ineligible, else: key
  end

  defp idempotency_group_key(_member), do: :ineligible

  defp corroborate(tenant_id, proposal, live, budget, scored) do
    case corroborated?(proposal, live, scored) do
      :ok ->
        apply_live_group(tenant_id, proposal, live, budget)

      {:withheld, entry, unscored} ->
        log_uncorroborated(tenant_id, proposal, live, entry, unscored)
        backfill_missing_embeddings(tenant_id, unscored)
        :uncorroborated
    end
  end

  # NAMES the signal that was actually re-checked. This log line is the only surface that
  # explains a skip, and an idempotency-drift group whose members never had to share a
  # title would send the operator to inspect (and retitle) the wrong column entirely.
  defp log_dissolved(tenant_id, proposal, live, surviving, signal) do
    Logger.info(
      "Consolidation: tenant=#{tenant_id} skipped duplicate_capture proposal " <>
        "##{proposal.number} — its #{length(live)} live member(s) no longer share one " <>
        "#{signal} as one group (#{length(surviving)} colliding subgroup(s), " <>
        "#{surviving |> List.flatten() |> length()} member(s)). Something changed since it " <>
        "was proposed; the next scan re-derives what is left, and the two-run gate " <>
        "re-confirms it before anything is unpublished."
    )
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
    # An article whose stored vector is a PREFIX is unscored on purpose — `score_pairs/2`
    # excludes truncation-marked rows so a prefix is never compared against a whole text.
    # It is NOT backfillable, and enqueueing it was a no-op loop I created in #617:
    # `BatchArticleEmbeddingWorker` compares through `ShrinkLadder.whole_hash/1`, so a
    # marked row reads as ALREADY EMBEDDED and the job returns without doing anything.
    # The gap therefore never closed, the group withheld on every subsequent night, and
    # the pass re-enqueued the same dead jobs forever — a producer with no consumer, the
    # exact shape #605 named and this pass keeps re-finding.
    #
    # Re-embedding would not help either: the text is over the provider's limit, which is
    # why it is a prefix. So the correct handling is to stop pretending it is a gap.
    # A tenant with no BYO embedding key can NEVER satisfy this gate: every backfill job
    # it enqueues is discarded `{:no_embedding_key, _}` on pickup, so the duplicate class
    # withholds on every run forever while looking transient in the log ("backfill
    # enqueued") — a drain converging to a floor, and nightly Oban churn to go with it.
    # Enqueue nothing; `log_permanent_withhold/2` says so once per RUN.
    if Llm.has_embedding_key?(tenant_id) do
      backfill_embeddable(tenant_id, ids)
    else
      :ok
    end
  rescue
    # EVERY read on this path is guarded, not just the enqueue. The group has ALREADY been
    # decided uncorroborated when we get here — a withhold is a normal, correct outcome —
    # so a repo fault while looking up the tenant's embedding key or its stored hashes must
    # not escape into `tally_apply/5`'s rescue, which would report the group as `failed`:
    # a WRITE that could not be made, counted in loser articles, for a night on which no
    # write was ever going to be attempted. The withhold stands and the backfill is retried
    # next run.
    e -> log_backfill_failed(tenant_id, ExitTag.tag(e))
  catch
    :exit, reason -> log_backfill_failed(tenant_id, "exit:" <> ExitTag.tag(reason))
  end

  defp backfill_embeddable(tenant_id, ids) do
    {prefix, missing} = split_prefix_embedded(tenant_id, ids)

    if prefix != [] do
      Logger.info(
        "Consolidation: tenant=#{tenant_id} #{length(prefix)} withheld member(s) carry a " <>
          "PREFIX embedding (input over the provider limit), which cannot corroborate a " <>
          "key collision and cannot be backfilled. Not enqueued; the group stays withheld " <>
          "until the article is shortened or split."
      )
    end

    enqueue_backfill(tenant_id, missing)
  end

  # Which of `ids` already carry a truncation-MARKED hash, read the same way every
  # idempotency guard on this surface reads it: the side table at the active dimension
  # when the tenant writes there, the legacy column otherwise.
  defp split_prefix_embedded(tenant_id, ids) do
    hashes =
      if Embeddings.use_side_table_hash?(tenant_id) do
        Embeddings.article_embedded_hashes(tenant_id, ids, Embeddings.active_dimension(tenant_id))
      else
        legacy_hashes(tenant_id, ids)
      end

    Enum.split_with(ids, &ShrinkLadder.truncated_hash?(Map.get(hashes, &1)))
  end

  defp legacy_hashes(tenant_id, ids) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: a.id in ^ids,
      select: {a.id, a.embedding_content_hash}
    )
    |> AdminRepo.all()
    |> Map.new()
  end

  defp enqueue_backfill(_tenant_id, []), do: :ok

  defp enqueue_backfill(tenant_id, ids) do
    enqueued =
      ids
      |> Enum.chunk_every(Knowledge.embedding_batch_max())
      |> Enum.map(fn chunk ->
        # `Oban.insert/1` returns `{:error, changeset}` without raising, so throwing the
        # result away left the ONLY failure mode that does not log — the group counted
        # uncorroborated with an enqueue that never happened, indistinguishable from a
        # successful one.
        case %{article_ids: chunk, tenant_id: tenant_id}
             |> BatchArticleEmbeddingWorker.new()
             |> Oban.insert() do
          {:ok, _job} ->
            length(chunk)

          {:error, reason} ->
            log_backfill_failed(tenant_id, "insert:" <> insert_tag(reason))
            0
        end
      end)
      |> Enum.sum()

    # AFTER the inserts, counting what actually landed. Printed at the top it was the same
    # before-the-fact claim this path was fixed to stop making: a run where every insert
    # failed still asserted "enqueued", and the operator scanning for the positive line read
    # a total failure as a transient gap. Zero enqueued prints nothing — the failures
    # already logged themselves.
    if enqueued > 0 do
      Logger.info(
        "Consolidation: tenant=#{tenant_id} enqueued an embedding backfill for " <>
          "#{enqueued} of #{length(ids)} withheld member(s); the withhold clears once the " <>
          "vectors land."
      )
    end

    :ok
  rescue
    e -> log_backfill_failed(tenant_id, ExitTag.tag(e))
  catch
    :exit, reason -> log_backfill_failed(tenant_id, "exit:" <> ExitTag.tag(reason))
  end

  # Low-cardinality, like every other tag this module logs — never the whole changeset.
  defp insert_tag(%Ecto.Changeset{errors: errors}), do: inspect(Keyword.keys(errors))
  defp insert_tag(other), do: inspect(other, limit: 3, printable_limit: 120)

  defp log_backfill_failed(tenant_id, tag) do
    Logger.warning(
      "Consolidation: tenant=#{tenant_id} could not enqueue the embedding backfill for a " <>
        "withheld duplicate group (#{tag}); it will be retried next run."
    )

    :ok
  end

  # The winner is the OLDEST live member, NOT the longest one, and that is a security
  # property rather than an editorial preference. Every input to a duplicate group is
  # writable by any agent-role key: it can pick a title that collides under `@title_key_sql`
  # (or an `idempotency_key` that does), and it can pick a body — so with longest-wins it
  # could retire an established published article simply by publishing a longer near-copy
  # beside it and waiting two nights. Content corroboration does not stop that; the
  # corroborating content is the attacker's own. Age is the one input a later writer cannot
  # manufacture, so keeping the earliest capture makes "write beside it" a way to unpublish
  # YOUR OWN article and nobody else's.
  #
  # It also matches what the class means: `duplicate_capture` is one thing captured twice,
  # and the duplicate is the second capture. The cost is that a fuller re-capture loses to
  # the stub it duplicates — bounded, because the unpublish is reversible and the fuller
  # text survives as a draft.
  defp apply_live_group(tenant_id, proposal, live, budget) do
    [winner | all_losers] =
      Enum.sort_by(live, fn a ->
        {DateTime.to_unix(a.inserted_at, :microsecond), -a.body_len, a.id}
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
      {:ok, _} ->
        stamp_retraction(tenant_id, loser.id)
        true

      other ->
        log_unpublish_failure(tenant_id, loser, unpublish_error_tag(other))
    end
  rescue
    e -> log_unpublish_failure(tenant_id, loser, ExitTag.tag(e))
  catch
    :exit, reason -> log_unpublish_failure(tenant_id, loser, "exit:" <> ExitTag.tag(reason))
  end

  # The DURABLE record that consolidation was the actor. The audit_log already carries it,
  # but retention-bounded (`:audit_retention_days`): past that horizon
  # `DraftDuplicateSweepWorker` could not tell this retraction from a human draft, and the
  # safe reading of an absent record is wrong in one direction — it would archive
  # consolidation's own work through a one-way door.
  #
  # AFTER the unpublish, never inside it: a stamp on an article that did not actually get
  # unpublished would suppress the sweep on a still-published article forever. Best-effort by
  # design — a failed stamp costs the horizon bound the sweep already falls back to, whereas
  # raising here would lose the remaining confirmed groups for the tenant.
  defp stamp_retraction(tenant_id, article_id) do
    from(a in Knowledge.Article,
      where: a.tenant_id == ^tenant_id and a.id == ^article_id
    )
    |> AdminRepo.update_all(set: [consolidation_retracted_at: DateTime.utc_now()])
  rescue
    e ->
      Logger.warning(
        "Consolidation: tenant=#{tenant_id} unpublished #{article_id} but could not stamp " <>
          "the retraction marker (#{ExitTag.tag(e)}); the sweep falls back to the audit_log."
      )
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
  Retitles every article whose PLACEHOLDER TITLE tonight's report and the previous one
  both propose. The second class this pass applies, and the second thing it can write.

  ## Why this class earns an automatic consumer

  The same rule the confirmed-duplicate unpublish earns its own by: REVERSIBILITY, not
  confidence (#605). A title is a plain column on a live changeset, the previous one is
  recorded on the article's own metadata before it is replaced, and putting it back is a
  `PATCH`. There is no human approver and there will not be one, so a class that only a
  human could ever consume is a leak — and this one leaked: it was re-derived every night
  for weeks with nothing on the other end.

  ## The same gate, deliberately

  Two consecutive reports must agree on the fingerprint (`confirmed_proposals/3`, the SAME
  helper and the same `#{@max_confirmation_gap}`-day window the duplicate drain uses), and
  the gate vocabulary is identical: `:report_gap`, `:insufficient_history`,
  `:drain_disabled`, `:open`. A title someone is midway through fixing is gone from the
  second report and is never touched.

  ## Nothing is trusted from the proposal

  The article is re-fetched LIVE — before the provider call and AGAIN after it — and must
  still be published, still shared-visibility, and its title must still match the placeholder
  pattern. Between the scan and the write a human may have retitled it, and completing their
  edit for them — with a machine title, hours later — is exactly the failure
  `still_colliding/5` exists to prevent on the other class. A CURATED article is skipped too:
  `Article.update_changeset/2` clears the governed curated marker on any title change, and
  clearing it is the one part of this write that putting the title back would NOT undo. So is
  a title that normalizes onto another live SHARED published article's (`title_key_taken`) —
  writing it would manufacture the `:duplicate_capture` group the sibling drain retracts.

  ## Abstention beats invention

  The title is derived from the article's own opening bytes through the existing
  `Loopctl.Knowledge.ContentExtractorBehaviour` seam (per-tenant BYO provider, so an
  Anthropic and an OpenAI-compatible tenant both work through `ContentExtractorRouter`).
  A provider error, an unparseable reply, a reply naming SEVERAL articles rather than one, an
  empty body, a reply whose title is itself a placeholder, one over the 500-character column
  limit, or one that normalizes to the title already there — every one of them ABSTAINS and
  is counted in `abstained`, whether it is noticed before the provider call or after. A wrong title is
  worse than a placeholder: the placeholder announces that nobody has named the article,
  while a confident wrong name does not.

  ## What bounds one night

  A WALL CLOCK (`:budget_ms`), because the per-item cost is an outbound provider call and a
  count bounds attempts rather than cost — #761, in this worker, for six consecutive nights.
  `:max_retitles` bounds the candidate QUERY (and `0` PAUSES the drain, `gate:
  :drain_disabled`). The return carries `offered` and `budget_exhausted` so a truncated
  night and a night with nothing to do are never the same numbers; the worker puts both in
  the log line and in the `knowledge.lint_completed` audit event.

  `applied + skipped + abstained + failed` is what was PROCESSED, so it is below `offered`
  exactly when the clock fired. `failed` counts articles a WRITE could not be made for
  (the live re-fetch or the update raised); a provider failure is an abstention, not a
  failure, because no write was ever going to be attempted.
  """
  @spec apply_confirmed_generic_titles(Ecto.UUID.t(), keyword()) :: %{
          applied: non_neg_integer(),
          skipped: non_neg_integer(),
          abstained: non_neg_integer(),
          failed: non_neg_integer(),
          offered: non_neg_integer(),
          budget_exhausted: boolean(),
          gate: :open | :report_gap | :insufficient_history | :drain_disabled
        }
  def apply_confirmed_generic_titles(tenant_id, opts \\ []) do
    cap =
      clamp_cap(
        Keyword.get(opts, :max_retitles, @default_max_retitles),
        @default_max_retitles,
        @hard_max_retitles
      )

    if cap == 0 do
      log_gate_blocked(tenant_id, :generic_title, :drain_disabled)
      retitle_tally(:drain_disabled)
    else
      run_confirmed_generic_titles(tenant_id, cap, opts)
    end
  end

  @doc """
  The content-extractor implementation this step calls.

  A per-CALL `:content_extractor` opt over the app-config seam, mirroring
  `Loopctl.Knowledge.ConflictJudge.impl/1` exactly. The config layer underneath is
  untouched and still resolves to `ContentExtractorRouter` in production and to the Mox
  mock in tests; the opt exists because a test must drive ONE call's extractor without
  `Application.put_env`, which mutates VM-global state every other test in this `async:
  true` suite would see.
  """
  @spec extractor(keyword()) :: module()
  def extractor(opts \\ []) do
    Keyword.get(
      opts,
      :content_extractor,
      Application.get_env(:loopctl, :content_extractor, ContentExtractorRouter)
    )
  end

  # ONE constructor for every retitle tally, so no path can ship a map missing a key the
  # worker's summary line interpolates — the `empty_tally/2` lesson, which cost a fail-soft
  # rescue a KeyError one line after it had swallowed the original error.
  defp retitle_tally(gate) do
    %{
      applied: 0,
      skipped: 0,
      abstained: 0,
      failed: 0,
      offered: 0,
      budget_exhausted: false,
      gate: gate
    }
  end

  defp run_confirmed_generic_titles(tenant_id, cap, opts) do
    case confirmed_proposals(tenant_id, :generic_title, cap) do
      {:error, reason} ->
        log_gate_blocked(tenant_id, :generic_title, reason)
        retitle_tally(reason)

      {:ok, proposals} ->
        drain_retitles(tenant_id, proposals, opts)
    end
  end

  defp drain_retitles(tenant_id, proposals, opts) do
    # Deadline taken before the first item and checked BEFORE each one, never after. A
    # post-item check is unconditionally committed to item #1, so a budget of exactly 0 — the
    # state a night whose prelude overran arrives in — still bought one full provider call
    # and one write out of a reserve that was already spent. Checking at the head also keeps
    # the flag readable for free: a night that processed its LAST candidate and only then
    # crossed the deadline never reaches another check, so a DRAINED night is never reported
    # as truncated.
    budget_ms = Keyword.get(opts, :budget_ms, @default_retitle_budget_ms)
    deadline = System.monotonic_time(:millisecond) + budget_ms
    offered = length(proposals)

    result =
      Enum.reduce_while(proposals, %{retitle_tally(:open) | offered: offered}, fn proposal, acc ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:halt, %{acc | budget_exhausted: true}}
        else
          {:cont, tally_retitle(tenant_id, proposal, acc, opts)}
        end
      end)

    log_retitle_truncation(tenant_id, budget_ms, result)
    log_provider_unconfigured(tenant_id, result)
    result
  end

  # ONCE PER RUN, and a WARNING rather than the per-item info line — the
  # `log_permanent_withhold/2` lesson, applied to the second applying class.
  # `{:error, :no_api_key}` is the one abstention reason that is PERMANENT, self-inflicted
  # and operator-fixable, and `generated_title/3` folds it into the same `provider:` tag a
  # transient model refusal gets. Without this line a keyless tenant offers the same
  # placeholders every night, abstains on every one of them, and the audit event reads
  # exactly like a model that declined 25 times — the #620 shape, one class over.
  # Self-guarded for the same reason its sibling is: this runs AFTER the drain, so a repo
  # blip reading the tenant's LLM settings must not discard a completed run's tally.
  defp log_provider_unconfigured(tenant_id, %{abstained: abstained}) when abstained > 0 do
    if Llm.has_api_key?(tenant_id) do
      :ok
    else
      Logger.warning(
        "Consolidation: tenant=#{tenant_id} has no extraction key (mandatory BYO), so its " <>
          "#{abstained} abstained generic_title candidate(s) can never be titled at all and " <>
          "are re-offered every night. This is a configuration state, not a provider that " <>
          "declined. Nothing is retitled while it stands."
      )
    end

    :ok
  rescue
    _e -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp log_provider_unconfigured(_tenant_id, _result), do: :ok

  defp processed(%{applied: a, skipped: s, abstained: b, failed: f}), do: a + s + b + f

  # NEVER silent (#761 acceptance). Without this line and the `offered` counter beside it, a
  # night the clock cut short and a night with nothing left to retitle report the same
  # `applied`, and the difference is the whole question when the class stops converging.
  defp log_retitle_truncation(tenant_id, budget_ms, %{budget_exhausted: true} = result) do
    Logger.warning(
      "Consolidation: tenant=#{tenant_id} generic_title retitling hit its #{budget_ms}ms " <>
        "budget after #{processed(result)} of #{result.offered} candidate(s); the " <>
        "remainder is retried next run."
    )
  end

  defp log_retitle_truncation(_tenant_id, _budget_ms, _result), do: :ok

  # Per-item containment, exactly like `tally_apply/5`: this reduce is not transactional, so
  # a raise escaping it would discard the tally of the articles ALREADY retitled and report
  # zero writes that really happened.
  defp tally_retitle(tenant_id, proposal, acc, opts) do
    case retitle_proposal(tenant_id, proposal, opts) do
      :applied -> %{acc | applied: acc.applied + 1}
      :skip -> %{acc | skipped: acc.skipped + 1}
      :abstain -> %{acc | abstained: acc.abstained + 1}
    end
  rescue
    e -> retitle_failed(tenant_id, proposal, ExitTag.tag(e), acc)
  catch
    :exit, reason -> retitle_failed(tenant_id, proposal, "exit:" <> ExitTag.tag(reason), acc)
  end

  defp retitle_failed(tenant_id, proposal, tag, acc) do
    Logger.error(
      "Consolidation: tenant=#{tenant_id} generic_title proposal ##{proposal.number} could " <>
        "not be applied (#{tag}); the placeholder title stands."
    )

    %{acc | failed: acc.failed + 1}
  end

  defp retitle_proposal(tenant_id, proposal, opts) do
    case live_placeholder(tenant_id, proposal) do
      {:ok, article} ->
        generate_and_write(tenant_id, proposal, article, opts)

      {:skip, reason} ->
        log_retitle_skipped(tenant_id, proposal, reason)
        :skip

      {:abstain, reason} ->
        log_retitle_abstained(tenant_id, proposal, reason)
        :abstain
    end
  end

  # Re-derivation, not trust — the twin of `apply_duplicate_group/3`'s live re-fetch and of
  # `still_colliding/5`'s re-check of the signal that formed the group. The body comes back
  # pre-truncated from SQL (`@title_source_chars`) so this can never pull a whole corpus of
  # 100 KB bodies into memory, and `shared_only/1` keeps an agent's `private`/`owner` memory
  # out of a step that ships bytes to a provider.
  #
  # A proposal naming anything other than exactly one live article is skipped: `:generic_title`
  # emits one article per proposal, so any other shape is a proposal this code does not
  # understand and must not act on.
  defp live_placeholder(tenant_id, proposal) do
    rows =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.id in ^proposal.article_ids,
        where: a.status == :published,
        select: %{
          id: a.id,
          title: a.title,
          title_key: fragment(unquote(@title_key_sql), a.title),
          body: fragment("left(coalesce(?, ''), ?)", a.body, ^@title_source_chars),
          metadata: a.metadata,
          project_id: a.project_id,
          source_type: a.source_type,
          curated_at: a.curated_at
        }
      )
      |> shared_only()
      |> AdminRepo.all()

    case rows do
      [article] -> classify_live(article)
      _no_single_live_article -> {:skip, :not_live}
    end
  end

  defp classify_live(article) do
    cond do
      # The title was FIXED between the scan and now. The `title_key` is computed by the
      # same SQL expression the deriving query matches on (`@title_key_sql`), so this asks
      # exactly the question the scan asked, of the row as it is now.
      not placeholder_key?(article.title_key) ->
        {:skip, :title_fixed}

      # A curated article is the one case where the write is NOT fully undoable: any title
      # change clears `curated_at`/`curated_by` (`Article.update_changeset/2`), and putting
      # the title back does not put the governed marker back — re-curation has to go through
      # `Knowledge.mark_curated/3`. Reversibility is what licenses this whole step, so where
      # it does not hold the step does not run.
      not is_nil(article.curated_at) ->
        {:skip, :curated}

      # Nothing to derive a title FROM. An abstention rather than a skip: the article is
      # still a live candidate, it just cannot be named from content it does not have.
      String.trim(article.body) == "" ->
        {:abstain, :empty_body}

      true ->
        {:ok, article}
    end
  end

  defp placeholder_key?(key) when is_binary(key), do: Regex.match?(@generic_title_regex, key)
  defp placeholder_key?(_key), do: false

  defp generate_and_write(tenant_id, proposal, article, opts) do
    case generated_title(tenant_id, article, opts) do
      {:ok, title} ->
        revalidate_and_write(tenant_id, proposal, title)

      {:abstain, reason} ->
        log_retitle_abstained(tenant_id, proposal, reason)
        :abstain
    end
  end

  # `classify_live/1` made this check ALREADY — and then `generated_title/3` spent a whole
  # provider round-trip (Anthropic `receive_timeout` 25 s, one retry) in between, which is
  # long enough for every state it validated to move. So it is made again, against the row
  # as it is NOW, and the write is built from THAT row rather than from the pre-call
  # snapshot. Three things ride on it: a human who retitled the article during the call does
  # not get their edit completed for them by a machine title (the failure `still_colliding/5`
  # exists to prevent on the other class); a curation that landed during the call is not
  # silently cleared by the title change; and the metadata merged into is the LIVE map, so a
  # concurrent `visibility` flip or ingestion write is not reverted by a snapshot one round
  # trip old. `previous_title` then names what was really replaced.
  #
  # This narrows the window to the statement pair below rather than closing it: a
  # precondition ON the update would have to live in `Knowledge.update_article/4`, which
  # every other caller shares. The remaining window is microseconds against 25 seconds.
  # The two outcomes stay DISTINCT across the call, exactly as `retitle_proposal/3` keeps
  # them ten lines above: `classify_live/1` makes an empty body an abstention on purpose
  # ("the article is still a live candidate"), so funnelling it into `:skip` here counted
  # one condition in two different buckets depending only on whether the provider call had
  # already returned — and moved it out of the counter `log_provider_unconfigured/2` reads.
  defp revalidate_and_write(tenant_id, proposal, title) do
    case live_placeholder(tenant_id, proposal) do
      {:ok, live} -> checked_write(tenant_id, proposal, live, title)
      {:skip, reason} -> retitle_skip(tenant_id, proposal, reason)
      {:abstain, reason} -> retitle_abstain(tenant_id, proposal, reason)
    end
  end

  defp retitle_skip(tenant_id, proposal, reason) do
    log_retitle_skipped(tenant_id, proposal, reason)
    :skip
  end

  defp retitle_abstain(tenant_id, proposal, reason) do
    log_retitle_abstained(tenant_id, proposal, reason)
    :abstain
  end

  defp checked_write(tenant_id, proposal, article, title) do
    if title_key_taken?(tenant_id, article.id, title) do
      log_retitle_collided(tenant_id, proposal)
      :skip
    else
      write_title(tenant_id, proposal, article, title)
    end
  end

  # Its OWN line, not `log_retitle_skipped/3`'s: that sentence says the article "is no longer
  # the candidate that was confirmed", which is the one thing this skip is not — the article
  # is exactly the confirmed candidate, and the collision recurs at one provider call a night
  # until generation differs. An operator reading the tally needs to see the recurring cost,
  # not a class that reads as self-resolving.
  defp log_retitle_collided(tenant_id, proposal) do
    Logger.info(
      "Consolidation: tenant=#{tenant_id} skipped generic_title proposal " <>
        "##{proposal.number} (title_key_taken) — the generated title normalizes onto a live " <>
        "shared article's, so applying it would manufacture the very duplicate group this " <>
        "pass retracts. The placeholder stands and is re-offered, at one provider call a " <>
        "night, until a generation differs."
    )
  end

  # The generated title must not collide with another live article under the pass's OWN
  # normalization, not merely under the raw-title unique index. That index is on
  # `(tenant_id, title)` VERBATIM, so "Ecto Changesets" lands beside "Ecto changesets"
  # without complaint — and `title_drift_groups/1` then reads the two as one
  # `:duplicate_capture` group, which this pass's sibling drain unpublishes two nights later.
  # A retitle that manufactures the very class the pass retracts is not one worth making, so
  # it is a SKIP: the placeholder stands and tomorrow's generation may differ. Both sides are
  # normalized by Postgres (`@title_key_sql`), never by the Elixir twin, so the comparison is
  # the one the grouping will actually make.
  #
  # Scoped by `published_base/1` — `status == :published` composed with `shared_only/1` — for
  # the same reason: it is the SAME set `title_drift_groups/1` groups over, so this refuses
  # exactly the collisions that can manufacture the group and no others. Scoping it to the
  # raw index's `not in [:archived, :superseded]` instead let a DRAFT, or an agent's PRIVATE
  # memory, veto a shared retitle that could never have formed a group — and that refusal is
  # PERMANENT, since the collision is deterministic and the placeholder is re-offered every
  # night. `shared_only/1` is composed into every place that decides whether an article of
  # this tenant is in scope, and this is one of them.
  #
  # And on `heavy_all/2`, not `AdminRepo`, like every other whole-corpus scan here: there is
  # no expression index on `@title_key_sql`, so this evaluates the normalization per row, and
  # the AdminRepo pool is 3 connections that every authenticated request also checks out of.
  defp title_key_taken?(tenant_id, article_id, title) do
    from(a in published_base(tenant_id),
      where: a.id != ^article_id,
      where:
        fragment(unquote(@title_key_sql), a.title) == fragment(unquote(@title_key_sql), ^title),
      limit: 1,
      select: 1
    )
    |> heavy_all(tenant_id)
    |> Enum.any?()
  end

  # The provider call, and the ONE place bytes of this tenant's corpus leave. Scoped to the
  # article's own project (`Egress.Scope`) so a `local_only` project marking is enforced at
  # the egress chokepoint rather than stopping at this caller.
  #
  # NO `:source_ref` is passed, deliberately. The behaviour asks callers to name the specific
  # source so a title can qualify itself, but the only source strings an article carries here
  # are caller-supplied metadata, and the doc on that option is explicit that a URL passed
  # through it must have its userinfo and query string stripped first — that is where
  # presigned signatures and share tokens live. The prompt has a defined branch for an absent
  # Source line (qualify from the content's own subject), so omitting it is a supported state
  # and not an unsatisfiable instruction.
  #
  # FAIL-SOFT into an ABSTENTION, never into a failure: a raise or an exit inside a provider
  # client means no title was produced, which is the same outcome as a model that declined.
  # `failed` is reserved for a write that could not be made.
  defp generated_title(tenant_id, article, opts) do
    scope = EgressScope.new(tenant_id, article.project_id)

    case extractor(opts).extract_from_content(scope, article.body,
           source_type: article.source_type || "unknown"
         ) do
      {:ok, candidates} -> sole_usable_title(candidates, article)
      {:error, reason} -> {:abstain, "provider:" <> ExitTag.tag(reason)}
    end
  rescue
    e -> {:abstain, "provider:" <> ExitTag.tag(e)}
  catch
    :exit, reason -> {:abstain, "provider:exit:" <> ExitTag.tag(reason)}
  end

  # The extractor is a knowledge EXTRACTOR: it returns whole article attribute maps. Only the
  # TITLE is taken and everything else is discarded — this step creates nothing, publishes
  # nothing, and rewrites no body. Reusing the seam rather than adding a second provider
  # surface is what keeps per-tenant BYO, the router's provider choice, the egress marking
  # and the token accounting working here for free.
  #
  # ONE candidate, or nothing. A reply naming SEVERAL articles is a DECOMPOSITION of the
  # content — the extractor's contract is to split raw content into up to ten articles — and
  # taking candidate #1 would name the whole article after whatever its opening section
  # happens to discuss. The body is truncated to `@title_source_chars` besides, so the model
  # saw only that opening. A sole candidate is the only reply shape that answers the question
  # this step asked, and abstention beats invention.
  defp sole_usable_title([candidate], article) do
    case usable_title(candidate, article) do
      nil -> {:abstain, "no_usable_title"}
      title -> {:ok, title}
    end
  end

  defp sole_usable_title([], _article), do: {:abstain, "no_usable_title"}

  defp sole_usable_title(candidates, _article) when is_list(candidates),
    do: {:abstain, "multi_candidate_reply"}

  defp sole_usable_title(_other, _article), do: {:abstain, "unparseable_reply"}

  # Every rejection here is a reason to keep the placeholder. A blank or over-long title is
  # a write the changeset would reject anyway; a title that is ITSELF a placeholder would be
  # re-proposed tomorrow night and retitled forever; and one that normalizes to the title
  # already stored is a write with nothing in it.
  defp usable_title(%{title: title}, article) when is_binary(title) do
    trimmed = String.trim(title)
    key = normalize_title(trimmed)

    if trimmed != "" and String.length(trimmed) <= @max_generated_title_chars and
         not placeholder_key?(key) and key != normalize_title(article.title) do
      trimmed
    end
  end

  defp usable_title(_candidate, _article), do: nil

  # The Elixir twin of `@title_key_sql`, for a string that has never been near the database.
  # It is deliberately the ASCII reading of `[[:alnum:]]` where Postgres's is locale-aware,
  # and the difference only ever makes this MORE willing to call a generated title a
  # placeholder — which abstains, the safe direction. The LIVE re-check never uses this: it
  # reads the key Postgres itself computed, so the question the scan asked is the question
  # asked again.
  defp normalize_title(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]]+/u, " ")
    |> String.trim()
  end

  # The two records this write leaves behind are NOT the same kind of thing, and the split is
  # the whole point of `Knowledge.retitle_article/4`:
  #
  # - The REPLACED TITLE — what an undo restores — goes on the `previous_title` COLUMN,
  #   stamped by `Article.retitle_changeset/2` and castable from nowhere. What licenses this
  #   pass to retitle without a human is REVERSIBILITY, so an undo record an ordinary
  #   `PATCH /api/v1/knowledge/:id` can erase is not a record: `metadata` is cast as a whole
  #   MAP, so one agent request would have destroyed it while leaving the retitle standing.
  #   That is the `stories.lifecycle_entered_at` lesson (CLAUDE.md) reached a second time.
  #   The audit log's `old_state` carries the replaced title too, but only until
  #   `:audit_retention_days` drops the partition.
  #
  # - The MACHINE-GENERATED MARKER stays on `metadata`, the same shape
  #   `Loopctl.Knowledge.StructuralLinks` uses (`hub_title_generated`), so a later pass or a
  #   human reading the row can tell this pass's work from a person's. It is advisory and it
  #   is allowed to be erasable, because it only answers "is this title ours to replace" and
  #   losing it fails SAFE — a future night declines the retitle rather than making an
  #   unrecorded one.
  #
  # The metadata map is MERGED, never replaced: `update_changeset/2` casts `:metadata` as a
  # whole map, so building the attrs from anything but the LIVE map (re-read by
  # `revalidate_and_write/4` after the provider call, never the pre-call snapshot) would
  # erase an agent's `visibility` or an ingestion's provenance as a side effect of a retitle.
  defp write_title(tenant_id, proposal, article, title) do
    metadata = article.metadata || %{}

    attrs = %{
      title: title,
      metadata: Map.put(metadata, "consolidation_title_generated", title)
    }

    case Knowledge.retitle_article(tenant_id, article.id, attrs,
           actor_type: "system",
           actor_label: "worker:consolidation"
         ) do
      {:ok, _updated} ->
        Logger.info(
          "Consolidation: tenant=#{tenant_id} applied generic_title proposal " <>
            "##{proposal.number} — retitled #{article.id} from its content. The previous " <>
            "title is on the article's previous_title column; reversible via PATCH."
        )

        :applied

      other ->
        # A rejected write is a SKIP, not a failure: the commonest rejection by far is the
        # per-tenant active-title unique index (another article already holds the generated
        # title), which is a decision this run cannot make and a normal outcome rather than
        # a fault. It stays a candidate, and tomorrow's generation may differ.
        log_retitle_rejected(tenant_id, proposal, article, retitle_error_tag(other))
        :skip
    end
  end

  # Low-cardinality, like every other tag this module logs — the changeset's ERROR KEYS, never
  # the changeset (which carries the rejected title and every other cast field). A title
  # collision therefore reads `[:title]`.
  #
  # No catch-all clause, deliberately, and this is the one place in the module without one:
  # `Knowledge.retitle_article/4`'s return type is CLOSED at `{:ok, article} | {:error,
  # :not_found} | {:error, changeset}`, so a wildcard here is unreachable and dialyzer says
  # so. If that shape ever gains a member, the FunctionClauseError is contained by
  # `tally_retitle/4`'s rescue — one article counted `failed` and logged, never a lost run —
  # which is a better outcome than tagging an unknown new failure mode "invalid" forever.
  defp retitle_error_tag({:error, %Ecto.Changeset{errors: errors}}),
    do: inspect(Keyword.keys(errors))

  defp retitle_error_tag({:error, reason}) when is_atom(reason), do: to_string(reason)

  defp log_retitle_skipped(tenant_id, proposal, reason) do
    Logger.info(
      "Consolidation: tenant=#{tenant_id} skipped generic_title proposal " <>
        "##{proposal.number} (#{reason}) — the article is no longer the candidate that was " <>
        "confirmed. The next scan re-derives what is left."
    )
  end

  defp log_retitle_abstained(tenant_id, proposal, reason) do
    Logger.info(
      "Consolidation: tenant=#{tenant_id} ABSTAINED on generic_title proposal " <>
        "##{proposal.number} (#{reason}); the placeholder title stands. A wrong title is " <>
        "worse than a placeholder."
    )
  end

  defp log_retitle_rejected(tenant_id, proposal, article, tag) do
    Logger.warning(
      "Consolidation: tenant=#{tenant_id} generic_title proposal ##{proposal.number} was " <>
        "rejected for #{article.id} (#{tag}); the placeholder title stands."
    )
  end

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
  # (`knowledge.ex:7293` and friends) so an article with no `visibility` key stays in scope.
  # NOTE: `mix loopctl.check_skill_citations` scans docs, not `.ex` comments, so a cite like
  # this one drifts silently — the previous anchor pointed at a bare `end`.
  defp shared_only(query), do: where(query, [a], shared_visibility(a.metadata))

  defp heavy_opts, do: HeavyRead.opts(@heavy_endpoint)

  defp heavy_all(query, tenant_id), do: HeavyRead.all(tenant_id, query, heavy_opts())

  # The matching set for `:generic_title`, as a composable query so the COUNT and the
  # capped PAGE are built from ONE predicate and cannot drift into disagreeing about what
  # "matching" means.
  defp generic_title_base(tenant_id) do
    from(a in published_base(tenant_id),
      where:
        fragment(
          unquote(@title_key_sql <> " ~ ?"),
          a.title,
          ^@generic_title_pattern
        )
    )
  end

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

    taken = Enum.take(groups, cap)
    members_cut = Enum.any?(taken, fn {_reason, ids} -> length(ids) > @max_group_members end)
    selected = Enum.map(taken, fn {reason, ids} -> {reason, cap_members(ids)} end)

    evidence_by_id = evidence_map(tenant_id, Enum.flat_map(selected, fn {_r, ids} -> ids end))

    items =
      Enum.map(selected, fn {reason, ids} ->
        build_proposal(:duplicate_capture, ids, evidence_by_id,
          severity: "warning",
          rationale:
            "#{length(ids)} published articles are the same capture under #{reason}. " <>
              "The novelty gate does not catch this: novelty scoring and idempotency are separate paths.",
          suggested_action:
            "Keep the EARLIEST capture and UNPUBLISH every later one — not the richest, and " <>
              "do not archive them. Age is the one input a later writer cannot manufacture, " <>
              "so keeping the oldest is what stops a longer near-copy written beside an " <>
              "established article from retiring it. This is the rule the nightly pass " <>
              "applies, so a hand-applied remedy that keeps a different member will be " <>
              "re-fought by it. " <>
              "`:archived` is TERMINAL for an article: `Article`'s transition table has no " <>
              "`{:archived, _}` and there is no unarchive function, so the only way back is a " <>
              "`user+` PATCH carrying an explicit status. `{:published, :draft}` and " <>
              "`{:draft, :published}` are both real transitions, so unpublish is the " <>
              "reversible primitive and the only one an unattended pass may ever apply."
        )
      end)

    {length(groups), items, members_cut}
  end

  defp interleave([], rest), do: rest
  defp interleave(rest, []), do: rest
  defp interleave([a | as], [b | bs]), do: [a, b | interleave(as, bs)]

  # The number of GROUPS was capped; the number of members WITHIN one group was not
  # (#617). Every member id is carried on the proposal row, echoed in its `evidence`
  # array, and re-sent as an `id in ^article_ids` parameter list on the apply path — so a
  # pathological group (one normalized title shared by thousands of captures, which is
  # exactly what filename-derived titles produce) writes an unbounded row and builds an
  # unbounded query out of one night's scan.
  #
  # Truncation is SAFE here only because it is deterministic: `fingerprint/2` hashes the
  # SORTED id set, and the two-run agreement gate confirms a group only when the same
  # fingerprint appears in two consecutive reports. The `array_agg` orders by
  # `inserted_at, id` — a TOTAL order, the `id` tiebreaker added with this cap — so both
  # runs truncate to the byte-identical set and the group stays confirmable. Ordering by
  # `inserted_at` alone left ties resolvable either way, which under a cap would flap the
  # fingerprint and make such a group permanently unconfirmable.
  #
  # The leftovers are not lost: the winner stays published, so the next scan re-derives
  # the remaining collision as a fresh group. Same drain-don't-stall shape as the apply
  # budget in `apply_live_group/4` — but SLOWER, and by construction: the survivors are a
  # different sorted id set, hence a different fingerprint, which the two-run agreement
  # gate cannot confirm until it has appeared in two consecutive reports. A truncated
  # group therefore drains one cap's worth every TWO runs (derive, confirm, apply), not
  # every run.
  defp cap_members(ids) when length(ids) <= @max_group_members, do: ids

  defp cap_members(ids) do
    Logger.info(
      "Consolidation: duplicate group of #{length(ids)} members truncated to " <>
        "#{@max_group_members} for this run; the remainder is re-derived on the next run " <>
        "and applies the run after that (its new fingerprint needs two agreeing reports)."
    )

    Enum.take(ids, @max_group_members)
  end

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
      select: %{ids: fragment("array_agg(?::text ORDER BY ?, ?)", a.id, a.inserted_at, a.id)}
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
  # It applies to BOTH forming signals, and the IDEMPOTENCY exemption it used to carry is
  # gone. That exemption read: a key the WRITER supplied to mark one capture is direct
  # evidence of one capture written twice, unlike a title, which is an accident of whatever
  # the source file was called. The premise holds for ONE writer. It does not hold in a
  # tenant where any agent-role key may publish an article and choose its own
  # `idempotency_key`: the key is then caller-controlled data and the group can span two
  # unrelated writers, so an uncorroborated idempotency group is a way to have a published
  # article retired by writing one beside it. Requiring content evidence for both signals
  # means an auto-unpublish always rests on what the articles SAY, never only on a key one
  # of them declared. "Confirmed" then means one thing for the whole class, rather than two
  # things depending on which query formed the group.
  #
  # Corroboration alone does NOT close that shape, because the corroborating content is the
  # same party's to write — `apply_live_group/4` deciding the winner by AGE is what does.
  #
  # The cost is real and was the exemption's second argument: a tenant with no embeddings
  # (mandatory BYO) now has its idempotency groups WITHHELD rather than applied. That is
  # the safe direction — the proposal is still reported, nothing is unpublished, and the
  # withhold self-clears the moment vectors exist. Title drift has always behaved exactly
  # this way for those tenants.
  #
  # FAILS CLOSED on missing evidence, and the withhold is SELF-CLEARING: an article with no
  # embedding where this tenant keeps them (`score_source/1`; the corpus has had 80 such
  # un-embedded articles since June) drops
  # its whole group rather than letting it pass on a partial sample, and the missing vectors
  # are enqueued (`backfill_missing_embeddings/2`) so the next run can decide instead of
  # withholding the same group forever.
  #
  # Scored over the LIVE members, never the scan-time id set, so what is checked is the group
  # that would actually be unpublished.
  defp corroborated?(proposal, live, scored) do
    # Sorted so the entry a group resolves to is deterministic, and looked up by ANY live
    # member rather than by the smallest id: the batch is scored once over the union of
    # every confirmed proposal's SCAN-time ids, so the smallest member of THIS group may
    # have been unpublished by an earlier group in the same reduce.
    ids = live |> Enum.map(& &1.id) |> Enum.sort()
    judge_similarity(lookup_score(scored, ids, drift_signal(proposal)), ids)
  end

  # Keyed by `{signal, member_id}`, never by member id alone: one article can belong to a
  # title group AND an idempotency group, and the two are scored under different grouping
  # keys. A flat member key would let one group's `min_sim` answer for the other's.
  defp lookup_score(:unavailable, _ids, _signal), do: :unavailable

  defp lookup_score(scored, ids, signal),
    do: Enum.find_value(ids, &Map.get(scored, {signal, &1}))

  # FAILS CLOSED on missing evidence, checked against THIS group's scored MEMBER set — never
  # against a pair COUNT, which was counted over the whole batch while the live ids are one
  # proposal's, so a shared article or a mid-run unpublish made the two denominators disagree
  # and rejected a genuine group. One unscored member withholds the whole group rather than
  # letting it be judged on the pairs that happen to carry vectors, which could be exactly the
  # two that genuinely match. Within one entry every embedded member is paired with every
  # other, so full member coverage IS full pair coverage; `min_sim` may span another
  # proposal's ids under the same title, which can only lower it.
  # A FAILED scoring read is not missing evidence: it says nothing about which members carry
  # vectors, so it withholds with an EMPTY unscored list — no backfill, and its own log line.
  # Treating it as "no vectors" answered a DB outage with an embedding job per member of
  # every confirmed group, against the same shedding database, under a message that pointed
  # the operator at embeddings.
  defp judge_similarity(:unavailable, _ids), do: {:withheld, :unavailable, []}

  defp judge_similarity(nil, ids), do: {:withheld, nil, ids}

  defp judge_similarity(%{scored: scored_ids, min_sim: min_sim} = entry, ids) do
    case Enum.reject(ids, &MapSet.member?(scored_ids, &1)) do
      [] -> if min_sim >= min_duplicate_similarity(), do: :ok, else: {:withheld, entry, []}
      unscored -> {:withheld, entry, unscored}
    end
  end

  # The three withholds have different remedies, so they say different things: a low cosine is
  # a verdict, missing vectors are a gap, and a failed read is neither. What this line does
  # NOT claim any more is that a backfill was enqueued — it runs BEFORE
  # `backfill_missing_embeddings/2` decides, and on a tenant with no BYO embedding key (or
  # whose members carry a truncation-marked PREFIX hash) nothing is enqueued at all. Saying
  # "backfill enqueued" there made a PERMANENT configuration state read as a transient gap,
  # which is the exact misreading that module comment exists to prevent. The enqueue owns
  # its own statement, in all three of its outcomes.
  defp log_uncorroborated(tenant_id, proposal, _live, :unavailable, _unscored) do
    Logger.warning(
      "Consolidation: tenant=#{tenant_id} WITHHELD duplicate_capture proposal " <>
        "##{proposal.number} from auto-apply — similarity scoring failed this run, so there " <>
        "is no content evidence to judge the collision on. Reported, not applied. No " <>
        "backfill enqueued: the cause is a failed read, not a missing vector."
    )
  end

  defp log_uncorroborated(tenant_id, proposal, live, entry, unscored) do
    detail =
      case {entry, unscored} do
        {_entry, [_ | _] = missing} ->
          "#{length(missing)} member(s) carry no embedding"

        {%{min_sim: sim, pairs: pairs}, []} ->
          "min cosine #{Float.round(sim, 4)} across #{pairs} scored pair(s), " <>
            threshold_detail()
      end

    key =
      case drift_signal(proposal) do
        :title -> "normalized title"
        :idempotency -> "normalized idempotency key"
      end

    Logger.warning(
      "Consolidation: tenant=#{tenant_id} WITHHELD duplicate_capture proposal " <>
        "##{proposal.number} from auto-apply — #{length(live)} live members share a " <>
        "#{key} but their bodies do not corroborate it (#{detail}). Reported, not applied. " <>
        "A shared key is not evidence of a duplicate capture."
    )
  end

  # A threshold no cosine can reach is a deliberate hard disable, so the withhold says that
  # rather than printing an impossible number and leaving the operator to work out that
  # "threshold 2.0" is their own setting rather than a bug. This is where the disable is
  # visible: it is intentional configuration, so it earns no repeated warning of its own.
  defp threshold_detail do
    case min_duplicate_similarity() do
      threshold when threshold >= 1.0 ->
        "auto-apply DISABLED by configuration — the threshold is set above any reachable " <>
          "cosine, so no group can corroborate"

      threshold ->
        "threshold #{threshold}"
    end
  end

  # The rationale is the only place the forming signal survives onto the persisted proposal
  # row, so both sites interpolate the phrase from the same attribute rather than repeating a
  # literal. It no longer selects WHETHER a group must corroborate — both signals must — only
  # which normalized key its members are re-checked and scored under.
  #
  # A rationale this cannot classify (reworded, truncated, non-binary) reads as `:title`, and
  # that is still the conservative answer: the two signals are scored under different keys,
  # so a misread looks the group up under a key it did not form on, finds no entry, and
  # WITHHOLDS. A copy edit can cost an apply; it cannot buy one.
  defp drift_signal(%{rationale: rationale}) when is_binary(rationale) do
    if String.contains?(rationale, @idempotency_drift), do: :idempotency, else: :title
  end

  defp drift_signal(_proposal), do: :title

  # Restricted to the CANDIDATE ids, never the whole corpus: the self-join is over the few
  # hundred articles that already collided on a normalized key, so this adds a small join
  # rather than a second 79k-row scan.
  #
  # Keyed by `{signal, EVERY scored member}`, so a caller can resolve its group from any live
  # id it still has without a title group answering for an idempotency one. The join
  # predicate and the grouping expression are the SAME normalized key that formed the group
  # (`@title_key_sql` / `@idempotency_key_sql`, referenced from the deriving query and from
  # here so they cannot drift), and each entry carries the member set it scored so the caller
  # can tell a low cosine from a missing one.
  defp pairwise_similarity_by_group(_tenant_id, [], _signal), do: %{}

  defp pairwise_similarity_by_group(tenant_id, ids, signal) do
    tenant_id
    |> pair_candidates(ids, signal)
    |> score_pairs(score_source(tenant_id))
    |> group_by_signal(signal)
    |> heavy_all(tenant_id)
    |> index_by_member(signal)
  end

  # `a2` binds tenant_id to the PASSED tenant_id, not transitively to `a1`'s. HeavyRead runs
  # on a BYPASSRLS pool and its guard requires every base-table source to carry its own
  # conjunctive equality — a transitive one is not checkable by inspecting the query. It
  # carries the visibility guard for the same reason `a1` does (`shared_only/1`).
  defp pair_candidates(tenant_id, ids, :title) do
    from(a1 in published_base(tenant_id),
      join: a2 in Article,
      on:
        a2.tenant_id == ^tenant_id and a2.status == :published and a1.id < a2.id and
          shared_visibility(a2.metadata) and
          fragment(unquote(@title_key_sql <> " = " <> @title_key_sql), a1.title, a2.title),
      where: a1.id in ^ids and a2.id in ^ids
    )
  end

  # The idempotency twin. The NOT NULL guards mirror `idempotency_drift_groups/1`'s `where`:
  # SQL would make the key comparison NULL rather than false, but a member whose key was
  # cleared since the scan is no longer a member the scan would find, and scoring it here
  # would judge a group the derivation no longer derives.
  defp pair_candidates(tenant_id, ids, :idempotency) do
    from(a1 in published_base(tenant_id),
      join: a2 in Article,
      on:
        a2.tenant_id == ^tenant_id and a2.status == :published and a1.id < a2.id and
          shared_visibility(a2.metadata) and
          not is_nil(a2.idempotency_key) and
          fragment(
            unquote(@idempotency_key_sql <> " = " <> @idempotency_key_sql),
            a1.idempotency_key,
            a2.idempotency_key
          ),
      where: a1.id in ^ids and a2.id in ^ids,
      where: not is_nil(a1.idempotency_key)
    )
  end

  # Applied AFTER `score_pairs/2` so the aggregate select is written once for both signals.
  # Positional bindings are unaffected by the embedding joins `score_pairs/2` may append —
  # `a1`/`a2` stay first.
  defp group_by_signal(query, :title),
    do: from([a1, _a2] in query, group_by: fragment(unquote(@title_key_sql), a1.title))

  defp group_by_signal(query, :idempotency),
    do:
      from([a1, _a2] in query,
        group_by: fragment(unquote(@idempotency_key_sql), a1.idempotency_key)
      )

  # WHERE this tenant's vectors live, branched exactly like every other embedding-presence
  # reader in this codebase (`KnowledgeLintWorker.embedded_ids/2`,
  # `BatchArticleEmbeddingWorker.side_table_hashes/2`) — and the branch has to agree with
  # THEIRS, not merely exist. A legacy-1536 tenant whose reads have not cut over keeps its
  # vector in `articles.embedding`; scoring it at the active dimension found no side-table
  # row, withheld the group, and the backfill's own legacy-hash check then skipped the
  # re-embed as already-done — a withhold that could never clear, which is the opposite of
  # the self-clearing property this gate claims.
  defp score_source(tenant_id) do
    if Embeddings.use_side_table_hash?(tenant_id),
      do: Embeddings.active_dimension(tenant_id),
      else: :legacy
  end

  # A PREFIX vector is excluded from scoring, not scored (#617). The shrink ladder embeds
  # an over-long body as its opening only, and two unrelated captures that share a
  # boilerplate opening (CHANGELOG/API-doc headers — the exact population this gate was
  # added for) then score near 1.0 against each other. Corroborating a title collision on
  # that is the auto-unpublish the gate exists to prevent, arriving through the gate
  # itself. A marked member is therefore treated as MISSING evidence — it drops out of
  # `scored`, so `judge_similarity/2` withholds the whole group, which fails closed.
  defp score_pairs(query, :legacy) do
    from([a1, a2] in query,
      where: not is_nil(a1.embedding) and not is_nil(a2.embedding),
      where:
        not like(coalesce(a1.embedding_content_hash, ""), ^ShrinkLadder.truncated_hash_pattern()),
      where:
        not like(coalesce(a2.embedding_content_hash, ""), ^ShrinkLadder.truncated_hash_pattern()),
      select: %{
        min_sim: min(fragment("1 - (? <=> ?)", a1.embedding, a2.embedding)),
        pairs: count(a1.id),
        members:
          fragment("array_agg(DISTINCT ?::text) || array_agg(DISTINCT ?::text)", a1.id, a2.id)
      }
    )
  end

  defp score_pairs(query, dim) do
    from([a1, a2] in query,
      join: e1 in "article_embeddings",
      on: e1.article_id == a1.id and e1.dim == ^dim and e1.tenant_id == a1.tenant_id,
      join: e2 in "article_embeddings",
      on: e2.article_id == a2.id and e2.dim == ^dim and e2.tenant_id == a2.tenant_id,
      where:
        not like(coalesce(e1.embedding_content_hash, ""), ^ShrinkLadder.truncated_hash_pattern()),
      where:
        not like(coalesce(e2.embedding_content_hash, ""), ^ShrinkLadder.truncated_hash_pattern()),
      select: %{
        min_sim: min(fragment("1 - (? <=> ?)", e1.embedding, e2.embedding)),
        pairs: count(a1.id),
        members:
          fragment("array_agg(DISTINCT ?::text) || array_agg(DISTINCT ?::text)", a1.id, a2.id)
      }
    )
  end

  defp index_by_member(rows, signal) do
    rows
    |> Enum.flat_map(fn %{min_sim: sim, pairs: pairs, members: members} ->
      entry = %{min_sim: to_float(sim), pairs: pairs, scored: MapSet.new(members)}
      Enum.map(members, &{{signal, &1}, entry})
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
  # permanently while the run still reports `gate: :open`.
  #
  # The two out-of-range directions are NOT symmetric, and neither is clamped.
  #
  # BELOW the range (`0`, a negative) falls back to the default. Clamping toward the near
  # bound would put the threshold at `0.0`, which satisfies `min_sim >= 0.0` for every pair
  # — the only content check on the auto-applying class fully OFF — and `0` is also the
  # exact value an operator reaches for meaning "disable", because on the sibling drain caps
  # it IS a pause. A typo there may only make this pass more conservative.
  #
  # AT OR ABOVE 1.0 is HONOURED as a hard disable (`@disabled_similarity`), because that is
  # the one reading of an impossible threshold: cosine cannot exceed 1.0, so an operator
  # typing `2.0` (or `100`) is shutting the class down, mid-incident, without a deploy.
  # Falling back to the default there did the opposite of what was asked — it silently
  # RE-ENABLED auto-unpublish at 0.80 on a knob the operator had just set to stop it. `1.0`
  # itself lands here too rather than being accepted verbatim: identical vectors score
  # exactly 1.0, so honouring it literally would still auto-unpublish byte-identical
  # captures out of a setting meant to disable the class.
  #
  # Resolved through `SystemConfig` FIRST, like the three drain caps in
  # `KnowledgeLintWorker` — this is the one threshold that decides whether the only
  # self-writing class applies anything at all, and an operator watching it behave wrong
  # must be able to move it without a deploy. The DB key is expressed in PERCENT
  # (`..._pct`, `80` = 0.80) because `SystemConfig`'s cache is integer-typed.
  #
  # The DB layer is consulted only when a row actually EXISTS, which is why the read is
  # `fetch_int/1` rather than `get_int/2` with an out-of-band default. Presence has to be
  # answerable on its own terms: a `-1` sentinel default made a row STORING `-1`
  # indistinguishable from no row, so that setting silently resolved to the app layer with
  # nothing in the log to say the operator's value had been dropped.
  #
  # Reading the app-config float directly (rather than through the percent) keeps it exact —
  # routing it through `round(x * 100)` quantized every threshold with more than two decimals
  # (0.925 became 0.93) even for deployments that set no DB row at all. And it lets the
  # percent be range-checked as the INTEGER an operator types: 1..99 is a threshold, `>= 100`
  # is the hard disable, and anything at or below `0` falls through to the app layer — the
  # conservative direction, per the asymmetry explained above.
  defp min_duplicate_similarity do
    case SystemConfig.fetch_int(@min_similarity_pct_key) do
      {:ok, pct} -> stored_pct_threshold(pct)
      :error -> app_layer_similarity()
    end
  end

  defp app_layer_similarity do
    :loopctl
    |> Application.get_env(
      :knowledge_consolidation_min_duplicate_similarity,
      @default_min_duplicate_similarity
    )
    |> validate_similarity()
  end

  defp stored_pct_threshold(pct) when pct > 0 and pct < 100, do: pct / 100

  defp stored_pct_threshold(pct) when pct >= 100, do: @disabled_similarity

  defp stored_pct_threshold(other) do
    app_layer = app_layer_similarity()

    Logger.warning(
      "Consolidation: ignoring duplicate similarity percent #{inspect(other)} — not an " <>
        "integer in 1..99 (0 would turn the corroboration gate OFF, not disable it; use " <>
        "100 or more to disable the class); using #{app_layer}."
    )

    app_layer
  end

  # The bounds are EXCLUSIVE at both ends, matching the DB percent path's 1..99.
  #
  # `0` was accepted here, and it is the one in-range value that is catastrophic: the gate
  # is `min_sim >= threshold`, so a threshold of 0.0 is satisfied by EVERY pair — including
  # a pair with a cosine of 0. The only content check on the only self-applying class is
  # then fully OFF, silently, while every run still reports `gate: :open` and unpublishes.
  # This module's own comment above already explained why clamping a NEGATIVE to 0.0 would
  # be a disaster; it just never noticed that an explicit 0 walked straight through the
  # in-range clause to the same place. `0` is also the exact value an operator reaches for
  # meaning "turn this off" — on the sibling drain caps it IS a pause, so the wrong guess
  # here is the likely one.
  #
  # `1.0` and above is NOT accepted verbatim and NOT sent to the default either — it
  # resolves to `@disabled_similarity`. Accepting 1.0 literally would still auto-unpublish
  # byte-identical captures (identical vectors score exactly 1.0) out of a setting that
  # means "stop"; sending it to the default RE-ENABLED the class at 0.80, which is the
  # behaviour the operator was disabling. Honouring an impossible threshold as a disable is
  # the only reading that is both what was asked for and the safe direction.
  # Public (`@doc false`) so the bound can be asserted as a pure function. The alternative
  # is mutating `:loopctl`'s application env from a test, which is banned here — it is
  # VM-global, so an `async: true` sibling would see another module's threshold. A guard on
  # the auto-unpublish path that nothing can test is a guard nobody can trust.
  @doc false
  @spec validate_similarity(term()) :: float()
  def validate_similarity(value)
      when (is_float(value) or is_integer(value)) and value > 0 and value < 1,
      do: value * 1.0

  def validate_similarity(value) when (is_float(value) or is_integer(value)) and value >= 1,
    do: @disabled_similarity

  def validate_similarity(value) do
    Logger.warning(
      "Consolidation: ignoring duplicate similarity threshold #{inspect(value)} — not a " <>
        "number strictly between 0.0 and 1.0 (0 would turn the corroboration gate OFF " <>
        "rather than disable the class; set 1.0 or more to disable it); " <>
        "using #{@default_min_duplicate_similarity}."
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
      where: fragment(unquote(@idempotency_key_sql <> " <> ''"), a.idempotency_key),
      group_by: fragment(unquote(@idempotency_key_sql), a.idempotency_key),
      having: count(a.id) > 1 and count(a.idempotency_key, :distinct) > 1,
      select: %{ids: fragment("array_agg(?::text ORDER BY ?, ?)", a.id, a.inserted_at, a.id)}
    )
    |> heavy_all(tenant_id)
    |> Enum.map(fn %{ids: ids} -> {@idempotency_drift, ids} end)
  end

  # `:contradiction_candidate` WAS a class here. It is not any more, and the reason is
  # ownership rather than value.
  #
  # `Loopctl.Workers.KnowledgeLintWorker.judge_redundant_conflicts/2` now resolves exactly
  # these pairs automatically, recording `classification: :redundant, disposition: :dismiss`.
  # The OWNERSHIP is what settles this, not a promise about latency: that drain is bounded by
  # a wall clock since #761 (~1,260 pairs a night gross, ~760 net of the promoter's own
  # share), so a backlog is worked through over days rather than cleared promptly — this
  # comment used to say "capped ABOVE the promotion rate so the queue converges", which read
  # as the latter. Proposing them here as well
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
  #
  # ONE query for both the page and the total (#617). This used to `heavy_all` every
  # matching id and then `Enum.take(ids, cap)` — shipping the whole matching set across the
  # wire to keep `cap` of it, purely because `total` is needed for the truncation flag.
  # `count(*) OVER ()` answers that from the same scan: splitting it into a COUNT plus a
  # LIMIT would evaluate the unindexable regexp-normalized title predicate over every
  # published row TWICE per run, each under its own 10s statement timeout, and a timeout on
  # either raises out of `analyze/2` whole — losing the duplicate_capture derivation, which
  # is the class that actually applies.
  defp generic_titles(tenant_id, cap) do
    rows =
      from(a in generic_title_base(tenant_id),
        order_by: [asc: a.inserted_at, asc: a.id],
        limit: ^cap,
        select: %{id: a.id, total: fragment("count(*) OVER ()")}
      )
      |> heavy_all(tenant_id)

    total = rows |> List.first(%{total: 0}) |> Map.fetch!(:total)
    selected = Enum.map(rows, & &1.id)
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

    # `false`: this class emits one article per proposal, so there are no members to cut.
    {total, items, false}
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
  # one from `evidence_map/2`, this blank, or a redaction. A caller reading `entry["title"]`
  # should get `nil` for an unresolvable article, not a KeyError-shaped absence that varies
  # by which article in one response it asked about.
  #
  # `idempotency_key` is NOT among those keys. It is write-side capture identity a caller
  # chose for itself, which is why it was removed from every article payload — and the
  # consolidation report is a payload like any other: it is served to any orchestrator+ key
  # for the exact article groups this pass grouped BY that key, and prior-day reports stay
  # addressable forever via `?day=`. Nothing on the apply path reads it; the grouping is
  # re-derived in SQL (`pair_candidates/3`).
  defp blank_evidence(article_id) do
    %{
      "article_id" => article_id,
      "title" => nil,
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

  # The live branch also DROPS `idempotency_key`, which reaches this function only from a
  # report persisted before the key stopped being copied into evidence. Read-time is where
  # those rows are served from, so it is the only seam that covers them — a report from
  # `?day=` two weeks ago goes out under today's rule, not the rule in force when it ran.
  defp redact_entry(%{"article_id" => id} = entry, live) do
    if MapSet.member?(live, id) do
      Map.delete(entry, "idempotency_key")
    else
      %{
        "article_id" => id,
        "title" => nil,
        "excerpt" => "",
        "redacted" => true
      }
    end
  end

  # Catch-all for an entry shape that carries no `article_id` (only a legacy/persisted one
  # can). It cannot be liveness-checked, but it must not be the one path that serves an
  # `idempotency_key` back: read-time redaction is unconditional or it is not a rule.
  defp redact_entry(entry, _live) when is_map(entry), do: Map.delete(entry, "idempotency_key")
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
  #
  # The `tenant_id` predicate is EXPLICIT (#617). This is an unqualified `delete_all`
  # on AdminRepo, which is BYPASSRLS — so RLS provides no backstop and the WHERE clause
  # is the ENTIRE tenant boundary. `report_id` happens to imply the tenant today (a
  # report row belongs to exactly one), so this is defence in depth rather than a live
  # cross-tenant delete; it is written out because the failure mode if that implication
  # ever stops holding is silent destruction of another tenant's rows, and a deletion
  # scoped only by a value derived elsewhere is a boundary you cannot see at the call
  # site. Every AdminRepo delete in a tenant-scoped context names its tenant.
  defp prune_proposals(tenant_id, report_id, proposals) do
    keep = Enum.map(proposals, & &1.fingerprint)

    from(p in ConsolidationProposal,
      where: p.tenant_id == ^tenant_id,
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
