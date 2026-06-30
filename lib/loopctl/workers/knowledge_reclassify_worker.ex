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
  alias Loopctl.Knowledge.Article
  alias Loopctl.Tenants.Tenant

  @classifier Application.compile_env(
                :loopctl,
                :category_classifier,
                Loopctl.Knowledge.ClaudeCategoryClassifier
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

  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id} = args}) do
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
    tally = process_batch(batch, run_mode, min_confidence)

    if upstream_unavailable?(batch, tally) do
      # A mostly/entirely failed batch means the classifier upstream (Anthropic,
      # or this host's egress) is unreachable -- NOT that the articles are bad.
      # Snooze: Oban re-runs THIS SAME job (same cursor) later WITHOUT consuming
      # an attempt and WITHOUT advancing, so an outage pauses the migration and it
      # resumes cleanly when connectivity returns -- no articles skipped, no audit
      # spam. (The migration also runs on the Fly host, so a local outage at the
      # operator's site never touches it.)
      snooze =
        Application.get_env(
          :loopctl,
          :knowledge_reclassify_snooze_seconds,
          @default_snooze_seconds
        )

      Logger.warning(
        "KnowledgeReclassifyWorker: tenant=#{tenant_id} batch failed to classify " <>
          "(#{tally.errors}/#{tally.processed}); classifier upstream likely unreachable. " <>
          "Snoozing #{snooze}s and retrying the same cursor (nothing skipped)."
      )

      {:snooze, snooze}
    else
      log_audit(tenant_id, run_mode, tally, processed_so_far)
      new_processed = processed_so_far + tally.processed
      maybe_chain(batch, tenant_id, args, batch_size, max_per_run, new_processed)
      :ok
    end
  end

  # True when a non-empty batch came back with an error RATE at or above the
  # configured threshold -- the signal of an upstream/connectivity outage rather
  # than a few unparseable articles. (With the JSON-parse fix, genuine per-article
  # errors are rare, so a high rate almost always means the API is unreachable.)
  defp upstream_unavailable?([], _tally), do: false

  defp upstream_unavailable?(_batch, %{processed: 0}), do: false

  defp upstream_unavailable?(_batch, %{processed: processed, errors: errors}) do
    rate =
      Application.get_env(
        :loopctl,
        :knowledge_reclassify_snooze_error_rate,
        @default_snooze_error_rate
      )

    errors / processed >= rate
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
        metadata: a.metadata
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
  defp process_batch(batch, run_mode, min_confidence) do
    max_concurrency =
      Application.get_env(
        :loopctl,
        :knowledge_reclassify_max_concurrency,
        @default_max_concurrency
      )

    batch
    |> Task.async_stream(
      fn article -> {article, @classifier.classify(article.title, article.body)} end,
      max_concurrency: max_concurrency,
      timeout: @classify_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(empty_tally(), &reduce_outcome(&1, &2, min_confidence, run_mode))
  end

  defp empty_tally do
    %{processed: 0, changed: 0, unchanged: 0, low_confidence: 0, errors: 0, by_transition: %{}}
  end

  defp reduce_outcome({:ok, {article, {:ok, verdict}}}, acc, min_confidence, run_mode) do
    %{category: proposed, confidence: confidence} = verdict
    acc = %{acc | processed: acc.processed + 1}
    classify_outcome(acc, article, proposed, confidence, min_confidence, run_mode)
  end

  defp reduce_outcome({:ok, {_article, {:error, _reason}}}, acc, _min_confidence, _run_mode) do
    %{acc | processed: acc.processed + 1, errors: acc.errors + 1}
  end

  # A classification task that timed out or crashed -- count it processed+errored;
  # its article is simply left for a later run (commit writes are idempotent).
  defp reduce_outcome({:exit, _reason}, acc, _min_confidence, _run_mode) do
    %{acc | processed: acc.processed + 1, errors: acc.errors + 1}
  end

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
