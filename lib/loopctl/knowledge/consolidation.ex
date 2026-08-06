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
  which the worker logs. `summary.corpus_size` counts PUBLISHED articles owned by
  this tenant — not its total article count.

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
  alias Loopctl.ExitTag
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ConsolidationProposal
  alias Loopctl.Knowledge.ConsolidationReport

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

  # How many CONFIRMED duplicate groups one nightly run may apply. Bounded because each
  # apply is a write on the shared admin pool, and because a bug that mis-picks winners
  # should be visible after one night rather than after the whole corpus.
  @default_max_applies 25

  # A GROUP cap is not an ARTICLE cap: one duplicate group can carry many members, so 25
  # groups is an unbounded number of unpublishes. This bounds the thing that is actually
  # irreversible-adjacent — loser articles pulled out of the published set in one night.
  @default_max_unpublishes 100

  # The classes `analyze/2` still PRODUCES, in the order proposals are numbered in. Distinct
  # from `ConsolidationProposal.classes()`, which is the schema enum and additionally carries
  # the retired values so historical rows load. Assembly iterates THIS list.
  @live_classes [:duplicate_capture, :generic_title]

  # How far apart the two agreeing reports may be, in days. One night's gap is normal (a
  # skipped run); anything wider is not the "two consecutive runs" the gate advertises.
  @max_confirmation_gap 2

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

  Two caps, in different units. `:max_applies` (default `#{@default_max_applies}`) bounds how
  many PROPOSALS are considered; `:max_unpublishes` (default `#{@default_max_unpublishes}`)
  bounds how many loser ARTICLES actually leave the published set. The second is the one that
  matters — a group can carry many members, so a group cap alone is not an article cap — and
  a group that would cross it is skipped WHOLE, never applied part-way, because a group with
  no winner is the one state neither the next run nor a reader can interpret.

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
  """
  @spec apply_confirmed_duplicates(Ecto.UUID.t(), keyword()) :: %{
          applied: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          gate: :open | :report_gap | :insufficient_history
        }
  def apply_confirmed_duplicates(tenant_id, opts \\ []) do
    cap = Keyword.get(opts, :max_applies, @default_max_applies)
    unpublish_cap = Keyword.get(opts, :max_unpublishes, @default_max_unpublishes)

    case confirmed_duplicate_proposals(tenant_id, cap) do
      {:error, reason} ->
        log_gate_blocked(tenant_id, reason)
        %{applied: 0, skipped: 0, failed: 0, gate: reason}

      {:ok, proposals} ->
        proposals
        |> Enum.reduce(
          %{applied: 0, skipped: 0, failed: 0, gate: :open},
          &tally_apply(tenant_id, &1, &2, unpublish_cap)
        )
    end
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
  defp tally_apply(tenant_id, proposal, acc, unpublish_cap) do
    # The group cap bounds how many PROPOSALS are considered; this bounds how many ARTICLES
    # actually leave the published set tonight. A group is skipped WHOLE rather than applied
    # part-way, because a half-applied group has no winner and is the one state neither the
    # next run nor a reader can interpret.
    if acc.applied + acc.failed >= unpublish_cap do
      %{acc | skipped: acc.skipped + 1}
    else
      do_tally_apply(tenant_id, proposal, acc)
    end
  end

  defp do_tally_apply(tenant_id, proposal, acc) do
    case apply_duplicate_group(tenant_id, proposal) do
      {:ok, applied, failed} ->
        %{acc | applied: acc.applied + applied, failed: acc.failed + failed}

      :skip ->
        %{acc | skipped: acc.skipped + 1}
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
    losers = max(length(proposal.article_ids) - 1, 1)

    Logger.error(
      "Consolidation: tenant=#{tenant_id} duplicate_capture proposal ##{proposal.number} " <>
        "could not be applied (#{tag}); #{losers} loser article(s) left published."
    )

    %{acc | failed: acc.failed + losers}
  end

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

  defp apply_duplicate_group(tenant_id, proposal) do
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
    # would unpublish the last copy of something.
    if length(live) < 2 do
      :skip
    else
      [winner | losers] =
        Enum.sort_by(live, fn a ->
          {-a.body_len, -DateTime.to_unix(a.updated_at, :microsecond), a.id}
        end)

      applied = Enum.count(losers, &unpublish_duplicate(tenant_id, &1))

      Logger.info(
        "Consolidation: tenant=#{tenant_id} applied duplicate_capture proposal " <>
          "##{proposal.number} — kept #{winner.id}, unpublished #{applied} of " <>
          "#{length(losers)} duplicate(s). Reversible via publish."
      )

      {:ok, applied, length(losers) - applied}
    end
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
  # Excludes agent-PRIVATE articles from everything this pass does. Composed into all THREE
  # places that build a "published article of this tenant" predicate — the scans
  # (`published_base/1`), the evidence fetch (`evidence_map/2`) and the apply-time live
  # re-check (`apply_duplicate_group/2`) — because a guard that lives in only one of them is
  # a guard the next reader adds a fourth path around.
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
  defp shared_only(query) do
    where(
      query,
      [a],
      fragment("COALESCE(?->>'visibility', 'shared') NOT IN ('private','owner')", a.metadata)
    )
  end

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
    groups =
      interleave(
        Enum.sort_by(title_drift_groups(tenant_id), fn {_r, ids} -> Enum.sort(ids) end),
        Enum.sort_by(idempotency_drift_groups(tenant_id), fn {_r, ids} -> Enum.sort(ids) end)
      )
      |> Enum.uniq_by(fn {_reason, ids} -> Enum.sort(ids) end)

    selected = Enum.take(groups, cap)
    evidence_by_id = evidence_map(tenant_id, Enum.flat_map(selected, fn {_r, ids} -> ids end))

    items =
      Enum.map(selected, fn {reason, ids} ->
        build_proposal(:duplicate_capture, ids, evidence_by_id,
          severity: "warning",
          rationale:
            "#{length(ids)} published articles are the same capture under #{reason} drift. " <>
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
      where:
        fragment("btrim(regexp_replace(lower(?), '[^[:alnum:]]+', ' ', 'g')) <> ''", a.title),
      where:
        fragment(
          "btrim(regexp_replace(lower(?), '[^[:alnum:]]+', ' ', 'g')) !~ ?",
          a.title,
          ^@generic_title_pattern
        ),
      group_by: fragment("btrim(regexp_replace(lower(?), '[^[:alnum:]]+', ' ', 'g'))", a.title),
      having: count(a.id) > 1,
      select: %{ids: fragment("array_agg(?::text ORDER BY ?)", a.id, a.inserted_at)}
    )
    |> heavy_all(tenant_id)
    |> Enum.map(fn %{ids: ids} -> {"title", ids} end)
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
    |> Enum.map(fn %{ids: ids} -> {"idempotency-tag", ids} end)
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
  defp live_evidence_ids(_tenant_id, []), do: MapSet.new()

  defp live_evidence_ids(tenant_id, article_ids) do
    ids = Enum.uniq(article_ids)

    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: a.status != :archived,
      where: a.id in ^ids,
      select: a.id
    )
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
