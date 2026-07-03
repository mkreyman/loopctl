defmodule Loopctl.Workers.ContentIngestionWorker do
  @moduledoc """
  Oban worker that ingests external content and extracts knowledge articles.

  Runs in the `:knowledge` queue with concurrency 5. When content is submitted
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
    queue: :knowledge,
    max_attempts: 3,
    unique: [
      keys: [:content_hash, :tenant_id],
      period: 3600,
      states: [:scheduled, :available, :executing, :retryable]
    ]

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ContentChunker
  alias Loopctl.Net.UrlGuard
  alias Loopctl.Workers.ArticleEmbeddingWorker

  @content_extractor Application.compile_env(
                       :loopctl,
                       :content_extractor,
                       Loopctl.Knowledge.ClaudeContentExtractor
                     )

  @max_articles 10
  @max_body_length 100_000

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
  # Concrete values:
  #   * @per_chunk_timeout_ms = 30s — ~2x+ headroom over the observed 7–13s so a
  #     healthy chunk is never falsely timed out under tail latency/variance.
  #   * @max_job_timeout_ms   = 6 min — the ABSOLUTE ceiling a single job may hold
  #     a :knowledge slot (concurrency 5), independent of chunk count. Bounds abuse
  #     (GHSA-j7m9-ffmr-pwhm) while comfortably covering a realistic large doc.
  #   * @max_chunks = cap / per_chunk = 12 — a document chunking to MORE than this
  #     (>~96KB) can't be guaranteed within the cap, so we ingest the first
  #     @max_chunks (persisted incrementally) and {:discard} the rest cleanly with
  #     a count, rather than crash-looping or silently losing everything.
  @per_chunk_timeout_ms :timer.seconds(30)
  @max_job_timeout_ms :timer.minutes(6)
  @max_chunks div(@max_job_timeout_ms, @per_chunk_timeout_ms)

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
        args:
          %{
            "tenant_id" => tenant_id,
            "source_type" => source_type,
            "content_hash" => content_hash
          } = args
      }) do
    url = args["url"]
    raw_content = args["content"]
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
    with :ok <- validate_project_id(project_id),
         {:ok, content} <- resolve_content(url, raw_content) do
      ctx = %{
        tenant_id: tenant_id,
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
  # chunk and hard-capped at @max_job_timeout_ms. A hostile/slow endpoint still
  # can't pin a :knowledge queue slot beyond the cap (worker-01 /
  # GHSA-j7m9-ffmr-pwhm), while a legitimate multi-chunk document now gets enough
  # wall-clock to finish. For a URL job the fetched size is unknown until fetch,
  # so we grant the full capped budget; perform/1 self-limits to @max_chunks and
  # persists incrementally, so the cap is a backstop, not the mechanism.
  @impl Oban.Worker
  def timeout(%Oban.Job{args: args}) do
    args
    |> chunk_count_for_timeout()
    |> max(1)
    |> Kernel.*(@per_chunk_timeout_ms)
    |> min(@max_job_timeout_ms)
  end

  defp chunk_count_for_timeout(%{"content" => content})
       when is_binary(content) and content != "" do
    content |> ContentChunker.chunk() |> length()
  end

  defp chunk_count_for_timeout(%{"url" => url}) when is_binary(url) and url != "" do
    @max_chunks
  end

  defp chunk_count_for_timeout(_), do: 1

  # --- Private ---

  # Ingest a document chunk-by-chunk, PERSISTING each chunk's articles as it
  # completes (#264). A timeout or mid-run failure therefore keeps the articles
  # already extracted instead of discarding everything. Documents that chunk
  # beyond @max_chunks are ingested up to that bound and the remainder is
  # {:discard}ed cleanly (with a count) rather than silently lost.
  defp ingest_chunks(ctx, content) do
    chunks = ContentChunker.chunk(content)
    chunk_count = length(chunks)
    {processable, dropped} = Enum.split(chunks, @max_chunks)

    if chunk_count > 1 do
      Logger.info(
        "ContentIngestionWorker: #{byte_size(content)} bytes -> #{chunk_count} chunks " <>
          "(processing #{length(processable)}, deferring #{length(dropped)})"
      )
    end

    acc0 = %{inserted: 0, persisted: 0, attempted: 0, errors: [], seen_titles: MapSet.new()}

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
    |> finalize_ingest(chunk_count, dropped)
  end

  defp reduce_chunk(ctx, chunk, chunk_index, remaining, acc) do
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
    case @content_extractor.extract_from_content(chunk, source_type: ctx.source_type) do
      {:ok, extracted} ->
        {articles, seen_titles} =
          extracted
          |> dedup_articles()
          |> validate_and_filter()
          |> dedup_cross_chunk(seen_titles, remaining)

        case insert_articles(ctx, articles, chunk_index) do
          :ok -> {:ok, length(articles), seen_titles}
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
  #   * dropped chunks (document > @max_chunks) → {:discard} with an ACCURATE
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
    first = errors |> Enum.reverse() |> List.first()

    if Enum.all?(errors, &permanent_error?/1) do
      # No transient error a retry could clear — {:discard} (no infinite retry);
      # whatever persisted stays committed.
      {:discard,
       {:extraction_failed,
        "extraction permanently failed on #{length(errors)} chunk(s) " <>
          "(first: #{inspect(first)}); persisted #{inserted} article(s) from " <>
          "#{persisted} of #{attempted} attempted chunk(s) — not retryable"}}
    else
      # At least one transient error — retry the whole (idempotent) job so the
      # failed chunk(s) get re-attempted; persisted chunks no-op on conflict.
      {:error, first}
    end
  end

  # A permanent extractor failure a retry can't fix: a 4xx API error other than
  # 408 (timeout) / 429 (rate limited), which ARE transient. Everything else
  # (5xx, request_failed/transport, json_parse_error from a non-deterministic
  # model response) is treated as transient and retried.
  defp permanent_error?({:api_error, status, _body})
       when is_integer(status) and status >= 400 and status < 500 and status != 408 and
              status != 429,
       do: true

  defp permanent_error?(_), do: false

  defp too_large_message(chunk_count, dropped, inserted, attempted) do
    "document too large: #{chunk_count} chunks exceed the #{@max_chunks}-chunk per-job " <>
      "budget (cap #{div(@max_job_timeout_ms, 1000)}s); persisted #{inserted} article(s) " <>
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

  defp resolve_content(nil, content) when is_binary(content) and content != "" do
    # Direct-content path: no Content-Type to consult, so the UTF-8 validity
    # check is the whole guard (#263). Non-UTF-8 inline content (a PDF/binary
    # posted directly) would raise Jason.EncodeError inside the extractor's JSON
    # request and crash-loop; {:discard} it cleanly instead.
    ensure_utf8_text(content)
  end

  defp resolve_content(url, _content) when is_binary(url) do
    # SSRF egress guard (worker-01 / GHSA-j7m9-ffmr-pwhm). Validate AND pin the
    # user-supplied URL immediately before fetching (the controller also validates
    # at enqueue time). pin/1 resolves once and the connection targets that exact
    # IP, closing the DNS-rebinding / TOCTOU window.
    case UrlGuard.pin(url) do
      {:ok, pinned} -> fetch_url(url, pinned)
      {:error, reason} -> blocked_url(url, reason)
    end
  end

  defp resolve_content(nil, _), do: {:error, :no_content}

  defp blocked_url(url, reason) do
    Logger.warning(
      "ContentIngestionWorker: refusing to fetch blocked URL " <>
        "(url=#{url}, reason=#{reason})"
    )

    {:error, {:url_blocked, reason}}
  end

  defp fetch_url(url, pinned) do
    req_opts =
      UrlGuard.pinned_request_opts(pinned)
      |> Keyword.merge(
        receive_timeout: 15_000,
        retry: :transient,
        max_retries: 1,
        # Do not follow redirects — a redirect hop would re-enter an unvalidated
        # URL and bypass the egress guard (worker-01 / GHSA-j7m9-ffmr-pwhm).
        redirect: false
      )
      |> maybe_add_plug()

    case Req.get(req_opts) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        handle_fetched_body(resp.body, Req.Response.get_header(resp, "content-type"))

      {:ok, %{status: status}} ->
        Logger.warning(
          "ContentIngestionWorker: URL fetch failed " <>
            "(url=#{url}, status=#{status})"
        )

        {:error, {:url_fetch_failed, status}}

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

      is_binary(body) and not String.valid?(body) ->
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

  defp strip_html(body) when is_binary(body) do
    body
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp strip_html(body), do: inspect(body)

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

  defp insert_articles(_ctx, [], _chunk_index) do
    :ok
  end

  defp insert_articles(ctx, articles, chunk_index) do
    %{
      tenant_id: tenant_id,
      source_id: job_id,
      source_type: source_type,
      project_id: project_id,
      url: url,
      publish: publish,
      content_hash: content_hash
    } = ctx

    status = if publish, do: :published, else: :draft

    multi =
      articles
      |> Enum.with_index()
      |> Enum.reduce(Multi.new(), fn {attrs, index}, multi ->
        # normalize_attrs already whitelists keys, but drop :status explicitly so
        # the server-set status (above) can never be overridden by extractor
        # output, independent of future normalize_attrs changes. The
        # idempotency_key is server-derived and set AFTER normalize_attrs so an
        # extractor-supplied key can never override it (#264, Finding 1).
        attrs =
          attrs
          |> normalize_attrs()
          |> Map.delete(:status)
          |> Map.put(:idempotency_key, ingest_idempotency_key(content_hash, chunk_index, index))

        article = %Article{
          tenant_id: tenant_id,
          source_type: source_type,
          source_id: job_id,
          status: status
        }

        # perform/1 already discarded jobs with an invalid project_id; this
        # valid_uuid? guard is defense in depth so the raw struct assign can NEVER
        # dump a non-UUID against the :binary_id column (a pre-existing queued job
        # replayed through an older path would otherwise raise). A non-UUID here
        # falls back to tenant-wide rather than crashing.
        article =
          if valid_uuid?(project_id) do
            %{article | project_id: project_id}
          else
            article
          end

        changeset = Article.create_changeset(article, attrs)

        # on_conflict: :nothing over the partial `articles_tenant_idempotency_key_idx`
        # (WHERE idempotency_key IS NOT NULL) makes a retry that re-reaches an
        # already-persisted (content_hash, chunk_index, article_index) a safe NO-OP
        # instead of a duplicate row (#264, Finding 1).
        Multi.insert(multi, {:article, index}, changeset,
          on_conflict: :nothing,
          conflict_target:
            {:unsafe_fragment, "(tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL"}
        )
      end)
      |> Audit.log_in_multi(:audit, fn changes ->
        article_ids =
          changes
          |> Enum.filter(fn {key, _} -> match?({:article, _}, key) end)
          |> Enum.map(fn {_, article} -> article.id end)

        %{
          tenant_id: tenant_id,
          entity_type: "article",
          entity_id: job_id,
          action: "knowledge.content_ingested",
          actor_type: "system",
          actor_id: nil,
          actor_label: "worker:content_ingestion",
          new_state: %{
            "source_type" => source_type,
            "url" => url,
            "article_count" => length(article_ids),
            "article_ids" => article_ids,
            # Record whether ingested articles went live (publish opt-in) or were
            # staged as drafts, so an operator can tell auto-published content
            # apart from review-staged content in the audit trail.
            "status" => to_string(status)
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, changes} ->
        # Published articles need embeddings to be semantically searchable;
        # enqueue AFTER commit (Oban runs on a separate repo/pool). Drafts get
        # none. Best-effort: a transient enqueue failure must not fail the job
        # (the rows are durably committed).
        if publish, do: enqueue_embeddings(tenant_id, changes)

        Logger.info(
          "ContentIngestionWorker: extracted #{length(articles)} articles " <>
            "(source_type=#{source_type}, url=#{url || "inline"}, publish=#{publish})"
        )

        :ok

      {:error, step, changeset, _completed} ->
        Logger.warning(
          "ContentIngestionWorker: insert failed at step #{inspect(step)}: " <>
            "#{inspect(changeset)}"
        )

        {:error, {:insert_failed, step, changeset}}
    end
  end

  # Enqueue an embedding job for each just-inserted (published) article. Runs
  # post-commit and is best-effort: a transient enqueue failure is logged, never
  # raised, so it can't fail/retry the whole ingestion job.
  defp enqueue_embeddings(tenant_id, changes) do
    changes
    |> Enum.filter(fn {key, _} -> match?({:article, _}, key) end)
    |> Enum.each(fn {_key, article} ->
      %{article_id: article.id, tenant_id: tenant_id}
      |> ArticleEmbeddingWorker.new()
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

  # DETERMINISTIC per-article idempotency key from (content_hash, chunk_index,
  # article_index_within_chunk) — NEVER from the LLM output, which varies across
  # calls (#264, Finding 1). Identical across Oban retries (all three inputs are
  # deterministic), so a retry re-reaching the same (chunk, article) slot conflicts
  # on `articles_tenant_idempotency_key_idx` and no-ops instead of duplicating.
  # SHA-256 hex keeps the key bounded (67 chars) regardless of content_hash length.
  defp ingest_idempotency_key(content_hash, chunk_index, article_index) do
    digest =
      :sha256
      |> :crypto.hash("#{content_hash}:#{chunk_index}:#{article_index}")
      |> Base.encode16(case: :lower)

    "ingest:" <> digest
  end
end
