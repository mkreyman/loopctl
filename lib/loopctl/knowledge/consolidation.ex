defmodule Loopctl.Knowledge.Consolidation do
  @moduledoc """
  The nightly consolidation ("dream") pass over a tenant's PUBLISHED corpus — #584,
  stage 1 of 3: **report only, writes nothing**.

  The pass reconciles the corpus and emits NUMBERED proposals, each naming the
  articles involved and carrying a QUOTED excerpt from each as evidence. It writes
  its findings to `consolidation_reports` / `consolidation_proposals` and NOTHING
  else — no `articles`, `article_links` or `conflict_resolutions` write happens here.
  Stage 2 runs it nightly with human approve/reject for calibration; stage 3 will
  auto-apply only the class with a clean record.

  ## Why it consolidates published ARTICLES, not transcripts

  Session transcripts stay on the machines that produced them. A 2026-08-04 harvest
  found live API keys sitting in raw source material, so shipping transcripts to the
  server is an egress decision to be made deliberately, not a side effect of this
  pass. Capture keeps doing client-side extraction; this pass sees only what is
  already published here.

  ## Where it runs

  Inside the existing nightly `Loopctl.Workers.KnowledgeLintWorker` run (04:00 UTC,
  `all_tenants` fan-out) — deliberately NOT a second scheduler over the same corpus.
  It reuses that run's `Knowledge.lint/2` report for the stale class rather than
  re-scanning, and it never runs in a request path: the API endpoint reads the
  persisted rows.

  ## The four defect classes

  | Class | Signal |
  |---|---|
  | `:duplicate_capture` | two published articles whose titles collide once case/punctuation are normalized away, or whose `idempotency_key`s collide under the same normalization while differing verbatim (tag-format drift — novelty scoring and idempotency are separate paths, so the novelty gate does not catch it) |
  | `:contradiction_candidate` | a SYSTEM-flagged (`auto_generated`) `potential_conflict` link between two PUBLISHED articles with no `conflict_resolutions` verdict yet — reported INTO the existing conflict machinery, never a parallel store |
  | `:generic_title` | a placeholder title, which collides on per-tenant active-title uniqueness and blocks hub creation |
  | `:stale_entry` | past the lint staleness threshold and never reconciled |

  ## Counts and their denominators (#582 discipline)

  `summary.total_proposals` is the TRUE pre-cap count of PROPOSALS (not articles:
  one duplicate group of three articles is one proposal, and one article may appear
  in several proposals). `summary.by_class` is the same unit per class.
  `summary.emitted` is how many proposals the capped arrays actually carry —
  lower exactly when a class hit `max_per_class`, which `summary.truncated` flags and
  which the worker logs. `summary.corpus_size` counts PUBLISHED articles owned by
  this tenant — not its total article count.

  One caveat this pass cannot remove: `:stale_entry` is derived from the lint report
  handed in, so its TRUE total is lint's own pre-cap total, while the proposals it can
  emit are drawn only from lint's already-capped array.

  ## Reads never touch the heat index

  Article bodies are read straight through the repo, never `Knowledge.get_article/3`,
  which records a heat-counted `get` event. A whole-corpus nightly pass reading through
  the public path would make the pass itself rank the corpus.

  ## Where the reads run

  Every whole-corpus ENUMERATION here (the corpus count, the two normalization GROUP BYs,
  the conflict-link scan, the judged-pair set, the placeholder-title regex scan) goes
  through `Loopctl.HeavyRead` on the `:consolidation` endpoint, not straight through
  `AdminRepo`: those scans are unindexable by construction (they group on a
  `regexp_replace` expression) and `AdminRepo`'s pool is 3 connections shared with every
  other admin op, so an all-tenants nightly fan-out on the shared `:knowledge` queue can
  starve it. `HeavyRead` also gives each scan a `SET LOCAL statement_timeout` and the
  per-tenant in-flight shed. `analyze/3` holds ONE gate slot across the whole set
  (`with_slot/3`). The evidence fetch stays on `AdminRepo` — it is keyed by a bounded id
  list, not an enumeration — and so do the report/proposal WRITES.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.ConflictResolution
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

  `lint_report` is a `Loopctl.Knowledge.lint/2` result, reused for the `:stale_entry`
  class so the nightly run scans the corpus once.

  Opts: `:max_per_class` (default #{@default_max_per_class}, hard max
  #{@hard_max_per_class}).
  """
  @spec analyze(Ecto.UUID.t(), map(), keyword()) :: {:ok, map()}
  def analyze(tenant_id, lint_report, opts \\ []) do
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
           contradiction_candidate: contradiction_candidates(tenant_id, cap),
           generic_title: generic_titles(tenant_id, cap),
           stale_entry: stale_entries(tenant_id, lint_report, cap)
         }}
      end)

    by_class = Map.new(found, fn {class, {total, _items}} -> {to_string(class), total} end)

    truncated =
      Map.new(found, fn {class, {total, items}} -> {to_string(class), total > length(items)} end)

    proposals =
      ConsolidationProposal.classes()
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
  @spec run(Ecto.UUID.t(), map(), keyword()) :: {:ok, ConsolidationReport.t()}
  def run(tenant_id, lint_report, opts \\ []) do
    {:ok, analysis} = analyze(tenant_id, lint_report, opts)
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
  Reads a persisted report and its proposals. Never recomputes.

  Evidence is re-checked against the live published corpus on the way out: an entry whose
  article has since been hard-deleted, archived or unpublished is redacted to its id
  (`"redacted" => true`), so the stored excerpt never outlives the article it quotes.

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
            "Review the excerpts; keep the richest article and archive the rest, or merge them."
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
  # the class #584 names as the likely first auto-apply candidate, which would poison
  # exactly the calibration signal stage 2 exists to collect. ASCII behaviour is
  # identical under both classes ("Retry  Pattern!!" -> "retry pattern").
  #
  # The EMPTY normalized key is still excluded, and that exclusion is still load-bearing:
  # a title made only of symbols or emoji ("🚀", "!!!") normalizes to the empty string
  # under either class, and without the guard those all land in one group.
  defp title_drift_groups(tenant_id) do
    from(a in published_base(tenant_id),
      where:
        fragment("btrim(regexp_replace(lower(?), '[^[:alnum:]]+', ' ', 'g')) <> ''", a.title),
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
  defp idempotency_drift_groups(tenant_id) do
    from(a in published_base(tenant_id),
      where: not is_nil(a.idempotency_key),
      where:
        fragment(
          "btrim(regexp_replace(lower(?), '[^[:alnum:]]+', ' ', 'g')) <> ''",
          a.idempotency_key
        ),
      group_by:
        fragment("btrim(regexp_replace(lower(?), '[^[:alnum:]]+', ' ', 'g'))", a.idempotency_key),
      having: count(a.id) > 1 and count(a.idempotency_key, :distinct) > 1,
      select: %{ids: fragment("array_agg(?::text ORDER BY ?)", a.id, a.inserted_at)}
    )
    |> heavy_all(tenant_id)
    |> Enum.map(fn %{ids: ids} -> {"idempotency-tag", ids} end)
  end

  # Conflict-flagged pairs no agent has judged yet. Canonical (sorted) pair, matching
  # how `conflict_resolutions` stores its verdicts, so an existing verdict in either
  # link direction suppresses the proposal.
  #
  # The predicates MIRROR the conflict-resolution surface this proposal points at, because
  # a proposal whose `suggested_action` the surface would refuse is a dead end the pass
  # re-derives every night (nothing can record a verdict for it, so `judged_pairs/1` never
  # suppresses it, and it permanently occupies one of the per-class slots):
  #
  #   * `:potential_conflict` ONLY, and only SYSTEM-flagged (`auto_generated`) — the same
  #     two predicates `Knowledge.validate_potential_conflict_exists/3` requires (else
  #     `422 no_potential_conflict`) and `Knowledge.list_potential_conflicts/2` applies.
  #     `:contradicts` is PUBLICLY creatable by an `:agent` key, so including it also let
  #     an agent manufacture orchestrator-facing proposals at will.
  #   * BOTH endpoints PUBLISHED — every other class derives from `published_base/1`, and
  #     `archive_article/3` deliberately retains `article_links`, so without this an
  #     archived article kept producing proposals (quoting its body) while `corpus_size`
  #     excluded it: a proposal citing an article outside its own stated denominator.
  defp contradiction_candidates(tenant_id, cap) do
    pairs =
      from(l in ArticleLink,
        join: s in Article,
        on: s.id == l.source_article_id,
        join: t in Article,
        on: t.id == l.target_article_id,
        where: l.tenant_id == ^tenant_id,
        where: s.tenant_id == ^tenant_id,
        where: t.tenant_id == ^tenant_id,
        where: l.relationship_type == :potential_conflict,
        where: fragment("(?->>'auto_generated') = 'true'", l.metadata),
        where: s.status == :published,
        where: t.status == :published,
        select: %{
          source_article_id: l.source_article_id,
          target_article_id: l.target_article_id
        }
      )
      |> heavy_all(tenant_id)
      |> Enum.map(fn %{source_article_id: s, target_article_id: t} -> Enum.sort([s, t]) end)
      |> Enum.uniq()
      |> Enum.sort()

    judged = judged_pairs(tenant_id)
    unjudged = Enum.reject(pairs, &MapSet.member?(judged, &1))

    selected = Enum.take(unjudged, cap)
    evidence_by_id = evidence_map(tenant_id, List.flatten(selected))

    items =
      Enum.map(selected, fn ids ->
        build_proposal(:contradiction_candidate, ids, evidence_by_id,
          severity: "warning",
          rationale:
            "These two articles are flagged as conflicting but carry no recorded verdict. " <>
              "Compare the excerpts: a wrong rationale attached to a right conclusion reads as " <>
              "correct until the two are quoted side by side.",
          suggested_action:
            "Record a conflict resolution for the pair (dismiss / supersede / merge) via the " <>
              "existing conflict-resolution surface — this pass records no verdict."
        )
      end)

    {length(unjudged), items}
  end

  defp judged_pairs(tenant_id) do
    from(r in ConflictResolution,
      where: r.tenant_id == ^tenant_id,
      select: {r.source_article_id, r.target_article_id}
    )
    |> heavy_all(tenant_id)
    |> Enum.map(fn {s, t} -> Enum.sort([s, t]) end)
    |> MapSet.new()
  end

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

  # Reuses the lint report already computed by the nightly run. TRUE total is lint's
  # own pre-cap total; the emittable set is lint's already-capped array.
  defp stale_entries(tenant_id, lint_report, cap) do
    stale = Map.get(lint_report, :stale_articles, [])

    true_total =
      lint_report
      |> Map.get(:summary, %{})
      |> Map.get(:total_per_category, %{})
      |> Map.get(:stale_articles, length(stale))

    selected = Enum.take(stale, cap)
    evidence_by_id = evidence_map(tenant_id, Enum.map(selected, & &1.article_id))

    items =
      Enum.map(selected, fn entry ->
        build_proposal(:stale_entry, [entry.article_id], evidence_by_id,
          severity: "info",
          rationale: "Not updated in #{entry.days_since_update} days and never reconciled since.",
          suggested_action: "Re-verify against current practice, then update or archive."
        )
      end)

    {true_total, items}
  end

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

  defp blank_evidence(article_id) do
    %{"article_id" => article_id, "title" => nil, "excerpt" => ""}
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
  # IRREVERSIBLE hard delete (`Knowledge.BulkOps`) removes the row, and archive/unpublish
  # removes it from every other read surface, while the excerpt sits in
  # `consolidation_proposals.evidence` — and prior-day reports are addressable forever via
  # `?day=`, so the copy outlives the article indefinitely. This module states its own
  # motivation as keeping sensitive source material off the server; a hard delete that
  # does not remove the quoted body contradicts it.
  #
  # The copy is therefore RE-CHECKED at read time against the live published corpus, and
  # any entry whose article no longer resolves is redacted down to its id. Read-time is
  # the right seam: it also covers the article that was archived after the pass ran, and
  # it needs no reaper for reports nobody reads.
  defp redact_stale_evidence(_tenant_id, []), do: []

  defp redact_stale_evidence(tenant_id, proposals) do
    live = live_published_ids(tenant_id, Enum.flat_map(proposals, & &1.article_ids))

    Enum.map(proposals, fn proposal ->
      %{proposal | evidence: Enum.map(proposal.evidence, &redact_entry(&1, live))}
    end)
  end

  defp redact_entry(%{"article_id" => id} = entry, live) do
    if MapSet.member?(live, id) do
      entry
    else
      %{"article_id" => id, "title" => nil, "excerpt" => "", "redacted" => true}
    end
  end

  defp redact_entry(entry, _live), do: entry

  defp live_published_ids(_tenant_id, []), do: MapSet.new()

  defp live_published_ids(tenant_id, article_ids) do
    ids = Enum.uniq(article_ids)

    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: a.status == :published,
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
