defmodule Loopctl.Workers.ArticleLinkingWorker do
  @moduledoc """
  Oban worker that auto-discovers semantic relationships between articles
  using pgvector cosine similarity and creates `relates_to` links.

  Runs in the `:knowledge` queue with max 3 attempts. Enqueued by
  `ArticleEmbeddingWorker` after an embedding is successfully stored.

  ## Flow

  1. Fetch the article by `article_id` + `tenant_id`
  2. If article was deleted or has no embedding, return `:ok` (no-op)
  3. Query candidate articles via cosine similarity (1 - cosine distance)
  4. Filter candidates above the configured threshold
  5. Check existing links in both directions to avoid duplicates
  6. Create `relates_to` links with `auto_generated: true` metadata
  7. Log audit event `knowledge.articles_linked`

  ## Scoping (AC-21.2.3)

  - Project-scoped articles compare against same-project articles plus
    tenant-wide articles (project_id IS NULL).
  - Tenant-wide articles compare against all articles in the tenant.

  Since US-27.7a the similarity lookup runs through the shared
  `Loopctl.Knowledge.VectorSearch.nearest/4` (the index-correct HNSW kNN path on
  the HeavyRead pool), with the project scope applied as a post-ANN filter over the
  over-fetch pool. The worker therefore links among the GLOBAL-nearest pool that
  match the project, not the nearest-WITHIN-project — the documented post-ANN-filter
  tradeoff (see `find_similar_articles/4`). For the worker's small `max_comparisons`
  (default 50) against a generously sized pool the two are equivalent.

  ## Limits (AC-21.2.8 / AC-21.2.15)

  Configurable max comparisons via
  `Application.get_env(:loopctl, :article_link_max_comparisons, 50)`.
  A warning fires when the corpus size exceeds the limit. Since US-36.4 that
  corpus-size count is no longer paid on every job: it runs on a deterministic
  ~1/N sample (`:erlang.phash2(article_id, N) == 0`,
  `:article_link_corpus_sample_rate`) and emits the
  `Loopctl.TelemetryEvents.article_linking_corpus_size/0` event
  (`[:loopctl, :knowledge, :article_linking, :corpus_size]`) alongside the warning.
  The event is registered in `Loopctl.TelemetryEvents.all_events/0` and consumed in
  prod by `Loopctl.Telemetry.ScaleMetrics` as a `last_value` corpus-size gauge tagged
  by a cap-gated `tenant_id`, so the sampled signal reaches Prometheus/dashboards
  rather than terminating in a handler-less no-op. It is purely observational — never a
  gate on linking.
  Since US-27.7a the lookup
  runs through `VectorSearch.nearest/4`, whose `k` is clamped to
  `VectorSearch.max_k/0` (default 100), so a configured value above that ceiling is
  capped (a documented kNN cost bound); the default 50 is unaffected, and a clamp is
  logged once per job.

  ## Threshold (AC-21.2.4)

  Configurable via `Application.get_env(:loopctl, :article_link_threshold, 0.6)`.
  Only articles with cosine similarity >= threshold get linked.

  ## Degree cap (#611 stage 0)

  A threshold alone is not a bound. Above it, `relates_to` took EVERY candidate — up to
  `max_comparisons` (50) outbound edges per article, and degree is bidirectional, so an
  article also accrues one inbound edge per other article that reaches it. Measured on the
  hosted corpus before the cap: **1,402,699 `relates_to` edges over 79,276 published
  articles**, 59% of them between 0.60 and 0.70, and 56% of articles carrying 21+ edges.
  A graph that dense relates nearly everything to everything and so distinguishes nothing.

  `relates_to` is now capped at `:article_max_relates_to_links` (default 10) STORED edges per
  article, counting edges INCIDENT to it in either direction: the cut runs AFTER the
  already-linked rejection, so a re-link (nightly orphan pass, a re-embed) tops the article up
  to K rather than adding K more. `:potential_conflict` is NOT capped — it has its own
  threshold and its own draining consumer, and a second cap there would withhold pairs from a
  queue designed to converge.

  The cap bounds what this worker WRITES; it cannot retract the edges written before it
  existed, which is why #611 stage 0 also prunes the standing backlog. See
  `Loopctl.Knowledge.LinkPruning`.

  ## Retry Strategy (AC-21.2.13)

  Custom polynomial backoff: `attempt^4 + 15 + rand(0..30*attempt)`.

  ## Uniqueness (AC-21.2.14)

  Unique per `article_id` within a 300-second window.
  """

  use Oban.Worker,
    queue: :knowledge,
    max_attempts: 3,
    unique: [period: 300, keys: [:article_id]]

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Embeddings
  alias Loopctl.ExitTag
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.LocalGuc
  alias Loopctl.Oban.FairShare
  alias Loopctl.TelemetryEvents

  # Compile-time DI for the similarity lookup. The worker uses this to fetch
  # nearest-neighbour candidates; in tests it resolves to a Mox mock, in prod to VectorSearch.
  @similarity_search Application.compile_env(
                       :loopctl,
                       :article_similarity_search,
                       Loopctl.Knowledge.VectorSearch
                     )

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: id,
        args: %{"article_id" => article_id, "tenant_id" => tenant_id} = args
      }) do
    # US-36.2: per-tenant fair-share gate on the hot :knowledge queue (this worker
    # fires on every knowledge_create). Yield loss-free ({:snooze, n}, no attempt
    # consumed) when this tenant is at/above its fair share of executing slots.
    # `id` excludes THIS (already-executing) job from its own count — see FairShare.
    case FairShare.gate(tenant_id, :knowledge, id) do
      {:snooze, _n} = snooze -> snooze
      :ok -> link(article_id, tenant_id, args)
    end
  end

  defp link(article_id, tenant_id, args) do
    case Knowledge.get_article_with_embedding(tenant_id, article_id) do
      {:error, :not_found} ->
        # Article deleted -- no-op
        :ok

      {:ok, %Article{embedding: nil}} ->
        # No embedding yet -- no-op
        :ok

      {:ok, %Article{} = article} ->
        threshold = resolve_threshold(args)
        max_comparisons = clamped_max_comparisons()
        find_and_link_similar(article, tenant_id, threshold, max_comparisons)
    end
  end

  # Optional per-job threshold override (query-shaped, so it lives in args, not
  # config DI). KnowledgeLintWorker uses a LOWER threshold when re-linking orphans
  # so a totally-isolated article connects to its nearest neighbor instead of
  # near-missing the default cutoff forever. Falls back to the global config.
  defp resolve_threshold(args) do
    case Map.get(args, "threshold") do
      t when is_number(t) and t >= 0 -> t / 1
      _ -> Application.get_env(:loopctl, :article_link_threshold, 0.6)
    end
  end

  # `max_comparisons` flows to the kNN helper as `k`, which is clamped to
  # `VectorSearch.max_k/0` (US-27.7a cost bound). Surface that clamp once so an operator
  # who configured a higher value isn't silently capped (default 50 is well under it).
  defp clamped_max_comparisons do
    configured = Application.get_env(:loopctl, :article_link_max_comparisons, 50)
    max_k = VectorSearch.max_k()

    if configured > max_k do
      Logger.warning(
        "article_link_max_comparisons=#{configured} exceeds VectorSearch.max_k=#{max_k}; " <>
          "capping similarity comparisons at #{max_k}"
      )

      max_k
    else
      configured
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  # --- Private ---

  defp find_and_link_similar(article, tenant_id, threshold, max_comparisons) do
    maybe_emit_corpus_size(article, tenant_id, max_comparisons)

    case find_similar_articles(article, tenant_id, threshold, max_comparisons) do
      {:error, :heavy_read_overloaded} ->
        # US-37.5: the tenant is over its per-tenant HeavyRead slice, so the kNN read
        # was shed (`on_overload: :tag`). Yield LOSS-FREE with `{:snooze, n}` (no
        # attempt consumed, same as the FairShare gate above) rather than erroring —
        # a raised OverloadedError would burn attempts toward max_attempts and could
        # PERMANENTLY lose this article's auto-links under a sustained heavy-read
        # burst. Retried when the tenant's heavy-read load subsides.
        {:snooze, FairShare.snooze_seconds()}

      candidates when is_list(candidates) ->
        conflict_threshold = conflict_threshold()

        # A `relates_to` ambient link for the TOP-K nearest above the link threshold, PLUS a
        # `:potential_conflict` flag (route-the-findings #4) for pairs >= the conflict
        # threshold — too similar to comfortably coexist, for the consumer to resolve.
        # Dedup is type-aware so the two link types don't crowd each other out.
        #
        # The top-K cut is #611 stage 0, and it replaces an unconditional keep. Admitting
        # every candidate over the threshold made this an unbounded producer: `max_comparisons`
        # is 50, so each article could contribute 50 outbound edges, and degree is BIDIRECTIONAL
        # — an article also accrues an inbound edge from every other article that reaches it.
        # MEASURED before the cap: 1,402,699 `relates_to` edges over 79,276 published articles,
        # 59% of them in the 0.60–0.70 band (barely over the floor) and 56% of articles carrying
        # 21+ edges. At that density any node reaches most of the corpus in two hops, so the
        # graph asserts a relationship between nearly everything and therefore distinguishes
        # nothing — which is what `Knowledge.progressive_index/2`'s one-hop enrichment was
        # spending its budget on.
        #
        # `:potential_conflict` is deliberately NOT capped here. It has its own (much higher)
        # threshold and its own consumer — `KnowledgeLintWorker.judge_redundant_conflicts/1`
        # drains it, capped above the promotion rate — so a second cap would silently withhold
        # pairs from a queue that is already designed to converge.
        relates =
          build_links(
            article.id,
            candidates,
            tenant_id,
            :relates_to,
            fn _sim -> true end,
            max_relates_to_links()
          )

        conflicts =
          build_links(
            article.id,
            candidates,
            tenant_id,
            :potential_conflict,
            fn sim -> sim >= conflict_threshold end,
            :infinity
          )

        created_count = create_links(relates ++ conflicts, tenant_id)
        log_audit_event(article.id, tenant_id, created_count)
        :ok
    end
  end

  # The `headroom` nearest candidates, by similarity. `find_similar_articles/4` returns them
  # in kNN order already, but that ordering is the vector index's and this cut must not depend
  # on it: an explicit sort makes the bound a property of THIS function, so a future change
  # to the search path cannot silently turn "the best K" into "whichever K arrived first".
  # Ties break on id so the cut is deterministic across re-runs — a re-link that kept a
  # different arbitrary half each night would churn the graph forever.
  defp top_k(candidates, :infinity), do: candidates

  defp top_k(candidates, headroom) do
    candidates
    |> Enum.sort_by(fn %{similarity: sim, id: id} -> {-sim, id} end)
    |> Enum.take(headroom)
  end

  # K minus what this article ALREADY holds, which is what makes the cap a bound on STORED
  # degree rather than on one run's writes. The cut used to run on the candidate list BEFORE
  # the already-linked rejection below, so existing edges cost nothing against K and every
  # re-link (nightly orphan pass, a re-embed) could add K MORE — degree grew without bound
  # between prunes, and the write-side cap the moduledoc claims held per run only.
  defp headroom(:infinity, _existing), do: :infinity
  defp headroom(cap, existing), do: max(cap - existing, 0)

  # Per-article cap for `relates_to`. Kept well under `max_comparisons` (50) —
  # a cap at or above the candidate count is not a cap.
  defp max_relates_to_links do
    Application.get_env(:loopctl, :article_max_relates_to_links, 10)
  end

  defp build_links(article_id, candidates, tenant_id, type, keep?, cap) do
    existing = get_existing_link_pairs(article_id, tenant_id, type)

    candidates
    |> Enum.filter(fn %{similarity: sim} -> keep?.(sim) end)
    # Reject self-links AND already-linked pairs (both directions) in one pass. The
    # `cid == article_id` guard is defense-in-depth (US-36.4 review): the batched
    # `insert_all` path bypasses `ArticleLink.changeset/2`'s `validate_no_self_link`.
    # UNREACHABLE in prod — `find_similar_articles/4` always passes `exclude_id: article.id`
    # so the source can never be its own candidate — but a future caller/mock yielding a
    # self-referential candidate would otherwise insert an invalid self-link unvalidated.
    |> Enum.reject(fn %{id: cid} ->
      cid == article_id or MapSet.member?(existing, {article_id, cid}) or
        MapSet.member?(existing, {cid, article_id})
    end)
    # AFTER the rejection, so an already-linked pair does not consume a slot it already holds.
    |> top_k(headroom(cap, MapSet.size(existing)))
    |> Enum.map(fn %{id: target_id, similarity: score} ->
      %{
        source_article_id: article_id,
        target_article_id: target_id,
        relationship_type: type,
        metadata: %{"auto_generated" => true, "similarity_score" => score}
      }
    end)
  end

  defp conflict_threshold do
    Application.get_env(:loopctl, :knowledge_conflict_threshold, 0.93)
  end

  # US-27.7a: route the similarity lookup through the shared, scale-tested kNN helper
  # (`Loopctl.Knowledge.VectorSearch.nearest/4`) on the dedicated HeavyRead pool instead
  # of a bespoke `AdminRepo` cosine query. The helper's index-correct shape guarantees a
  # background link pass can never silently full-scan the corpus at prod scale (the rot
  # this epic targets) — the inner ANN is the pure `ORDER BY <=> LIMIT pool` HNSW path,
  # and the project scope is applied on the OUTER pool (`project_id` is in the
  # `articles(tenant_id, project_id, category)` btree, so an inner predicate would defeat
  # HNSW).
  #
  # BEHAVIOR PRESERVED: self exclusion, published-only, and the project scope
  # ("same-project OR tenant-wide" for a project-scoped source; no project filter for a
  # tenant-wide one) are unchanged — the latter via the helper's `:project_or_global` opt,
  # which mirrors the old `scope_by_project/2` exactly. The threshold boundary is
  # preserved for any POSITIVE `threshold`: we ask the helper for `threshold: 0.0` (no
  # floor in the indexed query) and keep the INCLUSIVE `sim >= threshold` filter in memory
  # here — the helper's own floor is strict `>`, so leaving the boundary check here keeps a
  # candidate whose similarity equals the (positive) threshold linkable, identical to the
  # pre-migration code. (Edge: at `threshold == 0.0` the helper's `> 0.0` floor — over the
  # `GREATEST(0, 1 - distance)` score — additionally drops exactly-orthogonal candidates
  # the old in-memory `>= 0.0` kept. This is a deliberate, harmless tightening for
  # auto-linking: a 0.0-similarity "relates_to" link is noise; the default threshold is 0.6.)
  #
  # RECALL NOTE (post-ANN-filter tradeoff): because the project scope now runs on the
  # OUTER pool (it must, to keep HNSW), the worker links among the GLOBAL-nearest `pool`
  # rows that THEN match the project — not the nearest-WITHIN-project. With a generously
  # sized pool (`pool_size(max_comparisons)`) this is equivalent for the small
  # `max_comparisons` (default 50) the worker uses; in a pathological corpus where a
  # project's matches all fall outside the global top-pool it could under-fill, the same
  # documented post-ANN-filter limitation `VectorSearch` carries for `tags`/`category`.
  defp find_similar_articles(article, tenant_id, threshold, max_comparisons) do
    # US-37.5: `on_overload: :tag` so an over-cap heavy-read shed returns
    # `{:error, :heavy_read_overloaded}` (propagated up to a loss-free `{:snooze, n}`
    # in `find_and_link_similar/4`) instead of raising and burning a job attempt.
    case @similarity_search.nearest(tenant_id, article.embedding, max_comparisons,
           exclude_id: article.id,
           project_or_global: article.project_id,
           threshold: 0.0,
           on_overload: :tag,
           pool: VectorSearch.pool_size(max_comparisons)
         ) do
      {:error, :heavy_read_overloaded} = err ->
        err

      candidates when is_list(candidates) ->
        # The helper returns `%{id, title, category, similarity_score}`; the linking
        # path keys on `:id` + `:similarity`, so map the score across and keep the
        # inclusive `>= threshold` boundary in memory (see the threshold note above).
        candidates
        |> Enum.map(fn %{id: id, similarity_score: score} -> %{id: id, similarity: score} end)
        |> Enum.filter(fn %{similarity: sim} -> sim >= threshold end)
    end
  end

  # US-36.4 (AC-36.4.1): the corpus-size-vs-limit warning used to run a full `count(*)`
  # over the tenant/project corpus on EVERY linking job — the hottest `:knowledge` job (one
  # per embedded article) — purely to feed a warning log. It now runs on a deterministic
  # ~1/N sample of jobs and emits a telemetry event alongside the warning, so the signal
  # stays observable without the per-job cost. It is NOT a gate: linking proceeds whether or
  # not this samples, so correctness is untouched (AC-36.4.3).
  defp maybe_emit_corpus_size(article, tenant_id, max_comparisons) do
    if sample_corpus_count?(article.id) do
      total = corpus_count(article, tenant_id)

      :telemetry.execute(
        TelemetryEvents.article_linking_corpus_size(),
        %{total: total, limit: max_comparisons},
        %{tenant_id: tenant_id, project_id: article.project_id, article_id: article.id}
      )

      if total > max_comparisons do
        Logger.warning(
          "Article linking: #{total} candidate articles exceeds limit of #{max_comparisons} " <>
            "for article #{article.id}"
        )
      end
    end

    :ok
  rescue
    e ->
      # AC-36.4.3 (US-36.4 review): the corpus-size count is PURELY observational — it must
      # NEVER gate linking. `corpus_count/2` wraps its aggregate in a `SET LOCAL
      # statement_timeout` transaction; a timeout raises `Postgrex.Error` (57014
      # query_canceled), and because a raise inside `AdminRepo.transaction/1` RE-RAISES (it
      # never becomes `{:error, _}`), an un-rescued count would abort `perform/1` BEFORE any
      # candidate is fetched or link inserted. Worse, sampling is deterministic by
      # `article_id`, so every one of the job's retries would re-sample, re-count, re-time-out,
      # then discard — silently leaving that article unlinked forever (a regression vs the
      # pre-US-36.4 count, which had no statement_timeout and so never crashed the job).
      # Rescue here — mirroring `ScaleMetrics`' poll rescues — so a slow/failed count degrades
      # only the optional corpus-size signal while the linking it merely observes proceeds.
      # `LocalGuc`'s capture ABORT arrives here as a `DBConnection.ConnectionError` like any
      # wedged-pool fault, but it is a deliberate refusal to override a GUC an enclosing scope
      # owns. It gets its own tag so it stays greppable/alertable rather than hiding inside a
      # generic count failure — and, like the ingestion backlog gate and the under-fill probe,
      # it still degrades SOFTLY. Re-raising here would abort a linking job over an
      # observational signal, which is the precise regression this rescue exists to prevent.
      tag = if LocalGuc.capture_abort?(e), do: "guc_capture_abort", else: "count_failed"

      Logger.warning(
        "Article linking: corpus-size count failed (#{tag}: #{inspect(e.__struct__)}) for " <>
          "article #{article.id}; skipping the observational corpus_size signal — " <>
          "linking proceeds"
      )

      :ok
  catch
    # `rescue` alone left the non-exception half open. A pool checkout against a wedged,
    # saturated or unstarted `AdminRepo` EXITS (`{:timeout, {DBConnection, ...}}`, `:noproc`)
    # rather than raising, so it walked straight past the clause above and aborted `perform/1`
    # over a purely observational count. Scope of the guarantee, exactly: a failure CONFINED
    # TO THE COUNT — of any of the three kinds — no longer aborts linking. A pool fault that
    # OUTLIVES the count still aborts the job at the next unguarded `AdminRepo` call
    # (`get_existing_link_pairs/3`, the batched insert); that one is a genuine linking failure
    # and belongs to Oban's retries, not to this block.
    #
    # `:throw` is caught alongside `:exit` because "every way this call can fail" has three
    # kinds, not two — the same pairing the fail-soft rate-limiter taggers use. Tagged, not
    # swallowed untagged, so the degraded signal stays greppable, via the ONE shared
    # `Loopctl.ExitTag` (four private copies of that clause list had already diverged on the
    # crash-propagation shape).
    :exit, reason ->
      Logger.warning(
        "Article linking: corpus-size count exited (#{ExitTag.tag(reason)}) for " <>
          "article #{article.id}; skipping the observational corpus_size signal — " <>
          "linking proceeds"
      )

      :ok

    :throw, value ->
      Logger.warning(
        "Article linking: corpus-size count threw (#{ExitTag.tag(value)}) for " <>
          "article #{article.id}; skipping the observational corpus_size signal — " <>
          "linking proceeds"
      )

      :ok
  end

  # Deterministic-by-id sampling so the same article always makes the same decision (stable
  # across a job's retries). `phash2(id, 1) == 0` always, so a rate of 1 samples every job;
  # a rate <= 0 disables the count entirely.
  defp sample_corpus_count?(article_id) do
    rate = Application.get_env(:loopctl, :article_link_corpus_sample_rate, 100)
    rate > 0 and :erlang.phash2(article_id, rate) == 0
  end

  # The corpus-size count itself: scope UNCHANGED from the pre-US-36.4 hot-path count
  # (self-excluded, published, embedded, project-scoped via `scope_by_project/2`), now wrapped
  # in a per-query `SET LOCAL statement_timeout` transaction (AC-36.4.4) so a slow count on a
  # large corpus can never hold an AdminRepo connection indefinitely.
  defp corpus_count(article, tenant_id) do
    {:ok, total} =
      LocalGuc.timed_transaction(AdminRepo, statement_timeout_ms(), fn ->
        article
        |> corpus_count_query(tenant_id)
        |> scope_by_project(article.project_id)
        |> AdminRepo.aggregate(:count)
      end)

    total
  end

  # US-41.1 (review): behind the cutover flag "is embedded" is a side-table row at
  # the tenant's active dimension. `articles.embedding` is never written for a
  # non-1536 dimension, so this count reported 0 for those tenants and the
  # over-limit operator warning it drives DISAPPEARED rather than being
  # wrong-but-visible. Both shapes carry the conjunctive tenant equality.
  defp corpus_count_query(article, tenant_id) do
    if Embeddings.side_table_reads_enabled?() do
      dimension = Embeddings.active_dimension(tenant_id)

      from(a in Article,
        join: ae in ArticleEmbedding,
        on: ae.article_id == a.id and ae.tenant_id == ^tenant_id and ae.dim == ^dimension,
        where: a.tenant_id == ^tenant_id,
        where: a.id != ^article.id,
        where: a.status == :published
      )
    else
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.id != ^article.id,
        where: not is_nil(a.embedding),
        where: a.status == :published
      )
    end
  end

  # Candidate-COUNT scoping for the over-limit warning only (a plain `count(*)`, NOT the
  # vector scan — the kNN lookup itself routes through `VectorSearch.nearest/4`). Mirrors
  # the historical scope: a tenant-wide article counts against the whole tenant; a
  # project-scoped one against same-project plus tenant-wide (`project_id IS NULL`).
  defp scope_by_project(query, nil), do: query

  defp scope_by_project(query, project_id) do
    where(query, [a], is_nil(a.project_id) or a.project_id == ^project_id)
  end

  defp get_existing_link_pairs(article_id, tenant_id, type) do
    from(l in ArticleLink,
      where: l.tenant_id == ^tenant_id,
      where: l.relationship_type == ^type,
      where: l.source_article_id == ^article_id or l.target_article_id == ^article_id,
      select: {l.source_article_id, l.target_article_id}
    )
    |> AdminRepo.all()
    |> MapSet.new()
  end

  # US-36.4 (AC-36.4.2/.4): persist discovered links with a single batched `insert_all` +
  # `on_conflict: :nothing` instead of row-by-row `AdminRepo.insert/1` in a loop. Correctness
  # is preserved — the SAME links are created:
  #
  #   * The reverse-direction (application-level) dedup still runs in `build_links/5` BEFORE
  #     we get here; the directional unique index can't cover it, so `on_conflict` doesn't
  #     replace it. `on_conflict: :nothing` on that index only guards same-direction
  #     idempotency / concurrent races, exactly what the old per-row constraint-skip did.
  #   * With `on_conflict: :nothing` a conflicting row is NOT counted, so the returned count
  #     still means "links actually created" — matching the prior `create_links/2` semantics
  #     that feeds `new_link_count` in the audit event.
  #
  # `tenant_id` and `inserted_at` are set explicitly on every row map: `tenant_id` is
  # programmatic (never cast — Multi-Tenant Rule 4), and `insert_all` does NOT populate the
  # schema's `timestamps(updated_at: false)`. The `:id` binary_id PK IS autogenerated by
  # `insert_all` from the schema. Rows are chunked to stay well under Postgres's 65535
  # bind-parameter ceiling (~6 params/row), and the whole batch runs inside a `SET LOCAL
  # statement_timeout` transaction.
  #
  # FK-violation parity with the pre-US-36.4 row-by-row path (US-36.4 review): the old
  # `create_links/2` inserted each row via `AdminRepo.insert(changeset)` and SKIPPED any
  # `{:error, changeset}` — so if EITHER endpoint article was HARD-deleted (soft deletes
  # retain the row → FK stays valid; only a hard delete removes it) between the VectorSearch
  # read and the insert, that row was dropped and the job still succeeded. BOTH FKs
  # (`source_article_id` and `target_article_id`) are `on_delete: :restrict`, so a batched
  # `insert_all` against a vanished endpoint would instead RAISE a `Postgrex.Error`
  # (`:foreign_key_violation`) that aborts the ENTIRE transaction — a strictly worse failure
  # mode. Rescuing is not an option: once a statement errors inside a transaction Postgres
  # aborts it, so any follow-up insert on that connection fails with "current transaction is
  # aborted" (and under the test Sandbox the transaction is nested, poisoning the outer one
  # too). Instead we PRE-FILTER to rows whose BOTH endpoints still exist
  # (`reject_vanished_endpoints/2`), INSIDE the same `SET LOCAL statement_timeout` transaction
  # as the insert (AC-36.4.4: reads on the path run under the per-query timeout) and right
  # before it (shrinking the check→insert race window). The source guard matters precisely
  # here: the article has no links yet, so `:restrict` does not block deleting it, and every
  # row shares that one source — a vanished source would FK-violate all of them. This
  # reproduces the old "skip the vanished endpoint, link the rest, no crash" behavior without
  # an aborted transaction, for one cheap indexed `id = ANY(...)` lookup only when there is
  # actual linking work. The residual window (an endpoint hard-deleted between this pre-filter
  # and the insert, same transaction) is far narrower than the original read→insert window; if
  # it is ever hit the job crashes and Oban retries, and the retry's `get_article_with_embedding`
  # / VectorSearch read no longer surfaces the deleted endpoint, so it converges.
  defp create_links([], _tenant_id), do: 0

  defp create_links(links, tenant_id) do
    now = DateTime.utc_now()

    rows =
      Enum.map(links, fn attrs ->
        %{
          tenant_id: tenant_id,
          source_article_id: attrs.source_article_id,
          target_article_id: attrs.target_article_id,
          relationship_type: attrs.relationship_type,
          metadata: attrs.metadata,
          inserted_at: now
        }
      end)

    {:ok, created} =
      LocalGuc.timed_transaction(AdminRepo, statement_timeout_ms(), fn ->
        rows
        |> reject_vanished_endpoints(tenant_id)
        |> Enum.chunk_every(insert_chunk_size())
        |> Enum.reduce(0, fn chunk, acc -> acc + insert_chunk(chunk) end)
      end)

    created
  end

  # Drop any row whose SOURCE or TARGET article no longer exists — the pre-US-36.4 row-by-row
  # path skipped these as `{:error, changeset}` FK failures and still succeeded; the batched
  # `insert_all` would raise and abort the whole batch instead (see `create_links/2`). Both
  # endpoint FKs are `on_delete: :restrict`. All rows share ONE source (the article being
  # linked, which has no links yet, so nothing blocks a concurrent hard-delete of it): if that
  # source vanished, every row would FK-violate, so drop the whole batch (matching the old
  # per-row path's "skip every row, return :ok/0"). Otherwise keep only rows whose target
  # still lives. Scoped by `tenant_id` (all endpoints are same-tenant). Runs INSIDE the
  # `create_links/2` statement-timeout transaction (AC-36.4.4). Returns the input untouched
  # when both endpoints of every row still exist.
  defp reject_vanished_endpoints([], _tenant_id), do: []

  defp reject_vanished_endpoints(rows, tenant_id) do
    source_ids = rows |> Enum.map(& &1.source_article_id) |> Enum.uniq()
    target_ids = rows |> Enum.map(& &1.target_article_id) |> Enum.uniq()

    live =
      from(a in Article,
        where: a.tenant_id == ^tenant_id,
        where: a.id in ^(source_ids ++ target_ids),
        select: a.id
      )
      |> AdminRepo.all()
      |> MapSet.new()

    if Enum.all?(source_ids, &MapSet.member?(live, &1)) do
      Enum.filter(rows, fn row -> MapSet.member?(live, row.target_article_id) end)
    else
      []
    end
  end

  defp insert_chunk(chunk) do
    {inserted, _} =
      AdminRepo.insert_all(ArticleLink, chunk,
        on_conflict: :nothing,
        conflict_target: [
          :tenant_id,
          :source_article_id,
          :target_article_id,
          :relationship_type
        ]
      )

    inserted
  end

  defp statement_timeout_ms,
    do: Application.get_env(:loopctl, :article_link_statement_timeout_ms, 3_000)

  defp insert_chunk_size,
    do: Application.get_env(:loopctl, :article_link_insert_chunk_size, 1_000)

  defp log_audit_event(article_id, tenant_id, created_count) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "article",
      entity_id: article_id,
      action: "knowledge.articles_linked",
      actor_type: "system",
      actor_id: nil,
      actor_label: "worker:article_linking",
      new_state: %{
        "article_id" => article_id,
        "new_link_count" => created_count
      }
    })
  end
end
