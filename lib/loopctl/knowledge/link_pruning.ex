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

  ## Bounding

  One run deletes at most `:knowledge_link_prune_max_per_run` (default 250,000) edges,
  WORST-FIRST by similarity, inside a `SET LOCAL statement_timeout` transaction. The remainder
  is returned and logged rather than silently dropped, and the pass converges: the write-side
  cap means the producer no longer outruns it.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.LocalGuc

  @default_max_per_run 250_000
  # Generous: the ranking CTE over the whole hosted corpus measured 3.7 s, and the delete is
  # keyed on primary keys. The timeout exists so a pathological plan cannot hold an AdminRepo
  # connection (pool of 3) for the rest of the night, not to bound the normal case.
  @statement_timeout_ms 120_000

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

  Returns `{:ok, %{pruned: n, remaining: n}}`. `remaining` is how many prunable edges were
  still over the cap when the run stopped — zero means the graph is at its target degree.

  Opts: `:target_degree`, `:max_per_run` (both default to the config values above).
  """
  @spec prune(Ecto.UUID.t(), keyword()) ::
          {:ok, %{pruned: non_neg_integer(), remaining: integer()}}
  def prune(tenant_id, opts \\ []) do
    k = Keyword.get(opts, :target_degree, target_degree())
    cap = Keyword.get(opts, :max_per_run, max_per_run())

    {:ok, pruned} =
      LocalGuc.timed_transaction(AdminRepo, @statement_timeout_ms, fn ->
        delete_prunable(tenant_id, k, cap)
      end)

    remaining = count_prunable(tenant_id, k)

    if pruned > 0 or remaining > 0 do
      Logger.info(
        "LinkPruning: tenant=#{tenant_id} relates_to pruned=#{pruned} remaining=#{remaining} " <>
          "target_degree=#{k} cap=#{cap}"
      )
    end

    {:ok, %{pruned: pruned, remaining: remaining}}
  end

  # The ranking is over edges INCIDENT to a node, which means each edge is ranked twice —
  # once from each endpoint. `union all` materializes both sides; `rn <= k` on either keeps
  # the edge. Deleting worst-first (`order by sim`) makes a capped run drop the least
  # defensible edges first, so a partially-drained graph is always better than it was.
  defp delete_prunable(tenant_id, k, cap) do
    %{num_rows: n} =
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
          SELECT id, row_number() OVER (PARTITION BY node ORDER BY sim DESC, id) AS rn
          FROM sided
        ),
        keep AS (SELECT DISTINCT id FROM ranked WHERE rn <= $2),
        doomed AS (
          SELECT e.id FROM e
          LEFT JOIN keep ON keep.id = e.id
          WHERE keep.id IS NULL
          ORDER BY e.sim ASC, e.id
          LIMIT $3
        )
        DELETE FROM article_links WHERE id IN (SELECT id FROM doomed)
        """,
        [Ecto.UUID.dump!(tenant_id), k, cap]
      )

    n
  end

  defp count_prunable(tenant_id, k) do
    %{rows: [[n]]} =
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
          SELECT id, row_number() OVER (PARTITION BY node ORDER BY sim DESC, id) AS rn
          FROM sided
        ),
        keep AS (SELECT DISTINCT id FROM ranked WHERE rn <= $2)
        SELECT count(*) FROM e LEFT JOIN keep ON keep.id = e.id WHERE keep.id IS NULL
        """,
        [Ecto.UUID.dump!(tenant_id), k]
      )

    n
  end

  @doc """
  The SQL predicate selecting edges this module may delete — machine-derived, rankable
  `relates_to` only.

  Exposed so the test can assert the guard is present in BOTH statements above rather than
  in whichever one it happened to read: a predicate that drifts between the delete and the
  count would report a backlog it is not allowed to drain, forever.
  """
  @spec prunable_predicate() :: String.t()
  def prunable_predicate do
    "AND relationship_type = 'relates_to' " <>
      "AND metadata->>'auto_generated' = 'true' " <>
      "AND metadata->>'similarity_score' IS NOT NULL"
  end

  @doc """
  Ecto query over the edges this module may delete, for callers that need to count or
  inspect them without hand-writing the predicate.
  """
  @spec prunable_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def prunable_query(tenant_id) do
    from(l in Loopctl.Knowledge.ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.relationship_type == :relates_to,
      where: fragment("?->>'auto_generated' = 'true'", l.metadata),
      where: not is_nil(fragment("?->>'similarity_score'", l.metadata))
    )
  end
end
