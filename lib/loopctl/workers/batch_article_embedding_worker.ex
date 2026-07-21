defmodule Loopctl.Workers.BatchArticleEmbeddingWorker do
  @moduledoc """
  Oban worker that embeds a BATCH of articles in ONE provider array call (US-37.4).

  This is the truly-bulk background ingest counterpart to
  `Loopctl.Workers.ArticleEmbeddingWorker` (which embeds a single article on the
  interactive publish path). Enqueued by every BULK background path — `Knowledge`
  bulk publish (`enqueue_bulk_embeddings/2`), `ContentIngestionWorker` auto-publish
  ingest, and the `KnowledgeLintWorker` orphan-embedding backfill — each of which
  chunks its rows into groups of `Knowledge.embedding_batch_max/0` (~100) and
  enqueues one job per chunk. The interactive single-article/memory/promotion paths
  stay per-record (write-then-recall guarantee).

  Each chunk is embedded via the GUARDED `Knowledge.generate_embeddings/3`, which
  sends `input` as an array and maps each returned vector back to its input BY the
  response `index` field (never by position). Within a job the chunk is further
  sub-split by a cumulative CHARACTER budget (`Knowledge.embedding_batch_max_chars/0`)
  so no single array call exceeds the provider's per-request token ceiling; each
  sub-batch takes one admission token (US-37.1) and one concurrency slot (US-37.2),
  cutting provider round-trips ~100x vs. per-article fan-out.

  ## Flow

  1. US-36.2 per-tenant `FairShare.gate` for the `:embeddings` slot — ONE gate for
     the batch (loss-free `{:snooze, n}` when this tenant is at/above its fair share).
  2. Fetch every article in the chunk (with `embedding` + content-hash). Deleted /
     wrong-tenant ids are silently dropped.
  3. IDEMPOTENCY: articles whose stored content-hash already matches the current
     content are skipped (no provider call, re-ensure linking) — an Oban retry after
     a post-embed failure never re-bills the tenant.
  4. Embed the remaining texts in ONE `Knowledge.generate_embeddings/3` array call;
     zip the returned vectors (input order, guaranteed by the client's by-index map)
     back onto their articles and store each via `Knowledge.update_embedding/4`, then
     enqueue linking.

  ## Partial failure = whole-batch retry (AC-37.4.3)

  Vectors are written ONLY after a successful provider call returns every vector, so
  a provider error means ZERO writes — the batch fails/retries as a unit (no silent
  half-write). On a retry the already-stored rows are idempotent no-ops.

  ## Error taxonomy (MIRRORS `ArticleEmbeddingWorker` exactly)

  - `{:error, :no_api_key}` (mandatory BYO) → `{:discard, {:no_embedding_key, _}}`.
  - `{:error, :rate_limited_local}` (US-37.1 node-local admission) → `{:snooze, n}`.
  - `{:error, :circuit_open}` (US-37.3 breaker open) → `{:snooze, remaining_cooldown}`.
  - throttle 4-tuple with a provider `Retry-After` → `{:snooze, retry_after}`.
  - permanent provider error (4xx bad/revoked key) → `{:discard, {:embedding_permanent_error, _}}`.
  - transient (5xx / network / timeout) → `{:error, reason}` for Oban retry.

  ## Uniqueness

  Unique per `article_ids` within a 300-second window; a duplicate chunk while one is
  pending replaces the existing job.
  """

  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 4,
    unique: [keys: [:article_ids], period: 300],
    replace: [scheduled: [:args, :scheduled_at]]

  require Logger

  import Loopctl.Egress, only: [is_egress_refusal: 1]

  alias Loopctl.Custody
  alias Loopctl.Egress
  alias Loopctl.Egress.Scope
  alias Loopctl.Embeddings
  alias Loopctl.Knowledge
  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Oban.FairShare
  alias Loopctl.Provider.Admission
  alias Loopctl.Provider.RetryAfter
  alias Loopctl.SystemConfig
  alias Loopctl.Workers.ArticleLinkingWorker

  # Task.yield budget for a batch provider call. Review (MED #3): this was a
  # hardcoded 8s compile-time constant tuned for a SINGLE text — it neither scaled
  # with the ~100-input array the batch path sends nor could an operator raise it,
  # so it would shut the task down before a raised `embedding_receive_timeout_ms`
  # could take effect and would systematically time out a legitimately slow large
  # batch. Now: live-tunable via SystemConfig AND scaled by the sub-batch text count
  # (base + per-item), so the yield grows with the payload. The client's batch
  # receive_timeout is derived from the SAME shape (a strictly smaller base) so the
  # HTTP call always fails cleanly BEFORE the yield shuts the task — see
  # `EmbeddingClient.batch_receive_timeout_ms/1`.
  @default_yield_base_ms 8_000
  @default_yield_per_item_ms 100
  @max_text_length 32_000

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: id,
        args: %{"article_ids" => article_ids, "tenant_id" => tenant_id}
      })
      when is_list(article_ids) do
    # US-36.2: ONE per-tenant fair-share gate for the whole batch. `id` excludes THIS
    # already-executing job from its own count — see FairShare.
    case FairShare.gate(tenant_id, :embeddings, id) do
      {:snooze, _n} = snooze -> snooze
      :ok -> embed_batch(tenant_id, article_ids)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  defp embed_batch(tenant_id, article_ids) do
    articles = Knowledge.get_articles_with_embedding_status(tenant_id, article_ids)

    # Split into (a) already-embedded (idempotent skip — re-ensure linking) and
    # (b) to-embed `{article, text, content_hash}` tuples. The paid provider only
    # sees (b).
    {to_embed, already} =
      articles
      |> Enum.map(fn article ->
        text = build_embedding_text(article)
        {article, text, content_hash(text)}
      end)
      |> split_to_embed(tenant_id)

    Enum.each(already, fn {article, _text, _hash} -> enqueue_linking(article.id, tenant_id) end)

    generate_and_store(tenant_id, to_embed)
  end

  defp generate_and_store(_tenant_id, []), do: :ok

  # AC-37.4.4 (review MED #2): in ADDITION to the count cap applied at enqueue
  # (`Knowledge.embedding_batch_max/0`), bound each provider array call by a
  # CUMULATIVE character budget (`Knowledge.embedding_batch_max_chars/0`). A chunk of
  # many large-text articles (100 × ~32K chars ≈ 3.2M chars ≈ 800k tokens) can
  # otherwise exceed an OpenAI-compatible per-request token ceiling (~300k) and return
  # a permanent HTTP 400 that discards the whole chunk. Sub-split into groups under the
  # char budget; each sub-batch is ONE provider call (one admission token + one slot)
  # embedded+stored before the next, so an Oban retry idempotently skips already-stored
  # sub-batches (no re-bill). Stops at the first non-`:ok` sub-batch result
  # (snooze/discard/error), which the perform/1 caller returns to Oban.
  defp generate_and_store(tenant_id, to_embed) do
    to_embed
    # US-41.4 (AC-41.4.2): group by the article's PROJECT first, so every provider
    # array call carries exactly ONE egress scope. Mixing projects into one call would
    # force a single scope on articles with different markings — and the only safe
    # single scope would be the most restrictive one, which would block articles that
    # are not marked. Grouping keeps each decision exact.
    |> Enum.group_by(fn {article, _text, _hash} -> article.project_id end)
    |> Enum.reduce_while(:ok, fn {project_id, group}, :ok ->
      case generate_and_store_project_group(tenant_id, project_id, group) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  defp generate_and_store_project_group(tenant_id, project_id, to_embed) do
    to_embed
    |> chunk_by_char_budget(Knowledge.embedding_batch_max_chars())
    |> Enum.reduce_while(:ok, fn sub_batch, :ok ->
      case embed_and_store_sub_batch(tenant_id, project_id, sub_batch) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  # Greedy split of `to_embed` tuples into sub-batches whose cumulative text
  # `byte_size` stays at/under `max_chars`. A single input larger than the budget
  # (already sliced to `@max_text_length`) still forms its own sub-batch rather than
  # wedging into an empty one.
  defp chunk_by_char_budget(to_embed, max_chars) do
    chunk_fun = fn {_article, text, _hash} = item, {acc, size} ->
      len = byte_size(text)

      cond do
        acc == [] -> {:cont, {[item], len}}
        size + len > max_chars -> {:cont, Enum.reverse(acc), {[item], len}}
        true -> {:cont, {[item | acc], size + len}}
      end
    end

    after_fun = fn
      {[], _size} -> {:cont, [], {[], 0}}
      {acc, _size} -> {:cont, Enum.reverse(acc), {[], 0}}
    end

    Enum.chunk_while(to_embed, {[], 0}, chunk_fun, after_fun)
  end

  defp embed_and_store_sub_batch(tenant_id, project_id, to_embed) do
    texts = Enum.map(to_embed, fn {_article, text, _hash} -> text end)

    opts = [timeout: batch_yield_ms(length(texts)), project_id: project_id]

    # US-41.7 (AC-41.7.1): this is the BULK path — the harvest load profile the
    # custody story is scoped around — and every article's body in `texts` is
    # shipped to the resolved embedding endpoint. Each therefore gets its OWN
    # posture entry, recorded BEFORE the call so a batch that egressed and then
    # failed leaves recorded operations rather than a contiguous sequence that
    # omits them. Uninstrumented, this path would read as COMPLETE / all-local for
    # a row whose body went to a vendor.
    recorded = record_batch_custody(tenant_id, project_id, to_embed)
    result = Knowledge.generate_embeddings(tenant_id, texts, opts)

    Enum.each(
      recorded,
      &Custody.record_outcome(&1, if(match?({:ok, _}, result), do: :succeeded, else: :failed))
    )

    case result do
      {:ok, vectors} when length(vectors) == length(to_embed) ->
        store_all(tenant_id, Enum.zip(to_embed, vectors))

      {:ok, _mismatch} ->
        # Defensive: the guarded client already fails a short/misaligned batch with an
        # error; a length mismatch here is a contract violation — retry the batch.
        {:error, :embedding_batch_length_mismatch}

      {:error, reason} ->
        handle_batch_error(tenant_id, to_embed, reason)
    end
  end

  # `:reembed` when the article already carried a vector, so a model/endpoint
  # switch (US-41.1 AC-41.1.10) is legible as its own operation. One INSERT per
  # article on the batch's own connection — the CHAIN append stays batched out to
  # Oban (AC-41.7.7), so this adds no per-article AdminRepo chain round-trip.
  defp record_batch_custody(tenant_id, project_id, to_embed) do
    subjects =
      Enum.map(to_embed, fn {article, _text, _hash} ->
        operation = if article.has_embedding, do: :reembed, else: :embed
        {"article", article.id, operation}
      end)

    Custody.record_all(Scope.new(tenant_id, project_id), subjects)
  end

  # Every error branch lives in its own function so `embed_and_store_sub_batch/2`
  # stays under the credo --strict cyclomatic-complexity ceiling as US-41.4 adds
  # the terminal `:egress_blocked` / `:pin_stale` cancellation.
  defp handle_batch_error(tenant_id, to_embed, reason)

  defp handle_batch_error(tenant_id, to_embed, :no_api_key),
    do: skip_no_embedding_key(tenant_id, to_embed)

  # US-41.4 (AC-41.4.3): the ONE mapping from an egress refusal to an Oban outcome
  # lives in `Loopctl.Egress.oban_result/1`: `:egress_blocked` CANCELS (a permanent
  # configuration state; no data was sent), `:pin_stale` / `:egress_unavailable`
  # SNOOZE (recoverable — cancelling would silently strand the batch). The cancel
  # reason NAMES the scope and the offending endpoint (AC-41.4.6).
  defp handle_batch_error(_tenant_id, _to_embed, refusal)
       when is_egress_refusal(refusal),
       do: Egress.oban_result(refusal)

  # US-37.1 (AC-37.1.4): node-local admission backpressure is loss-free — snooze
  # the slot (no attempt consumed) so the batch retries once demand subsides.
  defp handle_batch_error(_tenant_id, _to_embed, :rate_limited_local),
    do: {:snooze, Admission.snooze_seconds()}

  # US-37.3 (AC-37.3.5): breaker OPEN — snooze loss-free for ~the remaining open
  # window rather than {:error, ...} (which could burn every attempt and DISCARD
  # the batch while the breaker stays open, stranding the articles un-embedded).
  defp handle_batch_error(tenant_id, _to_embed, :circuit_open),
    do: {:snooze, circuit_open_snooze_seconds(tenant_id)}

  # US-37.3 (AC-37.3.3): provider throttle with a Retry-After — snooze loss-free
  # for ~that interval instead of the blind polynomial backoff.
  defp handle_batch_error(
         _tenant_id,
         _to_embed,
         {:api_error, _status, :provider_error, retry_after}
       )
       when is_integer(retry_after),
       do: {:snooze, RetryAfter.snooze_seconds(retry_after)}

  defp handle_batch_error(tenant_id, to_embed, reason) do
    # No partial writes happened (we only store after a full success), so the whole
    # batch fails/retries as a unit (AC-37.4.3). The Oban error term is SANITIZED.
    sanitized = ProviderError.sanitize(reason)

    if Llm.permanent_provider_error?(reason) do
      Logger.debug(
        "BatchArticleEmbeddingWorker: tenant=#{tenant_id} batch=#{length(to_embed)} permanent " <>
          "embedding error (#{ProviderError.log_tag(reason)}); discarding."
      )

      {:discard, {:embedding_permanent_error, sanitized}}
    else
      {:error, sanitized}
    end
  end

  # Store every vector against its article + enqueue linking. A store failure (other
  # than :not_found, which means the row was deleted mid-flight — a benign skip)
  # returns {:error, _} so Oban retries the whole batch; already-stored rows are
  # idempotent no-ops on the retry.
  defp store_all(tenant_id, article_vector_pairs) do
    # AC-41.1.11: ONE dimension resolution for the WHOLE ~100-article batch, threaded
    # into every write. `Knowledge.update_embedding/4` resolves per call (a tenants
    # SELECT + a settings read), so the /4 form here was 100 tenant lookups per batch.
    dimension = Embeddings.resolve_write_dimension(tenant_id)

    Enum.reduce_while(article_vector_pairs, :ok, fn {{article, _text, hash}, vector}, :ok ->
      case Knowledge.update_embedding(tenant_id, article.id, vector, hash, dimension) do
        {:ok, _updated} ->
          enqueue_linking(article.id, tenant_id)
          {:cont, :ok}

        {:error, :not_found} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # Snooze interval (seconds) for the OPEN-breaker path: ~the remaining cooldown,
  # floored at `Admission.snooze_seconds/0` (always >= 1) so a just-expired/raced
  # window still yields a positive, loss-free re-snooze.
  defp circuit_open_snooze_seconds(tenant_id) do
    max(Knowledge.circuit_breaker_cooldown_remaining(tenant_id), Admission.snooze_seconds())
  end

  # Mandatory BYO: the tenant has no embedding key. Cleanly DISCARD the whole batch
  # (no retry, no crash, no operator-key fallback), emitting one telemetry signal +
  # audit entry per article so keyless-tenant volume stays observable and consistent
  # with the per-article worker.
  defp skip_no_embedding_key(tenant_id, to_embed) do
    Enum.each(to_embed, fn {article, _text, _hash} ->
      :telemetry.execute(
        [:loopctl, :embedding, :skipped_no_key],
        %{count: 1},
        %{tenant_id: tenant_id, article_id: article.id, source: "article"}
      )

      Llm.record_blocked(tenant_id, :embedding)
    end)

    Logger.debug(
      "BatchArticleEmbeddingWorker: tenant=#{tenant_id} batch=#{length(to_embed)} skipped — no " <>
        "embedding API key configured (mandatory BYO)."
    )

    {:discard, {:no_embedding_key, Enum.map(to_embed, fn {a, _t, _h} -> a.id end)}}
  end

  # IDEMPOTENCY, at the ACTIVE dimension (review). `has_embedding` is
  # `not is_nil(articles.embedding)`, a column `Knowledge.update_embedding/5` NEVER
  # writes for a non-1536 dimension — so for exactly the 768/1024 tenants this epic
  # serves, EVERY article of EVERY batch looked unembedded and each enqueue re-billed
  # the provider for the whole batch. Behind the cutover flag the check reads the
  # side table's recorded hashes instead, in ONE query for the whole batch
  # (AC-41.1.11: no per-item lookup).
  defp split_to_embed(entries, tenant_id) do
    hashes = side_table_hashes(tenant_id, entries)

    Enum.split_with(entries, fn {article, _text, hash} ->
      not already_embedded?(article, hash, hashes)
    end)
  end

  defp side_table_hashes(tenant_id, entries) do
    if Embeddings.side_table_reads_enabled?() do
      Embeddings.article_embedded_hashes(
        tenant_id,
        Enum.map(entries, fn {article, _text, _hash} -> article.id end),
        Embeddings.active_dimension(tenant_id)
      )
    else
      nil
    end
  end

  defp already_embedded?(article, content_hash, hashes) when is_map(hashes),
    do: Map.get(hashes, article.id) == content_hash

  defp already_embedded?(article, content_hash, _hashes),
    do: legacy_already_embedded?(article, content_hash)

  defp legacy_already_embedded?(
         %{has_embedding: true, embedding_content_hash: hash},
         content_hash
       )
       when is_binary(hash),
       do: hash == content_hash

  defp legacy_already_embedded?(_article, _content_hash), do: false

  defp content_hash(text) do
    :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
  end

  defp enqueue_linking(article_id, tenant_id) do
    ArticleLinkingWorker.new(%{article_id: article_id, tenant_id: tenant_id})
    |> Oban.insert()
  end

  defp build_embedding_text(article) do
    "#{article.title}\n\n#{article.body}"
    |> String.slice(0, @max_text_length)
  end

  # Task.yield budget (ms) for a sub-batch provider call — live-tunable via
  # SystemConfig and SCALED by the input count so a ~100-array call gets
  # proportionally more slack than a single text (review MED #3). Both knobs default
  # to the in-code values on a cache miss. The client's batch receive_timeout uses
  # the same base+per-item shape with a strictly smaller base, so the HTTP call
  # always fails cleanly before this yield shuts the task down.
  defp batch_yield_ms(text_count) do
    base = SystemConfig.get_int("embedding_batch_yield_base_ms", @default_yield_base_ms)

    per_item =
      SystemConfig.get_int("embedding_batch_yield_per_item_ms", @default_yield_per_item_ms)

    base + per_item * max(text_count, 1)
  end
end
