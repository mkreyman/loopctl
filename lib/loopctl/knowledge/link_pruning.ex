defmodule Loopctl.Knowledge.LinkPruning do
  @moduledoc """
  Bounds `relates_to` degree by pruning the standing edge backlog to top-K (#611 stage 0).

  `ArticleLinkingWorker` now caps what it WRITES at `:article_max_relates_to_links`, but that
  cap is on outbound edges only and it arrived after the graph was already built. This module
  drains what is already there.

  ## Why the graph needed a bound at all

  A similarity threshold is not a bound. Above 0.6, `relates_to` admitted every kNN candidate,
  so each article contributed up to `max_comparisons` (50) outbound edges and accrued one
  inbound edge from every other article that reached it.

  MEASURED on the hosted corpus 2026-08-05, before any pruning:

  | | |
  |---|---|
  | published articles | 79,276 |
  | `relates_to` edges | 1,402,699 |
  | in the 0.60–0.70 band | 833,418 (59%) |
  | articles with 21+ edges | 44,496 (56%) |
  | edges surviving union-kNN top-10 | 499,058 |

  At that density any node reaches most of the corpus in two hops, so the graph asserts a
  relationship between nearly everything and therefore distinguishes nothing — the structural
  half of the same symptom `precision@20 = 0.038` reports from the retrieval side.

  ## Union-kNN, not mutual

  An edge survives if it is in the top-K of **either** endpoint. Mutual-kNN (both endpoints)
  would delete an edge that is A's single best relationship merely because it is not in B's
  top-K, which breaks the one guarantee that makes this safe to run unattended: **every
  article keeps its own K nearest.**

  That guarantee has a structural consequence worth stating, because it is what stops this
  interacting with the orphan re-linker: an article with at least one edge necessarily holds
  that edge at rank 1 of its own partition, and rank 1 is always inside top-K. **Pruning can
  never create an orphan.** `prune_would_orphan_nobody/1` is not a runtime check because it is
  a property of the ranking, but the test asserts it against real rows.

  ## Why deleting these rows is safe without a human

  Everything else in the nightly machinery is gated on reversibility (#605), and a DELETE is
  not reversible. The distinction that licenses it: a `relates_to` edge is a **derived
  artifact**, not a record. It is a pure function of two embeddings and a threshold, so
  `ArticleLinkingWorker` regenerates it — the same computation, against the same vectors. No
  human wrote any of them: measured on the hosted corpus, **zero** `relates_to` edges lack a
  machine-written `similarity_score`.

  That reasoning applies only to edges that carry their derivation, so the predicate is
  narrow and fails CLOSED. `prunable_predicate/0` requires ALL of:

  - `relationship_type = 'relates_to'` — `:potential_conflict` has its own threshold and its
    own draining consumer (`KnowledgeLintWorker.judge_redundant_conflicts/1`, capped above the
    promotion rate). Pruning it would withhold pairs from a queue designed to empty itself.
  - `metadata->>'auto_generated' = 'true'` — a hand-made link is not regenerable and is never
    touched. None exist today; this is what keeps that true if one is ever added.
  - `metadata->>'similarity_score' IS NOT NULL` — an edge with no recorded similarity cannot be
    ranked, so it cannot be shown to be outside anyone's top-K. Unrankable means unprunable.

  One further class is RANKED but SPARED WHILE IT IS STILL PROMOTER INPUT: a `relates_to` edge
  at or above `:knowledge_conflict_threshold` whose pair carries NO `:potential_conflict` edge
  yet. `KnowledgeLintWorker.promote_conflicts/1` sources its candidates EXCLUSIVELY from those
  rows, capped at 500/night against a much larger backlog, so deleting one before the promoter
  reaches it makes that pair permanently invisible to conflict detection.

  The spare mirrors BOTH halves of the promoter's own candidate query — the similarity floor
  AND its `not exists` clause — so it is RELEASED the moment the pair is flagged. Copying only
  the similarity half left every promoted pair permanently unprunable while it was no longer
  promoter input at all, accumulating in exactly the high-similarity region this pass exists to
  thin. While a spare holds, that edge may sit outside both endpoints' top-K: the degree bound
  is not reached for it, and it is NOT counted in `remaining`.

  ## Bounding

  One run deletes at most `:knowledge_link_prune_max_per_run` (default 250,000) edges,
  WORST-FIRST by similarity, in BATCHES — each its own short transaction whose CLIENT deadline
  is set ABOVE its `SET LOCAL statement_timeout`, so the server bound is the one that fires
  and no single AdminRepo connection (pool of 3) is held for minutes while the nightly fan-out
  runs. Each batch deletes and counts the remainder in ONE statement, so the ranking is never
  re-derived for a number the delete already knows. A batch that fails after earlier ones
  committed still reports what they deleted (`remaining: -1`). The pass converges: the
  write-side cap means the producer no longer outruns it.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.ExitTag
  alias Loopctl.LocalGuc

  @default_max_per_run 250_000
  # Rows per statement: re-deriving the ranking per batch (3.7 s on the hosted corpus) is the
  # price of RELEASING one of AdminRepo's three connections between batches.
  @batch_size 50_000
  # SERVER bound on one batch. The CLIENT deadline must EXCEED it or DBConnection aborts the
  # checkout first and the server bound can never fire — the pairing that
  # `:bulk_op_transaction_timeout_ms` exists for elsewhere. It has to be passed TWICE, on the
  # transaction AND on the statement: Ecto stores only the CONNECTION in the process dictionary,
  # never the transaction's opts, so a query inside the transaction otherwise falls back to the
  # repo's DEFAULT 15 s `:timeout` — below the server bound, which is the same inversion one
  # level down (`Knowledge.BulkOps` avoids it the other way, with a 10 s server bound).
  @statement_timeout_ms 30_000
  @transaction_timeout_ms @statement_timeout_ms + 5_000

  @doc "Per-article `relates_to` degree target — the K in top-K."
  @spec target_degree() :: pos_integer()
  def target_degree do
    Application.get_env(:loopctl, :article_max_relates_to_links, 10)
  end

  @doc "Maximum edges one run may delete."
  @spec max_per_run() :: pos_integer()
  def max_per_run do
    Application.get_env(:loopctl, :knowledge_link_prune_max_per_run, @default_max_per_run)
  end

  @doc """
  Prunes this tenant's `relates_to` edges to union-kNN top-K.

  Returns `{:ok, %{pruned: n, remaining: n}}`, or `{:error, reason}` when the FIRST batch
  failed and nothing committed. `remaining` is how many DELETABLE edges were still over the cap
  when the run stopped — zero means nothing is left that this pass is ALLOWED to delete, which
  is weaker than "the graph is at its target degree": an edge spared as promoter input (see the
  moduledoc) is over-degree and uncounted. `-1` means unmeasured.

  Opts: `:target_degree`, `:max_per_run` (both default to the config values above).
  """
  @spec prune(Ecto.UUID.t(), keyword()) ::
          {:ok, %{pruned: non_neg_integer(), remaining: integer()}} | {:error, term()}
  def prune(tenant_id, opts \\ []) do
    k = Keyword.get(opts, :target_degree, target_degree())
    cap = Keyword.get(opts, :max_per_run, max_per_run())

    with {:ok, %{pruned: pruned, remaining: remaining} = result} <- drain(tenant_id, k, cap, 0) do
      if pruned > 0 or remaining != 0 do
        Logger.info(
          "LinkPruning: tenant=#{tenant_id} relates_to pruned=#{pruned} remaining=#{remaining} " <>
            "target_degree=#{k} cap=#{cap}"
        )
      end

      {:ok, result}
    end
  end

  # A batch that fails AFTER earlier ones committed must not discard their tally: the caller
  # would then record `pruned: 0` for a night that really deleted rows, and this is the one
  # step in the nightly pass that deletes anything.
  defp drain(tenant_id, k, cap, pruned) do
    case delete_batch(tenant_id, k, min(@batch_size, cap - pruned)) do
      {:ok, {deleted, prunable}} ->
        pruned = pruned + deleted
        remaining = prunable - deleted

        if deleted == 0 or remaining == 0 or pruned >= cap do
          {:ok, %{pruned: pruned, remaining: remaining}}
        else
          drain(tenant_id, k, cap, pruned)
        end

      {:error, reason} ->
        partial(tenant_id, pruned, reason)
    end
  end

  defp partial(_tenant_id, 0, reason), do: {:error, reason}

  defp partial(tenant_id, pruned, reason) do
    Logger.error(
      "LinkPruning: tenant=#{tenant_id} batch failed (#{ExitTag.tag(reason)}) after #{pruned} " <>
        "edges were already committed; reporting those, with remaining=-1 (unmeasured)."
    )

    {:ok, %{pruned: pruned, remaining: -1}}
  end

  # The ranking is over edges INCIDENT to a node, so each edge is ranked twice — once from each
  # endpoint. `union all` materializes both sides; `rn <= k` on either keeps the edge. Deleting
  # worst-first makes a capped run drop the least defensible edges first.
  #
  # Delete AND remainder in ONE statement: the ranking is the expensive part (3.7 s over the
  # whole hosted corpus) and a separate count re-ran all of it for a number this statement
  # already holds. `doomed` is evaluated on the statement's snapshot, so `prunable - deleted`
  # is exact — every deleted edge was outside EVERY partition's top-K, so removing it cannot
  # promote another doomed edge into one.
  #
  # `NULLS LAST` and the `coalesce` are not decoration: `DESC` defaults to NULLS FIRST and
  # `NULL < 0.93` is NULL, so if the scoreless guard were ever loosened an UNRANKABLE edge
  # would rank BEST and be spared by the band — the most protected row rather than the least.
  defp delete_batch(tenant_id, k, limit) do
    LocalGuc.timed_transaction(
      AdminRepo,
      @statement_timeout_ms,
      fn ->
        %{rows: [[deleted, prunable]]} =
          AdminRepo.query!(
            """
            WITH e AS (
              SELECT id, source_article_id AS a, target_article_id AS b,
                     (metadata->>'similarity_score')::float AS sim
              FROM article_links
              WHERE tenant_id = $1 #{prunable_predicate()}
            ),
            sided AS (
              SELECT id, a AS node, sim FROM e
              UNION ALL
              SELECT id, b AS node, sim FROM e
            ),
            ranked AS (
              SELECT id, row_number() OVER (PARTITION BY node ORDER BY sim DESC NULLS LAST, id) AS rn
              FROM sided
            ),
            keep AS (SELECT DISTINCT id FROM ranked WHERE rn <= $2),
            doomed AS (
              SELECT e.id, e.sim FROM e
              LEFT JOIN keep ON keep.id = e.id
              WHERE keep.id IS NULL
                AND (coalesce(e.sim, 0) < #{conflict_band()} OR EXISTS (
                  SELECT 1 FROM article_links pc
                  WHERE pc.tenant_id = $1
                    AND pc.relationship_type = 'potential_conflict'
                    -- Only a SYSTEM flag lifts the >=0.93 spare (#730). The spare exists
                    -- to protect `promote_conflicts/1`'s only input, and it is safe to
                    -- lift once the pair IS flagged because the edge has then done its
                    -- job. An ASSERTED flag has not done that job: the pair was never
                    -- promoted, so lifting the spare on it let any agent delete the very
                    -- `relates_to` edge the promoter needs — a caller-triggered deletion
                    -- of system data, and permanent, since nothing recreates a pruned
                    -- edge below the linker's cap.
                    AND (pc.metadata->>'auto_generated') = 'true'
                    AND ((pc.source_article_id = e.a AND pc.target_article_id = e.b)
                      OR (pc.source_article_id = e.b AND pc.target_article_id = e.a))
                ))
            ),
            deleted AS (
              DELETE FROM article_links
              WHERE id IN (SELECT id FROM doomed ORDER BY sim ASC, id LIMIT $3)
              RETURNING 1
            )
            SELECT (SELECT count(*) FROM deleted), (SELECT count(*) FROM doomed)
            """,
            [Ecto.UUID.dump!(tenant_id), k, limit],
            timeout: @transaction_timeout_ms
          )

        {deleted, prunable}
      end,
      timeout: @transaction_timeout_ms
    )
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  # A numeric SQL literal by construction, never caller input.
  defp conflict_band, do: Float.to_string(conflict_threshold())

  defp conflict_threshold,
    do: Application.get_env(:loopctl, :knowledge_conflict_threshold, 0.93) * 1.0

  @doc """
  The SQL predicate selecting the edges this module RANKS — machine-derived, rankable
  `relates_to` only; the delete additionally spares a conflict-band pair the promoter has not
  reached yet (see the moduledoc).
  Exposed so the test can assert the guard is in the STATEMENT, not in whichever prose it read.
  """
  @spec prunable_predicate() :: String.t()
  def prunable_predicate do
    "AND relationship_type = 'relates_to' " <>
      "AND metadata->>'auto_generated' = 'true' " <>
      "AND metadata->>'similarity_score' IS NOT NULL"
  end

  @doc """
  Ecto query over the edges this module can RECLAIM from `tenant_id` — machine-derived,
  rankable `relates_to`. The conflict-band spare is deliberately not applied here: it is
  transient, released as soon as the promoter flags the pair, so a band edge is reclaimable in
  the long run.

  `ArticleLinkingWorker` derives its per-article write headroom from this, so the writer's
  bound and the pruner's target are ONE definition of degree. Where they differed, an edge this
  module can never free (hand-made, or scoreless and so unrankable) consumed a write slot
  forever and switched that article's auto-linking off with no path back.
  """
  @spec reclaimable_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def reclaimable_query(tenant_id) do
    from(l in Loopctl.Knowledge.ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.relationship_type == :relates_to,
      where: fragment("?->>'auto_generated' = 'true'", l.metadata),
      where: not is_nil(fragment("?->>'similarity_score'", l.metadata))
    )
  end
end
