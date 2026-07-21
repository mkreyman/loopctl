defmodule Loopctl.Workers.KnowledgeReclassifyWorker do
  @moduledoc """
  Backfill worker that reclassifies the existing corpus onto the expanded
  taxonomy (see `Loopctl.Knowledge.Categories`).

  This is the engine for the one-time 77k reclassification. It is **not**
  scheduled — it is kicked on demand (see "Kicking" below) because it calls an
  LLM per article and has a real cost.

  ## Modes

  - `run_mode: "dry_run"` (default) — classifies every article but **writes
    nothing**. Each batch emits a `knowledge.reclassify_batch` audit event with
    a tally of what *would* change (including a `by_transition` breakdown such
    as `"convention->playbook" => 42`). Run this first and read the audit feed
    before committing.
  - `run_mode: "commit"` — actually updates `category` for articles where the
    classifier is confident AND the proposed category differs from the current
    one.

  ## Write-on-confident-change

  A write happens only when `confidence >= min_confidence` AND
  `proposed != current`. Low-confidence or same-category verdicts are no-ops, so
  the pass cannot regress an already-correct label on a coin-flip. Because the
  classifier only ever returns ACTIVE categories, every `convention` row that
  clears the threshold is moved off `convention` (the retired value), which is
  the point of the backfill.

  Re-running is safe and convergent: once an article is moved, a later pass sees
  `proposed == current` and writes nothing.

  ## Scale + cost bounds

  Processes the corpus in keyset batches (`batch_size`, default 100), chaining
  the next batch via a cursor so each job is bounded. `max_per_run` (default
  1000) caps how many articles a single *kick* will process before stopping;
  the next kick resumes from where it left off (forward by id). When the ceiling
  is hit mid-corpus that is logged, never silent.

  ## Kicking

      # tenant-wide dry run, default tunables:
      %{"mode" => "all_tenants", "run_mode" => "dry_run"}
      |> Loopctl.Workers.KnowledgeReclassifyWorker.new()
      |> Oban.insert()

      # a single tenant, committing, bigger ceiling:
      %{"tenant_id" => tid, "run_mode" => "commit", "max_per_run" => 80_000}
      |> Loopctl.Workers.KnowledgeReclassifyWorker.new()
      |> Oban.insert()

  `batch_size` / `max_per_run` / `min_confidence` are query-shaped tunables and
  may be passed in args (falling back to config, then to the defaults here).
  """

  use Oban.Worker,
    queue: :knowledge,
    max_attempts: 3,
    unique: [fields: [:worker, :args], period: 30]

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Egress
  alias Loopctl.Egress.Scope, as: EgressScope
  alias Loopctl.Knowledge.Article
  alias Loopctl.Oban.FairShare
  alias Loopctl.Tenants.Tenant

  @classifier Application.compile_env(
                :loopctl,
                :category_classifier,
                Loopctl.Knowledge.ClassifierRouter
              )

  @default_batch_size 100
  @default_max_per_run 1_000
  @default_min_confidence 0.75
  # Concurrent LLM classify calls per batch (backpressure). Conservative vs the
  # provider rate limit; tune via :knowledge_reclassify_max_concurrency.
  @default_max_concurrency 10
  @classify_timeout_ms 30_000
  # Outage resilience: if >= this fraction of a batch fails to classify, snooze
  # (retry same cursor) instead of advancing — an outage pauses, never skips.
  @default_snooze_error_rate 0.5
  @default_snooze_seconds 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_tenants"} = args}) do
    tenant_ids =
      from(t in Tenant, where: t.status == :active, select: t.id)
      |> AdminRepo.all()

    for tenant_id <- tenant_ids do
      args
      |> Map.drop(["mode"])
      |> Map.put("tenant_id", tenant_id)
      |> __MODULE__.new()
      |> Oban.insert()
    end

    :ok
  end

  def perform(%Oban.Job{id: id, args: %{"tenant_id" => tenant_id} = args}) do
    # US-36.2: fair-share gate on the shared :knowledge queue (the all_tenants
    # dispatcher clause above is NOT gated — it has no tenant_id). `id` excludes THIS
    # (already-executing) job from its own count — see FairShare.
    case FairShare.gate(tenant_id, :knowledge, id) do
      {:snooze, _n} = snooze -> snooze
      :ok -> reclassify_tenant(tenant_id, args)
    end
  end

  defp reclassify_tenant(tenant_id, args) do
    # Resolve the tenant's key + classification model ONCE per kick (review #19):
    # this both enforces mandatory BYO (Epic 28, #179) AND avoids a per-article
    # Loopctl.Llm.resolve/2 DB read across the batch — the resolved credentials are
    # threaded into every classify call.
    case Loopctl.Llm.resolve(tenant_id, :classification) do
      {:ok, resolved} ->
        run_tenant(tenant_id, resolved, args)

      {:error, :no_api_key} ->
        # No tenant Anthropic key → nothing to do. Skip cleanly (no snooze/retry
        # loop) rather than failing every classify call.
        Loopctl.Llm.record_blocked(tenant_id, :classification)
        :ok
    end
  end

  defp run_tenant(tenant_id, resolved, args) do
    run_mode = Map.get(args, "run_mode", "dry_run")

    batch_size =
      tunable_int(args, "batch_size", :knowledge_reclassify_batch_size, @default_batch_size)

    max_per_run =
      tunable_int(args, "max_per_run", :knowledge_reclassify_max_per_run, @default_max_per_run)

    min_confidence =
      tunable_float(
        args,
        "min_confidence",
        :knowledge_reclassify_min_confidence,
        @default_min_confidence
      )

    cursor = Map.get(args, "cursor")
    processed_so_far = Map.get(args, "processed", 0)

    batch = fetch_batch(tenant_id, cursor, batch_size)
    tally = process_batch(tenant_id, resolved, batch, run_mode, min_confidence)

    cond do
      # US-41.4 (AC-41.4.3): THIS is the classification worker the AC names. An
      # egress refusal is NOT an upstream outage: `:egress_blocked` is a permanent
      # local configuration state, so snoozing it would re-run the same cursor every
      # 60s FOREVER for a permanently blocked tenant while logging the misleading
      # "upstream likely unreachable". `Loopctl.Egress.oban_result/1` is the ONE
      # mapping — CANCEL on `:egress_blocked` (naming the scope and the offending
      # endpoint), SNOOZE on the recoverable `:pin_stale` / `:egress_unavailable`.
      tally.egress_refusal ->
        Logger.warning(
          "KnowledgeReclassifyWorker: tenant=#{tenant_id} classification refused by the " <>
            "egress guard — #{Egress.refusal_reason(tally.egress_refusal)}"
        )

        Egress.oban_result(tally.egress_refusal)

      transient_outage?(batch, tally) ->
        # A batch dominated by TRANSIENT errors (connection refused, timeout, 5xx,
        # 408/429) means the classifier upstream is unreachable -- NOT that the
        # articles or the tenant's key are bad. Snooze: Oban re-runs THIS SAME job
        # (same cursor) later WITHOUT consuming an attempt and WITHOUT advancing, so
        # an outage pauses the migration and resumes cleanly when connectivity
        # returns -- no articles skipped, no audit spam.
        snooze =
          Application.get_env(
            :loopctl,
            :knowledge_reclassify_snooze_seconds,
            @default_snooze_seconds
          )

        Logger.warning(
          "KnowledgeReclassifyWorker: tenant=#{tenant_id} batch failed to classify " <>
            "(#{tally.transient_errors}/#{tally.processed} transient); upstream likely " <>
            "unreachable. Snoozing #{snooze}s and retrying the same cursor (nothing skipped)."
        )

        {:snooze, snooze}

      true ->
        # PERMANENT errors (4xx auth/bad-request, unparseable) do NOT snooze — a
        # permanently-misconfigured tenant (bad key / bogus model) would otherwise
        # snooze every 60s forever (review #4). Log if permanent errors dominate,
        # then advance normally: those articles stay unchanged and the migration
        # progresses to completion rather than looping.
        maybe_warn_permanent(tenant_id, tally)
        log_audit(tenant_id, run_mode, tally, processed_so_far)
        new_processed = processed_so_far + tally.processed
        maybe_chain(batch, tenant_id, args, batch_size, max_per_run, new_processed)
        :ok
    end
  end

  # Snooze ONLY when TRANSIENT errors dominate the batch (a real outage). Permanent
  # errors never trigger a snooze, so a misconfigured tenant can't loop forever.
  defp transient_outage?([], _tally), do: false
  defp transient_outage?(_batch, %{processed: 0}), do: false

  defp transient_outage?(_batch, %{processed: processed, transient_errors: transient}) do
    transient / processed >= snooze_rate()
  end

  # When permanent errors dominate a batch, log it once (chain-of-custody breadcrumb
  # in the standard log stream) so a persistently bad key/model is visible instead of
  # silently no-oping the whole corpus.
  defp maybe_warn_permanent(tenant_id, %{processed: processed, permanent_errors: permanent})
       when processed > 0 do
    if permanent / processed >= snooze_rate() do
      Logger.warning(
        "KnowledgeReclassifyWorker: tenant=#{tenant_id} batch dominated by PERMANENT " <>
          "classify errors (#{permanent}/#{processed}) — likely a bad key/model. Advancing " <>
          "without retrying those articles (not an outage; not snoozing)."
      )
    end
  end

  defp maybe_warn_permanent(_tenant_id, _tally), do: :ok

  defp snooze_rate do
    Application.get_env(
      :loopctl,
      :knowledge_reclassify_snooze_error_rate,
      @default_snooze_error_rate
    )
  end

  # --- batch fetch (keyset by id) ---

  defp fetch_batch(tenant_id, cursor, batch_size) do
    from(a in Article,
      where: a.tenant_id == ^tenant_id,
      where: a.status == :published,
      order_by: [asc: a.id],
      limit: ^batch_size,
      select: %{
        id: a.id,
        title: a.title,
        body: a.body,
        category: a.category,
        metadata: a.metadata,
        # US-41.4 (AC-41.4.2): the article's own project is the egress scope its
        # title+body are classified under.
        project_id: a.project_id
      }
    )
    |> after_cursor(cursor)
    |> AdminRepo.all()
  end

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, cursor), do: where(query, [a], a.id > ^cursor)

  # --- per-batch processing ---

  # Classification is an LLM HTTP call per article — the batch bottleneck. Run
  # those concurrently with backpressure (Task.async_stream) so a 100-article
  # batch isn't 100 serial round-trips. Writes stay SERIAL (in the reduce, on the
  # worker process) so the small BYPASSRLS admin pool is never hit by N
  # concurrent updates.
  defp process_batch(tenant_id, resolved, batch, run_mode, min_confidence) do
    max_concurrency =
      Application.get_env(
        :loopctl,
        :knowledge_reclassify_max_concurrency,
        @default_max_concurrency
      )

    # Thread the ONCE-resolved credentials into every classify call (review #19).
    classify_opts = [api_key: resolved.api_key, model: resolved.model]

    batch
    |> Task.async_stream(
      fn article ->
        scope = EgressScope.new(tenant_id, article.project_id)
        {article, @classifier.classify(scope, article.title, article.body, classify_opts)}
      end,
      max_concurrency: max_concurrency,
      timeout: @classify_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(empty_tally(), &reduce_outcome(&1, &2, min_confidence, run_mode))
  end

  defp empty_tally do
    %{
      processed: 0,
      changed: 0,
      unchanged: 0,
      low_confidence: 0,
      errors: 0,
      transient_errors: 0,
      permanent_errors: 0,
      # The FIRST egress refusal seen in the batch (US-41.4, AC-41.4.3). It decides
      # the whole job's outcome: the guard's verdict is per-SCOPE, so every other
      # article in the batch would be refused identically.
      egress_refusal: nil,
      by_transition: %{}
    }
  end

  defp reduce_outcome({:ok, {article, {:ok, verdict}}}, acc, min_confidence, run_mode) do
    %{category: proposed, confidence: confidence} = verdict
    acc = %{acc | processed: acc.processed + 1}
    classify_outcome(acc, article, proposed, confidence, min_confidence, run_mode)
  end

  defp reduce_outcome({:ok, {_article, {:error, reason}}}, acc, _min_confidence, _run_mode) do
    acc = record_egress_refusal(acc, reason)

    # Classify error rate/transient split (review #4): a PERMANENT error (4xx
    # auth/bad-request, unparseable verdict, no_api_key) must not cause an infinite
    # snooze; only TRANSIENT errors (timeout/5xx/429/connection) signal an outage.
    count_error(acc, permanent_classify_error?(reason))
  end

  # A classification task that timed out or crashed -- TRANSIENT (a hung/slow
  # upstream, retryable). Count it processed+errored; its article is left for a
  # later run (commit writes are idempotent).
  defp reduce_outcome({:exit, _reason}, acc, _min_confidence, _run_mode) do
    count_error(acc, false)
  end

  defp count_error(acc, permanent?) do
    acc = %{acc | processed: acc.processed + 1, errors: acc.errors + 1}

    if permanent? do
      %{acc | permanent_errors: acc.permanent_errors + 1}
    else
      %{acc | transient_errors: acc.transient_errors + 1}
    end
  end

  # Remembers the FIRST egress refusal of the batch (nil-preserving: a later one
  # never overwrites it, so the reported endpoint is the one actually hit first).
  defp record_egress_refusal(%{egress_refusal: nil} = acc, reason) do
    case Egress.refusal(reason) do
      nil -> acc
      refusal -> %{acc | egress_refusal: refusal}
    end
  end

  defp record_egress_refusal(acc, _reason), do: acc

  # Permanent = a retry can't fix it: a 4xx (other than 408 timeout / 429 rate
  # limited, which ARE transient), an unparseable verdict, or a missing key.
  # Everything else (connection/timeout/5xx/request_failed) is transient.
  defp permanent_classify_error?(:no_api_key), do: true

  # US-41.4: an egress refusal is NEVER a transient upstream outage. Without this
  # clause the catch-all below buckets it as transient, which is what made the whole
  # batch look like an outage and drove the forever-snooze loop AC-41.4.3 forbids.
  defp permanent_classify_error?({tag, _details}) when tag in [:egress_blocked], do: true
  defp permanent_classify_error?(:unparseable_classification), do: true

  # US-41.3 (AC-41.3.4): a shape failure from the OpenAI-compatible sibling. The
  # configured model cannot emit the required JSON verdict, so no retry can fix it.
  defp permanent_classify_error?({:invalid_response_shape, _details}), do: true

  defp permanent_classify_error?({:api_error, status, _body})
       when is_integer(status) and status >= 400 and status < 500 and status != 408 and
              status != 429,
       do: true

  defp permanent_classify_error?(_), do: false

  defp classify_outcome(acc, article, proposed, confidence, min_confidence, run_mode) do
    current = article.category

    cond do
      confidence < min_confidence ->
        %{acc | low_confidence: acc.low_confidence + 1}

      proposed == current ->
        %{acc | unchanged: acc.unchanged + 1}

      true ->
        if run_mode == "commit", do: write_category(article, proposed, confidence)
        key = "#{current}->#{proposed}"

        %{
          acc
          | changed: acc.changed + 1,
            by_transition: Map.update(acc.by_transition, key, 1, &(&1 + 1))
        }
    end
  end

  defp write_category(article, proposed, confidence) do
    metadata =
      (article.metadata || %{})
      |> Map.put("reclassified_from", to_string(article.category))
      |> Map.put("reclassify_confidence", confidence)

    from(a in Article, where: a.id == ^article.id)
    |> AdminRepo.update_all(
      set: [category: proposed, metadata: metadata, updated_at: DateTime.utc_now()]
    )
  end

  # --- chaining (forward by id, bounded by max_per_run) ---

  defp maybe_chain(batch, tenant_id, args, batch_size, max_per_run, new_processed) do
    cond do
      length(batch) < batch_size ->
        # Last batch for this tenant — nothing more to do.
        :ok

      new_processed >= max_per_run ->
        Logger.info(
          "KnowledgeReclassifyWorker: tenant=#{tenant_id} reached max_per_run=#{max_per_run}; " <>
            "stopping this kick. Re-kick to resume forward from the last processed article."
        )

      true ->
        last_id = batch |> List.last() |> Map.fetch!(:id)

        args
        |> Map.put("cursor", last_id)
        |> Map.put("processed", new_processed)
        |> __MODULE__.new()
        |> Oban.insert()
    end
  end

  # --- audit ---

  defp log_audit(tenant_id, run_mode, tally, processed_so_far) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "knowledge_reclassify",
      entity_id: tenant_id,
      action: "knowledge.reclassify_batch",
      actor_type: "system",
      actor_id: nil,
      actor_label: "worker:knowledge_reclassify",
      new_state: %{
        "run_mode" => run_mode,
        "processed_before_this_batch" => processed_so_far,
        "batch" => %{
          "processed" => tally.processed,
          "changed" => tally.changed,
          "unchanged" => tally.unchanged,
          "low_confidence" => tally.low_confidence,
          "errors" => tally.errors,
          "transient_errors" => tally.transient_errors,
          "permanent_errors" => tally.permanent_errors,
          "by_transition" => tally.by_transition
        }
      }
    })
  end

  # --- tunables (args override config, which overrides the module default) ---

  defp tunable_int(args, arg_key, config_key, default) do
    case Map.get(args, arg_key) do
      n when is_integer(n) and n > 0 -> n
      _ -> config(config_key, default)
    end
  end

  defp tunable_float(args, arg_key, config_key, default) do
    case Map.get(args, arg_key) do
      n when is_number(n) -> n / 1
      _ -> config(config_key, default)
    end
  end

  defp config(key, default), do: Application.get_env(:loopctl, key, default)
end
