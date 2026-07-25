defmodule Loopctl.Workers.ContentIngestionWorker do
  @moduledoc """
  Oban worker that ingests external content and extracts knowledge articles.

  Runs in its own dedicated `:ingestion` queue (US-36.1). These are long (~6-min)
  LLM jobs, so they get a separate queue/consumer from the sub-second `:knowledge`
  workers — a burst of ingests can no longer head-of-line-block linking/lint/MOC/
  metrics/reclassify/review (GH #351). (`:knowledge` also hosts the daily
  `PromotionEvalWorker` LLM eval, but that is a once-daily cron, not part of the
  sub-second hot lane this split protects.) When content is submitted
  via the ingestion API, this worker fetches the content (if a URL was provided),
  extracts knowledge articles via the content extractor, validates them, and
  inserts them as draft articles.

  ## Flow

  1. If `url` present: fetch via Req, strip HTML tags with regex
  2. Call `@content_extractor.extract_from_content(content, source_type: source_type)`
  3. Validate extractor output (valid title, body, category, tags)
  4. Insert all as drafts via Ecto.Multi with source_type and source_id
  5. Audit log: `knowledge.content_ingested` with article count, source_type, url

  ## Retry Strategy

  Uses a custom polynomial backoff: `attempt^4 + 15 + rand(0..30*attempt)`.
  With `max_attempts: 3`, approximate delays are ~16s, ~31s.

  ## Uniqueness

  Unique per `content_hash` + `tenant_id` within a 3600-second window.
  """

  # `unique` deliberately EXCLUDES `:completed` (and `:discarded`/`:cancelled`)
  # from its states (#264, Finding 2): the default set includes `:completed`, so a
  # legitimate resubmission of UNDER-captured content within the hour would be
  # absorbed as a duplicate ({:ok, :already_queued}) and silently do no new work.
  # Excluding `:completed` lets an operator re-ingest; per-article inserts are
  # idempotent (deterministic idempotency_key + on_conflict), so a resubmission of
  # already-captured content re-runs safely without creating duplicate rows.
  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 3,
    unique: [
      keys: [:content_hash, :tenant_id],
      period: 3600,
      states: [:scheduled, :available, :executing, :retryable]
    ]

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Egress

  import Loopctl.Egress, only: [is_egress_refusal: 1]
  import Loopctl.Llm.ShapeError, only: [is_shape_error: 1]
  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Ingestion.ContentEnvelope
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ContentChunker
  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Llm.ShapeError
  alias Loopctl.Oban.FairShare
  alias Loopctl.Provider
  alias Loopctl.Provider.Admission
  alias Loopctl.Provider.RetryAfter
  alias Loopctl.SystemConfig
  alias Loopctl.Workers.BatchArticleEmbeddingWorker

  @content_extractor Application.compile_env(
                       :loopctl,
                       :content_extractor,
                       Loopctl.Knowledge.ContentExtractorRouter
                     )

  @max_articles 10
  @max_body_length 100_000

  # Network-layer fetch-size backstop (#461 item 4). A hostile/misbehaving URL could
  # otherwise stream unbounded bytes into memory; the pre-existing @max_body_length
  # guard only rejects AFTER a full download (per-ARTICLE text, not the raw page).
  # Req 0.6.3 has no `:max_body_length` option, so we cap at the network layer via
  # `into:` a bounded collector that HALTS the transfer (closing the connection) the
  # moment the accumulated body crosses this ceiling. Sized well above a large HTML
  # page (an ~87KB newsletter's raw markup) but bounded, so it never truncates a
  # legitimate fetch yet caps a malicious multi-GB stream.
  @max_fetch_body_bytes 5_000_000

  # --- Multi-chunk timeout budget (#264) ---
  #
  # A real ~87KB newsletter chunks into ~11 pieces, each 7–13s of LLM
  # extraction. The old flat 30s timeout killed every such job (Oban.TimeoutError
  # → discarded after 3 attempts with ZERO articles persisted). We now:
  #
  #   * persist each chunk's articles as it completes (partial progress survives
  #     a later timeout/failure — see ingest_chunks/2), and
  #   * scale the job timeout by chunk count with a hard cap.
  #
  # These budgets are now DB-backed and live-tunable via `Loopctl.SystemConfig`
  # (no redeploy to adjust). The in-code defaults below match the seeded rows and
  # apply on a cache miss (safe degrade):
  #   * per_chunk_timeout_ms/0 = 60s (default) — ample headroom over the observed
  #     7–13s so a healthy chunk is never falsely timed out under tail latency,
  #     with room for one internal extractor retry (see ClaudeContentExtractor).
  #   * max_job_timeout_ms/0   = 6 min (default) — the ABSOLUTE ceiling a single
  #     job may hold a :knowledge slot (concurrency 5), independent of chunk count.
  #     Bounds abuse (GHSA-j7m9-ffmr-pwhm) while covering a realistic large doc.
  #   * max_chunks/0 = cap / per_chunk = 6 (at the defaults) — a document chunking
  #     to MORE than this can't be guaranteed within the cap, so we ingest the
  #     first max_chunks (persisted incrementally) and {:discard} the rest cleanly
  #     with a count, rather than crash-looping or silently losing everything.
  defp per_chunk_timeout_ms,
    do: SystemConfig.get_int("ingestion_per_chunk_timeout_ms", 60_000)

  defp max_job_timeout_ms,
    do: SystemConfig.get_int("ingestion_max_job_timeout_ms", 360_000)

  # Derived at runtime from the two live budgets. Guarded against a
  # (mis)configured per-chunk value of 0 so the worker can never divide by zero,
  # and floored at 1 chunk.
  defp max_chunks do
    per_chunk = per_chunk_timeout_ms()
    if per_chunk > 0, do: max(div(max_job_timeout_ms(), per_chunk), 1), else: 1
  end

  # ON CONFLICT arbiter for the partial `articles_tenant_idempotency_key_idx`
  # (WHERE idempotency_key IS NOT NULL). A partial index can only be inferred as
  # the arbiter when the predicate is restated, hence the unsafe_fragment (#264).
  @idempotency_conflict_target "(tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL"

  # Content-Type families that are never ingestible UTF-8 text (#263). A PDF /
  # image / archive body handed to the JSON-encoded extractor request raises
  # Jason.EncodeError on the invalid bytes and — because the content hash is
  # deterministic — every retry fails identically (a permanent crash-loop). We
  # detect and {:discard} these BEFORE the content reaches the extractor.
  @binary_application_content_types ~w(
    application/pdf application/octet-stream application/zip application/gzip
    application/x-gzip application/x-tar application/x-bzip2 application/x-7z-compressed
    application/x-rar-compressed application/msword application/vnd.ms-excel
    application/vnd.ms-powerpoint application/x-protobuf application/wasm
    application/java-archive application/x-shockwave-flash
  )
  @binary_content_type_prefixes ~w(image/ audio/ video/ font/)
  # Single source of truth: the canonical taxonomy (avoids drift).
  @valid_categories Loopctl.Knowledge.Categories.all()
  @tag_pattern ~r/^[a-zA-Z0-9_-]+$/
  # Single source of truth: the Article schema's tag cap (avoids drift).
  @max_tags Loopctl.Knowledge.Article.max_tags()
  @max_tag_length 100

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: id,
        args:
          %{
            "tenant_id" => tenant_id,
            "source_type" => source_type,
            "content_hash" => content_hash
          } = args
      }) do
    # US-36.2: per-tenant fair-share gate on the :ingestion queue. These are long
    # (~6-min) LLM jobs, so one tenant's bulk ingest can otherwise hold both slots
    # for many minutes. Yield loss-free ({:snooze, n}, no attempt consumed) BEFORE
    # any fetch/LLM work when this tenant is at/above its fair share of executing
    # slots; the deterministic content_hash uniqueness means the snoozed job resumes
    # the same work later. `id` excludes THIS (already-executing) job from its own
    # count — CRITICAL on :ingestion (cap=1), where self-counting would wedge the
    # queue permanently (every lone job would snooze forever). See FairShare.
    case FairShare.gate(tenant_id, :ingestion, id) do
      {:snooze, _n} = snooze -> snooze
      :ok -> ingest_result(ingest(tenant_id, source_type, content_hash, args))
    end
  end

  # US-41.4 (AC-41.4.3/.9): an egress refusal raised by the INGESTION FETCH (not
  # just by the LLM extraction calls) is mapped by the ONE mapping —
  # `Loopctl.Egress.oban_result/1` — so a `local_only` scope refusing a
  # tenant-supplied URL CANCELS with a reason naming the scope and the endpoint,
  # instead of being retried as a generic fetch failure.
  defp ingest_result({:error, refusal})
       when is_egress_refusal(refusal),
       do: Egress.oban_result(refusal)

  defp ingest_result(other), do: other

  defp ingest(tenant_id, source_type, content_hash, args) do
    url = args["url"]
    # Normalize "" -> nil (a blank project_id is "tenant-wide", not a value to dump
    # against the :binary_id column).
    project_id = normalize_project_id(args["project_id"])
    # Default draft; publish only when the ingest request opted in (#133).
    publish = args["publish"] == true

    # Generate a deterministic source_id from the content_hash.
    # source_id must be a UUID (:binary_id), so we derive one from the hash.
    source_id = derive_source_id(content_hash)

    # Defense in depth (the controller boundary validates before enqueueing): a
    # malformed / non-string project_id would raise Ecto.ChangeError on insert and,
    # because the uniqueness key excludes project_id, crash-loop as a poison pill.
    # DISCARD such a job (no retry) BEFORE any fetch/LLM work rather than raising.
    # Mandatory BYO (Epic 28, #179): the tenant must have its own Anthropic key.
    # {:discard} up front (no fetch, no LLM work, no retry-loop) when it doesn't —
    # the controller boundary 422s before enqueue, this is defense in depth.
    with :ok <- validate_project_id(project_id),
         :ok <- require_tenant_llm_key(tenant_id),
         {:ok, raw_content} <- inline_content(args),
         {:ok, content} <- resolve_content(egress_scope(tenant_id, project_id), url, raw_content) do
      ctx = %{
        tenant_id: tenant_id,
        # US-41.4 (AC-41.4.2): the SAME scope the fetch was made under. The chunk
        # bodies are POSTed to the model provider from `extract_and_persist_chunk/5`,
        # so passing only `tenant_id` there would leave a PROJECT-only local_only
        # marking unenforced on the extraction half of this job.
        egress_scope: egress_scope(tenant_id, project_id),
        # content_hash seeds the DETERMINISTIC per-article idempotency_key (#264,
        # Finding 1) so an Oban retry that re-walks already-persisted chunks
        # no-ops instead of inserting duplicate rows.
        content_hash: content_hash,
        source_id: source_id,
        source_type: source_type,
        project_id: project_id,
        url: url,
        publish: publish
      }

      ingest_chunks(ctx, content)
    end
  end

  # Mandatory BYO: without a tenant Anthropic key, extraction can never succeed —
  # {:discard} cleanly (no infinite retry) rather than burning 3 attempts on a
  # deterministic no-key failure.
  defp require_tenant_llm_key(tenant_id) do
    if Llm.has_api_key?(tenant_id) do
      :ok
    else
      Llm.record_blocked(tenant_id, :extraction)
      {:discard, {:no_api_key, "tenant has no Anthropic API key configured (BYO required)"}}
    end
  end

  # nil (tenant-wide) or a valid UUID is fine; anything else is a poison pill —
  # discard it cleanly (no 3x retry), never raise.
  defp validate_project_id(nil), do: :ok

  defp validate_project_id(project_id) when is_binary(project_id) do
    if valid_uuid?(project_id), do: :ok, else: {:discard, {:invalid_project_id, project_id}}
  end

  defp validate_project_id(other), do: {:discard, {:invalid_project_id, other}}

  defp normalize_project_id(""), do: nil
  defp normalize_project_id(value), do: value

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_), do: false

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  # Per-job wall-clock cap that SCALES with chunk count (#264), floored at one
  # chunk and hard-capped at max_job_timeout_ms/0. A hostile/slow endpoint still
  # can't pin a :knowledge queue slot beyond the cap (worker-01 /
  # GHSA-j7m9-ffmr-pwhm), while a legitimate multi-chunk document now gets enough
  # wall-clock to finish. For a URL job the fetched size is unknown until fetch,
  # so we grant the full capped budget; perform/1 self-limits to max_chunks/0 and
  # persists incrementally, so the cap is a backstop, not the mechanism.
  @impl Oban.Worker
  def timeout(%Oban.Job{args: args}) do
    args
    |> chunk_count_for_timeout()
    |> max(1)
    |> Kernel.*(per_chunk_timeout_ms())
    |> min(max_job_timeout_ms())
  end

  defp chunk_count_for_timeout(%{"content" => content})
       when is_binary(content) and content != "" do
    content |> ContentChunker.chunk() |> length()
  end

  # #493: new inline jobs carry the document as an ENCRYPTED envelope, not
  # plaintext `content`. Without this clause an encrypted multi-chunk document
  # falls through to the `_ -> 1` catch-all and gets a flat one-chunk (60s)
  # budget, re-introducing the exact multi-chunk Oban.TimeoutError kill #264
  # fixed. Decrypt is cheap (once per attempt) and lets timeout/1 scale exactly
  # as it does for legacy plaintext. A corrupt envelope is a poison pill perform/1
  # {:discard}s anyway; grant it the full capped budget (max_chunks/0) so the
  # timeout is never the thing that kills it first.
  defp chunk_count_for_timeout(%{"content_encrypted" => envelope}) when is_binary(envelope) do
    case ContentEnvelope.unwrap(envelope) do
      {:ok, content} -> content |> ContentChunker.chunk() |> length()
      {:error, _reason} -> max_chunks()
    end
  end

  defp chunk_count_for_timeout(%{"url" => url}) when is_binary(url) and url != "" do
    max_chunks()
  end

  defp chunk_count_for_timeout(_), do: 1

  # --- Private ---

  # Ingest a document chunk-by-chunk, PERSISTING each chunk's articles as it
  # completes (#264). A timeout or mid-run failure therefore keeps the articles
  # already extracted instead of discarding everything. Documents that chunk
  # beyond max_chunks/0 are ingested up to that bound and the remainder is
  # {:discard}ed cleanly (with a count) rather than silently lost.
  defp ingest_chunks(ctx, content) do
    # Key the per-chunk idempotency/skip on a hash of the ACTUALLY-RESOLVED bytes
    # for THIS attempt — NOT the enqueue-time `content_hash` (#179 review round 4).
    # For a URL job `content_hash` is sha256(url), but the bytes are re-fetched fresh
    # on every Oban attempt; if the URL's content changed between attempts, keying the
    # skip on the URL would false-SKIP the new bytes' chunks and silently keep stale
    # content. Keying on sha256(fetched bytes) SKIPS correctly only when the content
    # is byte-identical across attempts and RE-EXTRACTS when it genuinely changed.
    # (For content-only jobs this equals `content_hash`, so their behavior is unchanged.)
    fetched_hash = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
    ctx = Map.put(ctx, :fetched_hash, fetched_hash)

    chunks = ContentChunker.chunk(content)
    chunk_count = length(chunks)
    {processable, dropped} = Enum.split(chunks, max_chunks())

    if chunk_count > 1 do
      Logger.info(
        "ContentIngestionWorker: #{byte_size(content)} bytes -> #{chunk_count} chunks " <>
          "(processing #{length(processable)}, deferring #{length(dropped)})"
      )
    end

    acc0 = %{inserted: 0, persisted: 0, attempted: 0, errors: [], seen_titles: MapSet.new()}

    result =
      processable
      |> Enum.with_index()
      |> Enum.reduce_while(acc0, fn {chunk, chunk_index}, acc ->
        remaining = @max_articles - acc.inserted

        if remaining <= 0 do
          # Article cap reached — stop early; we have the full @max_articles set.
          {:halt, acc}
        else
          reduce_chunk(ctx, chunk, chunk_index, remaining, acc)
        end
      end)

    case result do
      # US-37.1 (AC-37.1.4): a chunk hit the node-local provider admission gate
      # (`{:error, :rate_limited_local}`). This is loss-free backpressure, NOT a
      # failure to classify: snooze the WHOLE job (no Oban attempt consumed, never
      # a discard) rather than routing it through finalize_errors' transient-retry
      # path, which would burn max_attempts under sustained provider backpressure.
      # Already-persisted chunks committed in their own transactions and are
      # idempotent, so the re-run resumes without re-billing them.
      {:rate_limited_local, _acc} ->
        {:snooze, Admission.snooze_seconds()}

      # US-41.4 (AC-41.4.3): an egress refusal — `Loopctl.Egress.oban_result/1` maps
      # the PERMANENT `:egress_blocked` to a cancel (never {:error, _}, which Oban
      # retries) and the recoverable `:pin_stale` / `:egress_unavailable` to a
      # snooze. Already-persisted chunks stay committed; nothing left the boundary.
      {:egress_refusal, refusal, _acc} ->
        Egress.oban_result(refusal)

      # US-37.3 (AC-37.3.3): a chunk's Anthropic extraction was throttled with a
      # provider Retry-After. Snooze the whole job loss-free for ~that interval
      # (no attempt consumed) instead of the blind `attempt^4` backoff.
      # `RetryAfter.snooze_seconds/1` floors the value POSITIVE: this Anthropic path
      # has NO circuit breaker, so a provider persistently returning `Retry-After: 0`
      # would otherwise `{:snooze, 0}` hot-loop (each snooze bumps max_attempts, so it
      # never terminates by attempt cap) — the exact behavior AC-37.3.5 forbids.
      {:throttled, retry_after, _acc} ->
        {:snooze, RetryAfter.snooze_seconds(retry_after)}

      acc ->
        finalize_ingest(acc, chunk_count, dropped)
    end
  end

  defp reduce_chunk(ctx, chunk, chunk_index, remaining, acc) do
    case persisted_chunk_titles(ctx, chunk_index) do
      [] ->
        extract_reduce_chunk(ctx, chunk, chunk_index, remaining, acc)

      titles ->
        # This chunk's articles were durably committed by a PRIOR attempt (#179
        # review #1). SKIP re-extraction entirely — a whole-job Oban retry must
        # NEVER re-call (and re-BILL) the tenant's Anthropic key for a chunk that
        # already succeeded. Seed cross-chunk dedup with the persisted titles and
        # count them toward the article budget so the run stays consistent.
        seen =
          Enum.reduce(titles, acc.seen_titles, fn t, s ->
            MapSet.put(s, normalize_persisted_title(t))
          end)

        Logger.info(
          "ContentIngestionWorker: chunk #{chunk_index} already persisted " <>
            "(#{length(titles)} article(s)); skipping re-extraction (no re-bill)"
        )

        {:cont,
         %{
           acc
           | inserted: acc.inserted + length(titles),
             persisted: acc.persisted + 1,
             seen_titles: seen
         }}
    end
  end

  defp extract_reduce_chunk(ctx, chunk, chunk_index, remaining, acc) do
    acc = %{acc | attempted: acc.attempted + 1}

    case extract_and_persist_chunk(ctx, chunk, chunk_index, remaining, acc.seen_titles) do
      {:ok, count, seen_titles} ->
        {:cont,
         %{
           acc
           | inserted: acc.inserted + count,
             persisted: acc.persisted + 1,
             seen_titles: seen_titles
         }}

      {:error, refusal} when is_egress_refusal(refusal) ->
        # US-41.4 (AC-41.4.3): the scope is local_only and the resolved endpoint is
        # not local (or the pin/marking is momentarily unusable). Halt the reduce and
        # let `Loopctl.Egress.oban_result/1` decide the job outcome: CANCEL for the
        # permanent `:egress_blocked`, SNOOZE for the recoverable `:pin_stale` /
        # `:egress_unavailable`. No data was sent either way.
        {:halt, {:egress_refusal, refusal, acc}}

      {:error, :rate_limited_local} ->
        # US-37.1 (AC-37.1.4): node-local provider admission backpressure. Halt the
        # reduce and signal the caller to snooze the whole job loss-free — the gate
        # is shut, so re-attempting the remaining chunks now would just re-hit it.
        {:halt, {:rate_limited_local, acc}}

      {:error, {:api_error, _status, :provider_error, retry_after}}
      when is_integer(retry_after) ->
        # US-37.3 (AC-37.3.3): the Anthropic extraction call was throttled (429/503)
        # with a provider Retry-After. Halt and snooze the WHOLE job loss-free for
        # ~that interval (no Oban attempt consumed) rather than routing it through
        # finalize_errors' transient-retry path, which would burn max_attempts under
        # sustained throttling. Already-persisted chunks stay committed and are
        # idempotent, so the re-run resumes without re-billing them.
        {:halt, {:throttled, retry_after, acc}}

      {:error, reason} ->
        # Persist what earlier chunks produced; record the error and keep going —
        # finalize_ingest surfaces it as retryable (Finding 2).
        {:cont, %{acc | errors: [reason | acc.errors]}}
    end
  end

  # Extract + validate + persist ONE chunk in its own transaction, so its
  # article(s) are durably committed before the next chunk's LLM call runs.
  #
  # `seen_titles` carries the normalized titles already persisted by EARLIER
  # chunks so a title extracted from two different chunks isn't inserted twice
  # (the pre-#264 flow deduped across the whole accumulated set; per-chunk
  # persistence reintroduces that need — a cross-chunk title collision would
  # otherwise abort the whole chunk on the `articles_tenant_title_active_idx`).
  defp extract_and_persist_chunk(ctx, chunk, chunk_index, remaining, seen_titles) do
    case @content_extractor.extract_from_content(ctx.egress_scope, chunk,
           source_type: ctx.source_type
         ) do
      {:ok, extracted} ->
        {articles, seen_titles} =
          extracted
          |> dedup_articles()
          |> validate_and_filter()
          |> dedup_cross_chunk(seen_titles, remaining)

        case insert_articles(ctx, articles, chunk_index) do
          # Count GENUINELY-inserted rows (insert_all RETURNING), not the attempted
          # set — a retry that conflict-skips already-persisted articles reports 0,
          # so the article budget and audit reflect real work (#264 review F1).
          {:ok, inserted_count} -> {:ok, inserted_count, seen_titles}
          {:error, _} = err -> err
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Drop articles whose normalized title was already persisted by an earlier
  # chunk, cap at `remaining`, and return the kept articles plus the updated
  # seen-title set. Titles are non-blank here (validate_and_filter dropped blanks).
  defp dedup_cross_chunk(articles, seen_titles, remaining) do
    {kept_rev, seen} =
      Enum.reduce(articles, {[], seen_titles}, fn article, {kept, seen} ->
        title = normalized_title(article)

        cond do
          length(kept) >= remaining -> {kept, seen}
          MapSet.member?(seen, title) -> {kept, seen}
          true -> {[article | kept], MapSet.put(seen, title)}
        end
      end)

    {Enum.reverse(kept_rev), seen}
  end

  defp normalized_title(article) do
    (Map.get(article, :title) || Map.get(article, "title") || "")
    |> String.trim()
    |> String.downcase()
  end

  # Decide the job's return value from the incremental run. Because per-article
  # inserts are idempotent (deterministic idempotency_key + on_conflict, Finding
  # 1), a retry never duplicates already-committed chunks — so we can safely
  # surface a partial failure as retryable:
  #
  #   * ANY transient chunk error → {:error, first} so Oban retries the whole job;
  #     the retry no-ops the persisted chunks and productively re-attempts only
  #     the failed one(s). Returning :ok here (the old behavior) would mark the
  #     job :completed and permanently lose the failed chunk (Finding 2).
  #   * ONLY permanent errors (4xx that a retry can't fix) → {:discard} so it
  #     doesn't retry forever; whatever persisted stays committed.
  #   * dropped chunks (document > max_chunks/0) → {:discard} with an ACCURATE
  #     attempted-chunk count (Finding 3).
  #   * otherwise → :ok.
  defp finalize_ingest(
         %{inserted: inserted, persisted: persisted, attempted: attempted, errors: errors},
         chunk_count,
         dropped
       ) do
    cond do
      errors != [] ->
        finalize_errors(errors, inserted, persisted, attempted)

      dropped != [] ->
        {:discard,
         {:document_too_large, too_large_message(chunk_count, dropped, inserted, attempted)}}

      true ->
        :ok
    end
  end

  defp finalize_errors(errors, inserted, persisted, attempted) do
    # Sanitize the representative error BEFORE it becomes an Oban reason / log line
    # (review #5): a provider `{:api_error, _, body}` can echo a masked key fragment,
    # and these reasons land in oban_jobs.errors (surfaced by list_extraction_errors).
    # Classification below runs on the RAW errors (it needs the status/Postgrex code).
    first = errors |> Enum.reverse() |> List.first() |> ProviderError.sanitize()
    # US-41.3: a shape failure renders as its agent-readable message (endpoint +
    # model + why) rather than an opaque inspected tuple in oban_jobs.errors.
    first_text = if is_shape_error(first), do: ShapeError.message(first), else: inspect(first)

    if Enum.all?(errors, &permanent_error?/1) do
      # No transient error a retry could clear — {:discard} (no infinite retry);
      # whatever persisted stays committed.
      {:discard,
       {:extraction_failed,
        "extraction permanently failed on #{length(errors)} chunk(s) " <>
          "(first: #{first_text}); persisted #{inserted} article(s) from " <>
          "#{persisted} of #{attempted} attempted chunk(s) — not retryable"}}
    else
      # At least one transient error — retry the whole (idempotent) job so the
      # failed chunk(s) get re-attempted; persisted chunks no-op on conflict.
      {:error, first}
    end
  end

  # A permanent failure a retry can't fix:
  #   * a 4xx API error other than 408 (timeout) / 429 (rate limited), which ARE
  #     transient (5xx / request_failed / json_parse_error are all transient); and
  #   * a DB CONSTRAINT violation (#264 review F2) — e.g. an extracted title equal
  #     to an EXISTING different article's title trips the active-title unique
  #     index (the idempotency conflict target doesn't cover it), which is
  #     deterministic and would otherwise burn every retry before discard.
  # A non-constraint DB error (serialization/deadlock/connection) stays transient.
  #   * US-41.3 (AC-41.3.4): a shape failure from the OpenAI-compatible path — the
  #     configured model cannot produce the required structure, so every retry
  #     re-POSTs the tenant's full document to a model that will fail identically.
  defp permanent_error?({:invalid_response_shape, _details}), do: true

  defp permanent_error?({:api_error, status, _body})
       when is_integer(status) and status >= 400 and status < 500 and status != 408 and
              status != 429,
       do: true

  defp permanent_error?({:insert_failed, _step, %Postgrex.Error{} = error}),
    do: constraint_violation?(error)

  defp permanent_error?({:insert_failed, _step, %Ecto.Changeset{}}), do: true

  # Mandatory BYO: a missing tenant key is deterministic (a retry can't fix it).
  # The top-level gate normally discards before any chunk runs; this backstops the
  # case where the key is removed mid-job between chunks.
  defp permanent_error?(:no_api_key), do: true

  # US-41.3: a provider mismatch (the chat client resolved a DIFFERENT provider than
  # the one it guards, e.g. after a settings flip mid-job) is a deterministic
  # CONFIGURATION state — retrying re-resolves the same settings and refuses
  # identically, burning every attempt for nothing.
  defp permanent_error?(:provider_mismatch), do: true

  defp permanent_error?(_), do: false

  @constraint_violation_codes ~w(
    unique_violation check_violation not_null_violation
    foreign_key_violation exclusion_violation
  )a
  defp constraint_violation?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in @constraint_violation_codes

  defp constraint_violation?(_), do: false

  defp too_large_message(chunk_count, dropped, inserted, attempted) do
    "document too large: #{chunk_count} chunks exceed the #{max_chunks()}-chunk per-job " <>
      "budget (cap #{div(max_job_timeout_ms(), 1000)}s); persisted #{inserted} article(s) " <>
      "from #{attempted} attempted chunk(s), #{length(dropped)} chunk(s) not processed"
  end

  # When content is split into chunks, the same article may be extracted
  # from two overlapping chunks. Dedup by normalized title before capping.
  #
  # Two rules:
  #   1. Articles with blank/missing titles are NEVER merged together (each
  #      gets a unique sentinel key). They'll be rejected later by schema
  #      validation anyway, but collapsing them here would silently drop
  #      distinct articles.
  #   2. When duplicates exist, keep the one with the LONGEST body (the
  #      more complete extraction, vs a truncated partial from a chunk
  #      boundary). Enum.uniq_by keeps first-occurrence, so we sort by
  #      body length descending first.
  defp dedup_articles(articles) do
    articles
    |> Enum.sort_by(&article_body_length/1, :desc)
    |> Enum.uniq_by(&article_dedup_key/1)
  end

  defp article_dedup_key(article) do
    title =
      (Map.get(article, :title) || Map.get(article, "title") || "")
      |> String.trim()
      |> String.downcase()

    if title == "" do
      # Unique sentinel so blank-title articles are never merged together.
      # They'll be filtered by downstream validation, but don't collapse
      # them here.
      {:no_title, System.unique_integer([:positive])}
    else
      title
    end
  end

  defp article_body_length(article) do
    body = Map.get(article, :body) || Map.get(article, "body") || ""
    byte_size(body)
  end

  # US-41.4 (AC-41.4.2): articles carry a nullable `project_id`, so the ingestion
  # fetch is scoped to the article's project when it has one and to the tenant
  # otherwise. `Loopctl.Egress.Policy` resolves the effective marking as
  # MOST-RESTRICTIVE (project OR tenant).
  defp egress_scope(tenant_id, project_id), do: EgressScope.new(tenant_id, project_id)

  # #493: inline document content is stored in job args ENCRYPTED at rest
  # (`content_encrypted`: Cloak AES-256-GCM + Base64) — never plaintext in `oban_jobs`.
  # Decrypt it here. A pre-#493 job still in flight at deploy carries legacy plaintext
  # `content`; accept it too so the queue drains without loss. The URL path has neither,
  # so inline content is nil and `resolve_content` fetches. A tampered/corrupt envelope
  # is a poison pill no retry can heal — {:discard} it cleanly, mirroring the project_id
  # and no-key guards, rather than crash-looping to max_attempts.
  defp inline_content(%{"content_encrypted" => envelope}) when is_binary(envelope) do
    case ContentEnvelope.unwrap(envelope) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:discard, {reason, "ingestion content envelope could not be decrypted"}}
    end
  end

  defp inline_content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp inline_content(_args), do: {:ok, nil}

  defp resolve_content(_scope, nil, content) when is_binary(content) and content != "" do
    # Direct-content path: no Content-Type to consult, so the UTF-8 validity
    # check is the whole guard (#263). Non-UTF-8 inline content (a PDF/binary
    # posted directly) would raise Jason.EncodeError inside the extractor's JSON
    # request and crash-loop; {:discard} it cleanly instead.
    ensure_utf8_text(content)
  end

  defp resolve_content(scope, url, _content) when is_binary(url) do
    # ONE address decision (US-41.5 review). This used to gate on `UrlGuard.pin/1`
    # FIRST and only then consult the policy, which meant:
    #
    #   * the pre-gate could not see the OPERATOR deployment allowlist, so an
    #     allowlisted private host was a legal WEBHOOK destination but still a hard
    #     refusal as an INGESTION source — an asymmetry inside the very path
    #     US-41.5 unified; and
    #   * every fetch resolved the URL twice.
    #
    # `Loopctl.Provider.get/3` now makes the whole decision through
    # `Loopctl.Egress.Policy` with `tenant_supplied_url: true`, which is what turns
    # a `:denylisted` verdict into the PERMANENT `:egress_blocked` on the default
    # (unmarked) path — so the SSRF denylist stays mandatory for EVERY tenant,
    # marked or not (worker-01 / GHSA-j7m9-ffmr-pwhm), and `denylist_gate/4` is the
    # single place that call is made. The purpose is `:ingest`: a host declared for
    # `inference` does NOT authorize loopctl to fetch tenant-supplied URLs.
    fetch_url(scope, url)
  end

  defp resolve_content(_scope, nil, _), do: {:error, :no_content}

  defp fetch_url(scope, url) do
    req_opts =
      [
        receive_timeout: 15_000,
        retry: :transient,
        max_retries: 1,
        # Do not follow redirects — a redirect hop would re-enter an unvalidated
        # URL and bypass the egress guard (worker-01 / GHSA-j7m9-ffmr-pwhm).
        # `Provider` sets this too for a pinned request; belt and braces.
        redirect: false,
        # #461 item 4: stream the response through a bounded collector that aborts
        # the transfer once the body exceeds @max_fetch_body_bytes (network-layer cap).
        into: &collect_capped_body/2
      ]
      |> maybe_add_plug()

    ctx = %{scope: scope, purpose: :ingest, tenant_supplied_url: true}

    case Provider.get(url, req_opts, ctx) do
      {:ok, %{private: %{ingestion_body_capped: true}}} ->
        Logger.warning(
          "ContentIngestionWorker: URL fetch aborted — body exceeds " <>
            "#{@max_fetch_body_bytes} bytes (url=#{url})"
        )

        {:error, {:url_body_too_large, @max_fetch_body_bytes}}

      {:ok, %{status: status} = resp} when status in 200..299 ->
        # `resp.body` is the iolist accumulated by `collect_capped_body/2`; flatten it
        # back to a binary for the extractor.
        handle_fetched_body(
          IO.iodata_to_binary(resp.body),
          Req.Response.get_header(resp, "content-type")
        )

      {:ok, %{status: status}} ->
        Logger.warning(
          "ContentIngestionWorker: URL fetch failed " <>
            "(url=#{url}, status=#{status})"
        )

        {:error, {:url_fetch_failed, status}}

      {:error, refusal} when is_egress_refusal(refusal) ->
        # US-41.4: the ingestion FETCH was refused by the egress guard. Propagate the
        # refusal unchanged so `perform/1` maps it through `Egress.oban_result/1`
        # (cancel vs snooze) instead of burying it in a generic fetch error.
        {:error, refusal}

      {:error, reason} ->
        Logger.warning(
          "ContentIngestionWorker: URL fetch error " <>
            "(url=#{url}, error=#{inspect(reason)})"
        )

        {:error, {:url_fetch_error, reason}}
    end
  end

  # Guard a fetched body BEFORE it reaches strip_html (which runs regex over the
  # bytes) or the JSON-encoded extractor request (#263). A binary Content-Type,
  # or a body that isn't valid UTF-8 (a mislabeled binary), is discarded cleanly
  # so Oban never retries a deterministically-failing PDF/binary crash-loop.
  defp handle_fetched_body(body, content_type_values) do
    content_type = List.first(List.wrap(content_type_values))

    cond do
      is_binary(content_type) and binary_content_type?(content_type) ->
        unsupported_content_discard("Content-Type \"#{content_type}\"")

      not String.valid?(body) ->
        unsupported_content_discard("fetched body")

      true ->
        {:ok, strip_html(body)}
    end
  end

  # UTF-8 guard for the direct-content path (#263). There is no Content-Type to
  # consult here, so validity is the whole check. Returns {:ok, content} for
  # ingestible text, or {:discard, {:unsupported_content, msg}} — which Oban
  # DISCARDS (no infinite retry) and never raises — for non-UTF-8 (PDF/binary).
  defp ensure_utf8_text(content) when is_binary(content) do
    if String.valid?(content) do
      {:ok, content}
    else
      unsupported_content_discard("content")
    end
  end

  defp binary_content_type?(content_type) do
    normalized =
      content_type
      |> String.downcase()
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()

    String.starts_with?(normalized, @binary_content_type_prefixes) or
      normalized in @binary_application_content_types
  end

  defp unsupported_content_discard(what) do
    reason =
      "#{what} is not UTF-8 text (looks like PDF/binary); " <>
        "PDF/binary text extraction is not supported on this endpoint"

    Logger.warning("ContentIngestionWorker: discarding job — #{reason}")
    {:discard, {:unsupported_content, reason}}
  end

  defp derive_source_id(content_hash) do
    # Derive a deterministic UUID from the content hash.
    # Hash the content_hash with SHA256 to ensure we always have 32 bytes,
    # then format the first 16 bytes as a UUID string.
    <<uuid_bytes::binary-size(16), _rest::binary>> =
      :crypto.hash(:sha256, content_hash)

    <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
      e::binary-size(6)>> = uuid_bytes

    raw_uuid = a <> b <> c <> d <> e

    raw_uuid
    |> Base.encode16(case: :lower)
    |> format_uuid_hex()
  end

  defp format_uuid_hex(
         <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
           e::binary-size(12)>>
       ) do
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  defp maybe_add_plug(opts) do
    case Application.get_env(:loopctl, :ingestion_req_plug) do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end

  # `into:` collector that enforces the @max_fetch_body_bytes network-layer cap
  # (#461 item 4). Accumulates the streamed body; the instant it crosses the ceiling
  # it flags the response (`ingestion_body_capped`) and returns `{:halt, _}`, so Req
  # stops reading and closes the connection instead of buffering an unbounded stream.
  # A normally-completed fetch stays under the cap (the crossing chunk always halts),
  # so `fetch_url/2` can treat the flag as an unambiguous "too large" signal.
  #
  # The accumulator is an IOLIST (`[resp.body, data]`), not a `resp.body <> data`
  # binary concat: because Req threads the accumulator back through its stream loop
  # between reductions, the BEAM writable-binary append optimization does not apply to
  # a binary accumulator, so each chunk would copy the entire buffer so far — O(n^2)
  # total bytes over a multi-chunk stream. Appending to an iolist is O(1) per chunk and
  # the running byte total is tracked in a `:ingestion_body_bytes` private counter (so
  # the cap check never has to walk the accumulated iodata), giving O(n) overall.
  # `fetch_url/2` flattens the iolist back to a binary via `IO.iodata_to_binary/1`
  # before handing it to the extractor.
  #
  # Public (`@doc false`) rather than private only so the cumulative multi-chunk
  # crossing path can be unit-tested directly: `Req.Test`/`plug:` delivers a stubbed
  # body as a SINGLE `{:data, _}` message (Req buffers `send_chunked`/`chunk` output),
  # so the `:cont` accumulation branch this cap actually defends against under the real
  # Finch adapter is not reachable through a stub — see the worker test.
  @doc false
  def collect_capped_body({:data, data}, {req, resp}) do
    new_size = Req.Response.get_private(resp, :ingestion_body_bytes, 0) + byte_size(data)
    resp = %{resp | body: [resp.body, data]}

    if new_size > @max_fetch_body_bytes do
      capped = Req.Response.put_private(resp, :ingestion_body_capped, true)
      {:halt, {req, capped}}
    else
      {:cont, {req, Req.Response.put_private(resp, :ingestion_body_bytes, new_size)}}
    end
  end

  # `body` is always a binary here: `handle_fetched_body/2`'s sole caller flattens the
  # fetched iolist with `IO.iodata_to_binary/1` and the cond above already routes
  # non-UTF-8 bytes to a discard, so no non-binary/invalid fallback clause is reachable.
  defp strip_html(body) do
    body
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp validate_and_filter(raw_articles) do
    raw_articles
    |> Enum.take(@max_articles)
    |> Enum.filter(&valid_article?/1)
  end

  defp valid_article?(attrs) when is_map(attrs) do
    valid_title?(attrs) and valid_body?(attrs) and valid_category?(attrs) and valid_tags?(attrs)
  end

  defp valid_article?(_), do: false

  defp valid_title?(attrs) do
    title = Map.get(attrs, :title) || Map.get(attrs, "title")
    is_binary(title) and title != "" and String.length(title) <= 500
  end

  defp valid_body?(attrs) do
    body = Map.get(attrs, :body) || Map.get(attrs, "body")
    is_binary(body) and String.length(body) <= @max_body_length
  end

  defp valid_category?(attrs) do
    category = Map.get(attrs, :category) || Map.get(attrs, "category")
    normalize_category(category) in @valid_categories
  end

  @category_string_map Map.new(@valid_categories, fn cat -> {Atom.to_string(cat), cat} end)

  defp normalize_category(cat) when is_atom(cat), do: cat
  defp normalize_category(cat) when is_binary(cat), do: Map.get(@category_string_map, cat)
  defp normalize_category(_), do: nil

  defp valid_tags?(attrs) when is_map(attrs) do
    tags = Map.get(attrs, :tags) || Map.get(attrs, "tags") || []
    validate_tag_list(tags)
  end

  defp validate_tag_list(tags) when is_list(tags) do
    length(tags) <= @max_tags and Enum.all?(tags, &valid_single_tag?/1)
  end

  defp validate_tag_list(_), do: false

  defp valid_single_tag?(tag) do
    is_binary(tag) and String.length(tag) <= @max_tag_length and Regex.match?(@tag_pattern, tag)
  end

  defp insert_articles(_ctx, [], _chunk_index), do: {:ok, 0}

  defp insert_articles(ctx, articles, chunk_index) do
    ctx
    |> build_rows(articles, chunk_index)
    |> persist_rows(ctx)
  end

  # Validate each article via the changeset (insert_all bypasses validation), then
  # dump the VALID ones to insert_all row maps. Invalid articles are dropped, as
  # before. id + timestamps are set here because insert_all does not autogenerate.
  defp build_rows(ctx, articles, chunk_index) do
    status = if ctx.publish, do: :published, else: :draft
    # perform/1 already discarded jobs with an invalid project_id; this valid_uuid?
    # guard is defense in depth so a non-UUID can NEVER dump against the :binary_id
    # column — it falls back to tenant-wide instead of crashing.
    project_id = if valid_uuid?(ctx.project_id), do: ctx.project_id, else: nil
    now = DateTime.utc_now()

    articles
    |> Enum.with_index()
    |> Enum.flat_map(fn {attrs, index} ->
      # normalize_attrs whitelists keys; :status is dropped and idempotency_key is
      # server-derived and set AFTER normalize_attrs so extractor output can never
      # override either (#264 Finding 1). The idempotency_key is deterministic
      # across retries so on_conflict can no-op a re-inserted (chunk, article).
      attrs =
        attrs
        |> normalize_attrs()
        |> Map.delete(:status)
        |> Map.put(:idempotency_key, ingest_idempotency_key(ctx.fetched_hash, chunk_index, index))

      base = %Article{
        tenant_id: ctx.tenant_id,
        source_type: ctx.source_type,
        source_id: ctx.source_id,
        status: status,
        project_id: project_id
      }

      changeset = Article.create_changeset(base, attrs)

      if changeset.valid? do
        [changeset_to_row(changeset, now)]
      else
        Logger.warning(
          "ContentIngestionWorker: dropping invalid article: #{inspect(changeset.errors)}"
        )

        []
      end
    end)
  end

  @insert_all_fields ~w(
    tenant_id title body category status scope slug tags
    source_type source_id idempotency_key metadata project_id
  )a
  defp changeset_to_row(changeset, now) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> Map.take(@insert_all_fields)
    |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})
  end

  defp persist_rows([], _ctx), do: {:ok, 0}

  # Persist a chunk's validated rows with insert_all + RETURNING so the returned
  # set reflects ONLY genuinely-inserted rows (conflict-skipped rows are NOT in
  # RETURNING). Audit + embeddings are built from THOSE real rows — never from the
  # client-minted changeset ids, which on_conflict :nothing would otherwise leave
  # pointing at rows that were never inserted (#264 review F1: phantom audit +
  # leaked embedding jobs on retry).
  defp persist_rows(rows, ctx) do
    multi =
      Multi.new()
      |> Multi.insert_all(:articles, Article, rows,
        on_conflict: :nothing,
        conflict_target: {:unsafe_fragment, @idempotency_conflict_target},
        returning: [:id]
      )
      |> Multi.merge(fn %{articles: {_count, returned}} -> audit_multi(ctx, returned) end)

    run_persist(multi, ctx)
  rescue
    # insert_all does not map constraint violations to changeset errors (there is
    # no changeset) — it RAISES. A title/slug unique collision surfaces here; we
    # classify it permanent in permanent_error?/1 so it discards instead of
    # burning every retry (#264 review F2).
    error in Postgrex.Error ->
      Logger.warning("ContentIngestionWorker: insert_all raised: #{inspect(error)}")
      {:error, {:insert_failed, :constraint, error}}
  end

  defp run_persist(multi, ctx) do
    case AdminRepo.transaction(multi) do
      {:ok, %{articles: {_count, returned}}} ->
        # Published articles need embeddings; enqueue AFTER commit, best-effort,
        # and ONLY for the rows that were genuinely inserted this run.
        if ctx.publish, do: enqueue_embeddings(ctx.tenant_id, returned)

        Logger.info(
          "ContentIngestionWorker: persisted #{length(returned)} new article(s) " <>
            "(source_type=#{ctx.source_type}, url=#{ctx.url || "inline"}, publish=#{ctx.publish})"
        )

        {:ok, length(returned)}

      {:error, step, reason, _completed} ->
        Logger.warning(
          "ContentIngestionWorker: insert failed at step #{inspect(step)}: #{inspect(reason)}"
        )

        {:error, {:insert_failed, step, reason}}
    end
  end

  # Conditional audit: write the `knowledge.content_ingested` event ONLY when rows
  # were genuinely inserted. On a retry where every article conflict-skips, the
  # returned set is empty and we write NO audit row — never a phantom "ingested"
  # entry for rows that already existed (#264 review F1, chain-of-custody).
  defp audit_multi(_ctx, [] = _returned), do: Multi.new()

  defp audit_multi(ctx, returned) do
    ids = Enum.map(returned, & &1.id)
    Audit.log_in_multi(Multi.new(), :audit, fn _changes -> ingested_audit_attrs(ctx, ids) end)
  end

  defp ingested_audit_attrs(ctx, ids) do
    status = if ctx.publish, do: :published, else: :draft

    %{
      tenant_id: ctx.tenant_id,
      entity_type: "article",
      entity_id: ctx.source_id,
      action: "knowledge.content_ingested",
      actor_type: "system",
      actor_id: nil,
      actor_label: "worker:content_ingestion",
      new_state: %{
        "source_type" => ctx.source_type,
        "url" => ctx.url,
        "article_count" => length(ids),
        "article_ids" => ids,
        # Record whether ingested articles went live (publish opt-in) or were
        # staged as drafts, so an operator can tell auto-published content apart
        # from review-staged content in the audit trail.
        "status" => to_string(status)
      }
    }
  end

  # Enqueue embedding jobs for the just-inserted (published) articles. Runs
  # post-commit and is best-effort: a transient enqueue failure is logged, never
  # raised, so it can't fail/retry the whole ingestion job.
  #
  # US-37.4 (HIGH review): this is the PRIMARY automated bulk article-ingest path
  # (up to ~60 articles per job), so it BATCHES — chunk the inserted rows into groups
  # of `Knowledge.embedding_batch_max/0` (~100) and enqueue ONE
  # `BatchArticleEmbeddingWorker` per chunk, which embeds the whole chunk in a single
  # provider array call (one admission token + one concurrency slot per batch). This
  # collapses the old per-article `ArticleEmbeddingWorker` fan-out that issued one
  # provider round-trip per ingested article — the exact amplification US-37.4
  # targets. Per-chunk `Oban.insert/1` (NOT `insert_all`) so the batch worker's
  # `unique:` window is honored (the basic Oban engine ignores `unique:` for
  # `insert_all`). The interactive single-article publish path stays per-record.
  defp enqueue_embeddings(tenant_id, returned) do
    returned
    |> Enum.chunk_every(Knowledge.embedding_batch_max())
    |> Enum.each(fn chunk ->
      %{article_ids: Enum.map(chunk, & &1.id), tenant_id: tenant_id}
      |> BatchArticleEmbeddingWorker.new()
      |> Oban.insert()
    end)
  rescue
    e ->
      Logger.error("ContentIngestionWorker: embedding enqueue failed: #{Exception.message(e)}")
      :ok
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.map(fn
      {"title", v} -> {:title, v}
      {"body", v} -> {:body, v}
      {"category", v} -> {:category, v}
      {"tags", v} -> {:tags, v}
      {"metadata", v} -> {:metadata, v}
      {k, v} when is_atom(k) -> {k, v}
      {_k, _v} -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  # DETERMINISTIC per-CHUNK idempotency prefix from (fetched_hash, chunk_index),
  # where `fetched_hash = sha256(actually-resolved bytes for this attempt)` — NOT the
  # enqueue-time content_hash (#179 review round 4). The per-article key appends
  # ":<article_index>" (below), so ALL of a chunk's articles share this prefix — which
  # lets `persisted_chunk_titles/2` detect a committed chunk via a `LIKE prefix || ':%'`
  # query and SKIP re-extraction on a retry (round-3 #1: re-extracting an
  # already-persisted chunk re-BILLS the tenant's Anthropic key) ONLY when the resolved
  # bytes are byte-identical across attempts. SHA-256 hex keeps it bounded.
  defp ingest_chunk_prefix(fetched_hash, chunk_index) do
    digest =
      :sha256
      |> :crypto.hash("#{fetched_hash}:#{chunk_index}")
      |> Base.encode16(case: :lower)

    "ingest:" <> digest
  end

  # DETERMINISTIC per-article idempotency key = chunk prefix + ":" + article index.
  # NEVER from the LLM output (which varies across calls, #264 Finding 1). Identical
  # across Oban retries FOR IDENTICAL fetched bytes, so a retry re-reaching the same
  # (chunk, article) slot conflicts on `articles_tenant_idempotency_key_idx` and no-ops
  # (backstop to the chunk-skip above).
  defp ingest_idempotency_key(fetched_hash, chunk_index, article_index) do
    ingest_chunk_prefix(fetched_hash, chunk_index) <> ":" <> Integer.to_string(article_index)
  end

  # Titles of the articles a PRIOR attempt already persisted for this chunk (empty
  # list = not yet persisted). Keyed on the deterministic per-chunk idempotency
  # prefix; the digest + integer index contain no LIKE wildcards, so the pattern is
  # injection-safe. Used both to SKIP re-extraction and to seed cross-chunk dedup.
  defp persisted_chunk_titles(ctx, chunk_index) do
    pattern = ingest_chunk_prefix(ctx.fetched_hash, chunk_index) <> ":%"

    from(a in Article,
      where: a.tenant_id == ^ctx.tenant_id and like(a.idempotency_key, ^pattern),
      select: a.title
    )
    |> AdminRepo.all()
  end

  defp normalize_persisted_title(title) do
    (title || "") |> String.trim() |> String.downcase()
  end
end
