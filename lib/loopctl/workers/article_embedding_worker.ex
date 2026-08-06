defmodule Loopctl.Workers.ArticleEmbeddingWorker do
  @moduledoc """
  Oban worker that generates and stores vector embeddings for articles.

  Runs in the `:embeddings` queue with concurrency 5. When an article is
  created or updated with content changes (title/body) and is in `:published`
  status, this worker is enqueued to generate an embedding vector via the
  configured embedding client.

  ## Flow

  1. Fetch the article (with its embedding + content-hash) by `article_id` + `tenant_id`
  2. If article was deleted, return `:ok` (no-op)
  3. Build embedding text: `"{title}\\n\\n{body}"`, cut by
     `Loopctl.Embeddings.TextBudget.initial/1` — the same 32,000-CHARACTER cap that
     predates the ladder, so nothing the provider already accepted is shortened.
     A character cap does not BOUND tokens, which is why step 7b exists; bounding
     the first attempt in bytes instead would silently gut the multi-byte articles
     that fit. See `TextBudget` for both halves of that argument.
  4. IDEMPOTENCY (review #12): if the article already carries an embedding whose
     stored content-hash matches the current content, skip the paid provider call
     entirely (re-ensure linking, return `:ok`). This stops an Oban retry after a
     post-embed failure from re-billing the tenant for identical content.
  5. Otherwise generate via the GUARDED `Knowledge.generate_embedding/3` (review #4:
     tenant-scoped circuit breaker + timeout) and store via `Knowledge.update_embedding/4`
  6. On `{:error, :no_api_key}` (mandatory BYO — the tenant has no embedding key),
     `{:discard, {:no_embedding_key, article_id}}` — a CLEAN skip: no crash, no
     retry, no operator-key fallback. The article stays created; it is simply not
     vector-searchable until the tenant configures a key.
  7. On a PERMANENT provider error (a 4xx other than 408/429 — bad/revoked key),
     `{:discard, {:embedding_permanent_error, _}}` (review #5): retrying a revoked
     key 3× is pointless. Transient errors (5xx / network / timeout) return
     `{:error, reason}` for Oban retry.
  7b. EXCEPT `:context_length_exceeded`, which is permanent for the text SENT but
     not for the article: `embed_with_shrink/5` re-sends it at half the bytes it just
     sent, down to a floor that provably fits (`TextBudget`). Only an exhausted ladder
     falls through to the discard in 7 — so an over-long article is embedded from
     its prefix instead of being retried hourly forever by the reconciler.
  8. On `{:error, :circuit_open}` (the tenant breaker is OPEN — a throttle/latency
     storm) the worker `{:snooze, remaining_cooldown}`s (US-37.3, AC-37.3.5): a
     loss-free reschedule that consumes NO attempt. This is deliberately NOT the
     `{:error, reason}` retry path — a honored Retry-After can hold the breaker open
     up to 300s, exceeding a job's 4-attempt window, so `{:error, ...}` would discard
     the job and leave the article permanently un-embedded (no embedding backfill).

  ## Retry Strategy

  Uses a custom polynomial backoff: `attempt^4 + 15 + rand(0..30*attempt)`.
  With `max_attempts: 4`, approximate delays are ~16s, ~31s, ~96s, ~271s.

  US-37.3: when a throttle error (429/503) carries a provider `Retry-After`, the
  worker instead `{:snooze, retry_after}`s (loss-free, no Oban attempt consumed)
  for ~that interval rather than the blind polynomial backoff — so it never
  hot-retries into a throttling provider. A throttle WITHOUT a Retry-After keeps
  the polynomial backoff.

  ## Uniqueness

  Unique per `article_id` within a 300-second window. If a new job is
  inserted for the same article while one is pending, it replaces the
  existing job.
  """

  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 4,
    # `:tenant_id` is part of the key, not just `:article_id`. Article ids are GLOBAL, and a
    # SYSTEM canonical is enumerated for re-embedding by EVERY tenant — so keying on the id
    # alone made two tenants' repair jobs collide inside the 300s window, deduping one away
    # or (with `replace:` below) overwriting its args. `SystemCorpusEmbeddingWorker` already
    # keys on `[:tenant_id, :dim]` for the same reason.
    unique: [keys: [:tenant_id, :article_id], period: 300],
    replace: [scheduled: [:args, :scheduled_at]]

  require Logger

  alias Loopctl.Custody
  alias Loopctl.Egress
  alias Loopctl.Egress.Scope

  import Loopctl.Egress, only: [is_egress_refusal: 1]
  alias Loopctl.Embeddings
  alias Loopctl.Embeddings.Dimensions
  alias Loopctl.Embeddings.TextBudget
  alias Loopctl.Knowledge
  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Oban.FairShare
  alias Loopctl.Provider.Admission
  alias Loopctl.Provider.RetryAfter
  alias Loopctl.Workers.ArticleLinkingWorker

  # Longer Task.yield budget than the interactive query path: a background embed can
  # afford a little more headroom, but still bounded so a wedged provider can't pin a
  # worker. The client itself caps a single attempt at ~4s (no client retries), so
  # this only adds slack for scheduling/DB.
  @worker_yield_ms 8_000

  @impl Oban.Worker
  def perform(%Oban.Job{id: id, args: %{"article_id" => article_id, "tenant_id" => tenant_id}}) do
    # US-36.2: per-tenant fair-share gate. Yield the :embeddings slot (loss-free
    # {:snooze, n}, no attempt consumed) when this tenant already holds at/above its
    # fair share of executing slots, so one tenant's bulk burst can't monopolize.
    # `id` excludes THIS (already-executing) job from its own count — see FairShare.
    case FairShare.gate(tenant_id, :embeddings, id) do
      {:snooze, _n} = snooze -> snooze
      :ok -> embed(tenant_id, article_id)
    end
  end

  defp embed(tenant_id, article_id) do
    case Knowledge.get_article_with_embedding(tenant_id, article_id) do
      {:error, :not_found} ->
        # Article deleted -- no-op
        :ok

      {:ok, article} ->
        generate_and_store(article, tenant_id, article_id)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  defp generate_and_store(article, tenant_id, article_id) do
    text = build_embedding_text(article)
    content_hash = content_hash(text)

    if already_embedded?(tenant_id, article, content_hash) do
      # Idempotent no-op: this exact content is already embedded (review #12). Ensure
      # linking is (re-)enqueued and finish — never re-call the paid provider.
      enqueue_linking(article_id, tenant_id)
      :ok
    else
      generate(tenant_id, article, article_id, text, content_hash)
    end
  end

  # NOTE the asymmetry between `text` and `content_hash` once the ladder shrinks:
  # the hash is always of the INITIAL text, never of the shrunk text actually
  # sent. That is deliberate. `embedding_content_hash` answers "has this article's
  # content already been embedded?", and keying it to whichever rung succeeded would
  # make the answer depend on a provider verdict — so every later enqueue would miss
  # the idempotency check, walk the whole ladder again, and re-bill the tenant for
  # an embedding it already has.
  defp generate(tenant_id, article, article_id, text, content_hash) do
    # US-41.4 (AC-41.4.2): articles carry a nullable `project_id`, so the egress scope
    # is the ARTICLE's project when it has one and the tenant-wide scope otherwise.
    # The effective marking is MOST-RESTRICTIVE (project OR tenant).
    opts = [timeout: @worker_yield_ms, project_id: article.project_id]

    # US-41.7 (AC-41.7.1/.2): the embedding is its OWN content-touching operation,
    # recorded with the posture RESOLVED for THIS call — not folded into the
    # article's write-time snapshot, which an async embed or a later re-embed
    # against a different endpoint would falsify.
    #
    # Recorded BEFORE the call, not after. The sequence number is what proves
    # completeness, so allocating it only on success would leave every failure
    # that happens AFTER the request body left the process — a provider 5xx, a read
    # timeout, a task yield timeout, a node death mid-call — with no entry AND no
    # gap, and the claim would report no-third-party-egress for a row whose body
    # did egress. AC-41.7.2 names exactly that scenario.
    result = embed_with_shrink(tenant_id, article, article_id, text, opts)

    case result do
      {:ok, embedding} ->
        store(tenant_id, article_id, embedding, content_hash)

      {:error, :no_api_key} ->
        skip_no_embedding_key(tenant_id, article_id)

      {:error, refusal} when is_egress_refusal(refusal) ->
        # US-41.4 (AC-41.4.3): the ONE mapping from an egress refusal to an Oban
        # outcome lives in `Loopctl.Egress.oban_result/1`: `:egress_blocked` CANCELS
        # (a permanent configuration state; retrying burns max_attempts and no data
        # was sent), while `:pin_stale` / `:egress_unavailable` SNOOZE (an IP change
        # or a DB hiccup is recoverable, and cancelling would silently strand the
        # item). The cancel reason NAMES the scope and the offending endpoint
        # (AC-41.4.6).
        Egress.oban_result(refusal)

      {:error, :rate_limited_local} ->
        # US-37.1 (AC-37.1.4): a node-local provider admission rate-limit is
        # loss-free backpressure, NOT a failure. Snooze the slot (no attempt
        # consumed, never a discard) — mirrors the FairShare.gate snooze pattern —
        # so the embed is retried once local demand subsides.
        {:snooze, Admission.snooze_seconds()}

      {:error, :circuit_open} ->
        # US-37.3 (AC-37.3.5): the tenant's embedding breaker is OPEN (a throttle /
        # latency storm short-circuited the guarded call before any provider hit).
        # Snooze loss-free for ~the remaining open window (no Oban attempt consumed)
        # rather than returning {:error, ...}: since this story makes 429/408 COUNT
        # toward the breaker AND lets a honored Retry-After raise the open cooldown up
        # to 300s — which can exceed a job's whole 4-attempt window — an {:error, ...}
        # here would burn every attempt against the still-open breaker and DISCARD the
        # job, leaving the article permanently un-embedded (there is no embedding
        # backfill). The snooze is floored positive by cooldown-remaining's caller.
        {:snooze, circuit_open_snooze_seconds(tenant_id)}

      {:error, {:api_error, _status, :provider_error, retry_after}}
      when is_integer(retry_after) ->
        # US-37.3 (AC-37.3.3): the provider signalled a throttle (429/503) with a
        # Retry-After. Snooze loss-free for ~that interval (no Oban attempt consumed)
        # INSTEAD of the blind `attempt^4` backoff, so we don't hot-retry into a
        # throttling provider. The value is already clamped to the SystemConfig max
        # at parse time; `RetryAfter.snooze_seconds/1` floors it POSITIVE so a
        # provider `Retry-After: 0` can't produce a `{:snooze, 0}` hot-reschedule. A
        # throttle WITHOUT a Retry-After falls through to the generic branch below and
        # keeps the polynomial backoff.
        {:snooze, RetryAfter.snooze_seconds(retry_after)}

      {:error, reason} ->
        # Classify on the raw reason, but the term that becomes an Oban discard/error
        # reason (-> oban_jobs.errors) is SANITIZED (review #5/#6) — never a raw body.
        # US-34.3 (review MED #1): the `[:loopctl, :llm, :provider_error]` telemetry
        # signal is now recorded ONCE, upstream, in
        # `Loopctl.Knowledge.run_embedding_task/3` — the single choke point shared by
        # this worker AND every query-time embedding caller. Do NOT re-record here.
        sanitized = ProviderError.sanitize(reason)

        if Llm.permanent_provider_error?(reason) do
          # A revoked/invalid tenant key (4xx) will never succeed on retry (review #5).
          Logger.debug(
            "ArticleEmbeddingWorker: tenant=#{tenant_id} article=#{article_id} permanent " <>
              "embedding error (#{ProviderError.log_tag(reason)}); discarding."
          )

          {:discard, {:embedding_permanent_error, sanitized}}
        else
          {:error, sanitized}
        end
    end
  end

  # The shrink ladder. `attempt` arrives as the initial (character-capped) text, so the
  # first pass sends exactly what the pre-ladder code sent; each rejection re-truncates
  # what was JUST SENT to half its bytes and re-sends.
  #
  # The next budget is derived from `byte_size(attempt)`, never from a nominal rung:
  # a rung larger than the text truncates nothing, so halving the rung alone would
  # re-send byte-identical bytes and buy a guaranteed-identical rejection.
  #
  # Terminates unconditionally: `TextBudget.next_budget/1` returns `:exhausted` once
  # the floor has been tried. On `:exhausted` the original error is returned untouched,
  # so the caller's existing permanent-error branch discards it — a floor-sized input
  # that is STILL rejected is a different defect (a much smaller model window, e.g. a
  # self-hosted 512-token embedder) and must be legible as one, not absorbed by more
  # halving.
  defp embed_with_shrink(tenant_id, article, article_id, attempt, opts) do
    case embed_with_custody(tenant_id, article, article_id, attempt, opts) do
      {:error, {:api_error, _status, :context_length_exceeded}} = error ->
        sent = byte_size(attempt)

        case TextBudget.next_budget(sent) do
          :exhausted ->
            Logger.warning(
              "ArticleEmbeddingWorker: tenant=#{tenant_id} article=#{article_id} rejected as " <>
                "too long at #{sent} bytes, the ladder's floor — not a length problem " <>
                "(a smaller model window?); discarding."
            )

            error

          smaller ->
            Logger.warning(
              "ArticleEmbeddingWorker: tenant=#{tenant_id} article=#{article_id} exceeded the " <>
                "provider token limit at #{sent} bytes; retrying at #{smaller}. The embedding " <>
                "will cover a prefix of the article, not all of it."
            )

            embed_with_shrink(
              tenant_id,
              article,
              article_id,
              TextBudget.truncate(attempt, smaller),
              opts
            )
        end

      result ->
        result
    end
  end

  defp embed_with_custody(tenant_id, article, article_id, text, opts) do
    recorded = record_custody_posture(tenant_id, article, article_id)
    result = Knowledge.generate_embedding(tenant_id, text, opts)
    Custody.record_outcome(recorded, custody_outcome(result))
    result
  end

  defp custody_outcome({:ok, _}), do: :succeeded
  defp custody_outcome(_other), do: :failed

  # `:reembed` when the article already carried a vector, so a model/endpoint
  # switch (US-41.1 AC-41.1.10) is legible as its own operation rather than
  # overwriting what the first embed recorded.
  defp record_custody_posture(tenant_id, article, article_id) do
    operation = if is_nil(article.embedding), do: :embed, else: :reembed

    Custody.record(
      Scope.new(tenant_id, article.project_id),
      "article",
      article_id,
      operation
    )
  end

  defp store(tenant_id, article_id, embedding, content_hash) do
    # Pre-write dimension check (review): resolve the write dimension ONCE, then verify
    # the vector length BEFORE the changeset. An off-dimension model otherwise surfaced
    # as a changeset validation error, `perform` returned `{:error, _}`, and Oban
    # re-billed the provider on each of five attempts. A mismatch DISCARDS legibly.
    dimension = Embeddings.resolve_write_dimension(tenant_id)

    case Dimensions.check_batch_length([embedding], dimension) do
      :ok ->
        with {:ok, _article} <-
               Knowledge.update_embedding(
                 tenant_id,
                 article_id,
                 embedding,
                 content_hash,
                 dimension
               ) do
          enqueue_linking(article_id, tenant_id)
          :ok
        end

      {:error, {:dimension_mismatch, expected, actual}} ->
        Logger.debug(
          "ArticleEmbeddingWorker: model returned #{inspect(actual)}-dimension vector but " <>
            "the tenant is recorded at #{expected}; discarding rather than re-billing."
        )

        {:discard, {:dimension_mismatch, expected, actual}}
    end
  end

  # Snooze interval (seconds) for the OPEN-breaker path: ~the remaining cooldown so
  # the job wakes right as the breaker closes. Floored at `Admission.snooze_seconds/0`
  # (always >= 1) so a just-expired/raced window still yields a positive snooze — a
  # short re-snooze is loss-free (no attempt consumed), never a `{:snooze, 0}` loop.
  defp circuit_open_snooze_seconds(tenant_id) do
    max(Knowledge.circuit_breaker_cooldown_remaining(tenant_id), Admission.snooze_seconds())
  end

  # IDEMPOTENCY, at the ACTIVE dimension (review).
  #
  # This guard used to read ONLY the legacy `articles.embedding` +
  # `articles.embedding_content_hash`, which `Knowledge.update_embedding/5` NEVER
  # writes for a non-1536 dimension. For exactly the 768/1024 tenants this epic
  # exists for, both stayed NULL forever, so the guard fell through to `false` on
  # every invocation and every enqueue re-billed the paid provider: a silent,
  # unbounded cost loop. Behind the cutover flag the presence+hash check therefore
  # consults the side table at the tenant's active dimension, where the hash HAS been
  # recorded all along.
  defp already_embedded?(tenant_id, article, content_hash) do
    # Gated on the WRITE dimension (`use_side_table_hash?/1`), NOT the read flag
    # (review): a non-1536 tenant NEVER has a legacy hash, so keying this on the read
    # flag re-billed the provider on every enqueue until cutover.
    if Embeddings.use_side_table_hash?(tenant_id) do
      Embeddings.article_embedded_hash(
        tenant_id,
        article.id,
        Embeddings.active_dimension(tenant_id)
      ) == content_hash
    else
      legacy_already_embedded?(article, content_hash)
    end
  end

  defp legacy_already_embedded?(
         %{embedding: embedding, embedding_content_hash: hash},
         content_hash
       )
       when not is_nil(embedding) and is_binary(hash),
       do: hash == content_hash

  defp legacy_already_embedded?(_article, _content_hash), do: false

  defp content_hash(text) do
    :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
  end

  # Mandatory BYO: the tenant has no embedding key. Cleanly DISCARD (no retry, no
  # crash, no operator-key fallback) with a distinct, queryable reason + a telemetry
  # signal AND an audit entry (review #9) so the keyless-tenant volume is observable
  # and consistent with the Anthropic mandatory-BYO path.
  defp skip_no_embedding_key(tenant_id, article_id) do
    :telemetry.execute(
      [:loopctl, :embedding, :skipped_no_key],
      %{count: 1},
      # `source: "article"` is the ONE bounded metadata tag US-34.4 (AC-34.4.4) adds at
      # this emit site — lets the `loopctl.embedding.skipped_no_key.count` counter
      # (`Loopctl.Telemetry.ScaleMetrics`) distinguish article vs memory skips without
      # tagging the unbounded `article_id`.
      %{tenant_id: tenant_id, article_id: article_id, source: "article"}
    )

    Llm.record_blocked(tenant_id, :embedding)

    Logger.debug(
      "ArticleEmbeddingWorker: tenant=#{tenant_id} article=#{article_id} skipped — no " <>
        "embedding API key configured (mandatory BYO)."
    )

    {:discard, {:no_embedding_key, article_id}}
  end

  defp enqueue_linking(article_id, tenant_id) do
    ArticleLinkingWorker.new(%{
      article_id: article_id,
      tenant_id: tenant_id
    })
    |> Oban.insert()
  end

  # The initial CHARACTER cap, shared verbatim with `BatchArticleEmbeddingWorker`,
  # `ReembedWorker` and `SystemCorpusEmbeddingWorker` — they all write
  # `embedding_content_hash` into the same side table and read each other's back as
  # the no-re-bill guard, so a divergent unit here makes every hash miss and re-bills
  # the provider on every enqueue.
  defp build_embedding_text(article) do
    TextBudget.initial("#{article.title}\n\n#{article.body}")
  end
end
