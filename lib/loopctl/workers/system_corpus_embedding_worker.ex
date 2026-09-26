defmodule Loopctl.Workers.SystemCorpusEmbeddingWorker do
  @moduledoc """
  US-41.1 AC-41.1.7 — materializes the SYSTEM-scoped article corpus for ONE tenant,
  at that tenant's active embedding dimension, using that tenant's OWN credential.

  ## Why per-tenant and not once for everyone

  System articles (`scope: :system`, `tenant_id IS NULL`) are read by every tenant,
  so the obvious designs are to embed them once with an operator key, or to store
  their vector with a NULL `tenant_id`. Both were rejected by the AC and neither is
  implementable here:

    * There is NO operator embedding credential. Embeddings are mandatory BYO —
      `Loopctl.Knowledge.EmbeddingClient` returns `{:error, :no_api_key}` with no
      fallback, and the global operator key was deliberately removed. Reversing that
      is a separate, separately-argued decision.
    * A NULL `tenant_id` row can never satisfy the CONJUNCTIVE
      `x.tenant_id == ^tenant_id` predicate `Loopctl.HeavyRead`'s `guard!/2` requires
      of every BYPASSRLS read, and RLS does nothing on that path. The only way to
      make such a row reachable would be to WEAKEN that guard — degrading tenant
      isolation on every heavy read in the product. Forbidden by the AC.

  So each tenant materializes the shared corpus for itself: ordinary
  `article_embeddings` rows with the SHARED `article_id` and the REQUESTING tenant's
  `tenant_id`. The conjunctive predicate holds unchanged and no guard is relaxed.

  Until this worker has run for a tenant, the system corpus is KEYWORD-ONLY for it
  and `Loopctl.Embeddings.system_corpus_meta/2` says so explicitly in the search
  response `meta` — never a silent absence.

  ## Batching + self-continuation

  One job handles up to `Knowledge.embedding_batch_max/0` articles in ONE provider
  array call, then re-enqueues itself if more remain. The batch is every article with no
  row at the dimension or a row embedded from different text
  (`Embeddings.stale_system_articles/3`), so the worker is resumable, idempotent and safe
  to enqueue at any time.

  ## Error taxonomy

  Mirrors `Loopctl.Workers.BatchArticleEmbeddingWorker`: `:no_api_key` DISCARDS
  (mandatory BYO — the tenant simply has no key, retrying can never help),
  admission/breaker/throttle SNOOZE loss-free, permanent provider errors discard,
  and everything else retries.
  """

  # UNIQUE STATES, load-bearing (review #2): Oban's DEFAULT unique states include
  # `:executing`, so this worker's self-continuation conflicted with the very job
  # performing it and a multi-batch corpus stalled after one batch. `:executing` stays
  # OUT; `Embeddings.enqueue_system_corpus_materialization/2` refuses to queue beside an
  # executing run itself. `period` is unbounded (#896): with 300 s, a job queued or backing
  # off for longer than that no longer deduplicated, and a second run embedded the same
  # batch and billed the tenant twice. Continuing by INSERT rather than by snooze keeps
  # each batch at attempt 1: a snooze adds an attempt every time, and the attempt^4
  # backoff of a job that had snoozed through a large corpus ran to days.
  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 5,
    unique: [
      keys: [:tenant_id, :dim],
      period: :infinity,
      states: [:available, :scheduled, :retryable]
    ],
    replace: [scheduled: [:args, :scheduled_at]]

  require Logger

  import Loopctl.Egress, only: [is_egress_refusal: 1]

  alias Loopctl.Egress
  alias Loopctl.Embeddings
  alias Loopctl.Embeddings.Dimensions
  alias Loopctl.Embeddings.ShrinkLadder
  alias Loopctl.ExitTag
  alias Loopctl.Knowledge
  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Provider.Admission
  alias Loopctl.Provider.RetryAfter

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id} = args}) when is_binary(tenant_id) do
    # AC-41.1.11: the dimension is resolved ONCE for the whole batch and threaded
    # into every changeset — never re-read per article.
    #
    # `resolve_write_dimension/1` (review): this is a WRITE path, so it must PIN.
    # `active_dimension/1` left a tenant whose only embedded corpus is the system
    # corpus unpinned, and its DERIVED leg then moved under that populated corpus on
    # the next `embedding_model` edit.
    dim = args["dim"] || Embeddings.resolve_write_dimension(tenant_id)

    case Embeddings.stale_system_articles(tenant_id, dim, limit: batch_size()) do
      [] -> :ok
      articles -> materialize(tenant_id, dim, articles)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  # Materialization is driven by `Embeddings.stale_system_articles/3`: the articles with
  # no row, and the ones whose stored hash is not the hash of the text embedded below.
  # That comparison IS the content check, so every article it hands over is re-embedded.
  defp materialize(tenant_id, dim, articles) do
    embed_entries(tenant_id, dim, Enum.map(articles, fn a -> {a, embedding_text(a)} end))
  end

  # Through `ShrinkLadder.embed_batch/3` (#617). An input-too-long rejection used to
  # reach `handle_error/2`, where `permanent_provider_error?/1` is `true` for any 4xx —
  # so one over-long canonical DISCARDED the job and left that canonical keyword-only
  # for this tenant while `system_corpus_meta/2` kept reporting "semantic". The ladder
  # bisects to isolate the offender and truncates only it.
  #
  # Sub-split by the CUMULATIVE byte budget FIRST (`Knowledge.embedding_batch_max_chars/0`),
  # exactly as `BatchArticleEmbeddingWorker` does: the count cap does not bound aggregate
  # tokens, and an AGGREGATE rejection names no member — so without this the ladder would
  # bisect every batch on every run, paying the whole tree as routine rather than as the
  # one-time recovery it exists to be. Each sub-batch is stored before the next, so an
  # error later in the batch keeps what was already paid for (its hash now matches, so
  # `Embeddings.stale_system_articles/3` skips it on the retry).
  defp embed_entries(tenant_id, dim, entries) do
    entries
    |> ShrinkLadder.chunk_by_bytes(Knowledge.embedding_batch_max_chars(), fn {_a, text} ->
      text
    end)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case embed_sub_batch(tenant_id, dim, chunk) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
    |> case do
      :ok -> continue(tenant_id, dim, Enum.map(entries, fn {a, _text} -> a.id end))
      other -> other
    end
  end

  defp embed_sub_batch(tenant_id, dim, entries) do
    texts = Enum.map(entries, fn {_a, text} -> text end)

    result =
      ShrinkLadder.embed_batch(
        texts,
        &Knowledge.generate_embeddings(tenant_id, &1),
        label: "SystemCorpusEmbeddingWorker tenant=#{tenant_id}"
      )

    case result do
      {:ok, vectors} ->
        store_all(tenant_id, dim, zip_marked(entries, vectors, []))

      # A member the ladder could only embed as a PREFIX is stored MARKED, so a reader
      # that COMPARES vectors can tell it from a whole-text one (see `ShrinkLadder`).
      {:ok, vectors, truncated} ->
        store_all(tenant_id, dim, zip_marked(entries, vectors, truncated))

      # PARTIAL: the bisect embedded some members before another half failed (#617 review
      # follow-up). Those vectors are already billed, and a stored member's hash matches, so
      # `Embeddings.stale_system_articles/3` skips it on the retry: storing them is what
      # stops a deterministic failure re-paying for the same canonicals on every attempt.
      # The error still propagates.
      {:error, reason, partial} ->
        store_partial(tenant_id, dim, entries, partial)
        propagate(tenant_id, reason)

      {:error, reason} ->
        propagate(tenant_id, reason)
    end
  end

  defp propagate(_tenant_id, :embedding_batch_length_mismatch),
    do: {:error, :embedding_batch_length_mismatch}

  defp propagate(tenant_id, reason), do: handle_error(tenant_id, reason)

  # Best-effort: a store failure here must not mask the provider error the Oban outcome is
  # derived from.
  defp store_partial(_tenant_id, _dim, _entries, []), do: :ok

  defp store_partial(tenant_id, dim, entries, partial) do
    by_index = Map.new(Enum.with_index(entries), fn {entry, i} -> {i, entry} end)

    triples =
      Enum.flat_map(partial, fn {index, vector, truncated?} ->
        case Map.fetch(by_index, index) do
          {:ok, {article, text}} -> [{article, vector, hash_for(text, truncated?)}]
          :error -> []
        end
      end)

    Logger.info(
      "SystemCorpusEmbeddingWorker: tenant=#{tenant_id} storing #{length(triples)} " <>
        "already-embedded canonical(s) from a partially-failed batch, so the retry does " <>
        "not re-bill them."
    )

    store_all(tenant_id, dim, triples)
    :ok
  rescue
    e ->
      Logger.warning(
        "SystemCorpusEmbeddingWorker: tenant=#{tenant_id} could not store the salvaged " <>
          "partial batch (#{ExitTag.tag(e)}); those members re-embed on the retry."
      )

      :ok
  end

  # ONE batched hash read for the whole batch (AC-41.1.11: no per-item query).
  # Vectors are written only after the WHOLE array call succeeded, so a provider
  # failure means zero writes and the batch retries as a unit. The batch's vector
  # LENGTH is checked once, before the first write, so a model that does not emit
  # `dim` fails legibly instead of burning five attempts of provider spend.
  defp store_all(tenant_id, dim, triples) do
    case Dimensions.check_batch_length(Enum.map(triples, fn {_a, v, _h} -> v end), dim) do
      :ok -> do_store_all(tenant_id, dim, triples)
      {:error, {:dimension_mismatch, expected, actual}} -> discard_mismatch(expected, actual)
    end
  end

  defp zip_marked(entries, vectors, truncated) do
    marked = MapSet.new(truncated)

    entries
    |> Enum.zip(vectors)
    |> Enum.with_index(fn {{article, text}, vector}, index ->
      {article, vector, hash_for(text, MapSet.member?(marked, index))}
    end)
  end

  # Returns `:ok` WITHOUT continuing: `embed_entries/3` drives the sub-batches and calls
  # `continue/2` once, after the last one — continuing here would enqueue the next page
  # per sub-batch.
  defp do_store_all(tenant_id, dim, triples) do
    Enum.reduce_while(triples, :ok, fn {article, vector, hash}, :ok ->
      case Embeddings.materialize_system_article_embedding(
             tenant_id,
             article,
             vector,
             hash,
             dim
           ) do
        {:ok, _row} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp discard_mismatch(expected, actual) do
    Logger.error(
      "SystemCorpusEmbeddingWorker: model returned #{inspect(actual)}-dimension vectors but " <>
        "the tenant is recorded at #{expected}; discarding."
    )

    {:discard, {:dimension_mismatch, expected, actual}}
  end

  # Self-continuation: more stale rows means another batch, as a FRESH job (attempt 1).
  # See the `unique:` comment above for why this is an insert and not a snooze.
  defp continue(tenant_id, dim, embedded_ids) do
    case Embeddings.stale_system_articles(tenant_id, dim, limit: batch_size()) do
      [] -> :ok
      remaining -> continue_unless_stuck(tenant_id, dim, remaining, embedded_ids)
    end
  end

  # Something just stored that still reads stale means another batch would only pay again
  # for the same result. Stop; the read path's next fill starts a fresh run.
  defp continue_unless_stuck(tenant_id, dim, remaining, embedded_ids) do
    case for a <- remaining, a.id in embedded_ids, do: a.id do
      [] ->
        insert_continuation(tenant_id, dim)

      stuck ->
        Logger.error(
          "SystemCorpusEmbeddingWorker: tenant=#{tenant_id} dim=#{dim} articles still " <>
            "stale after being embedded: #{inspect(stuck)}"
        )

        :ok
    end
  end

  defp insert_continuation(tenant_id, dim) do
    %{tenant_id: tenant_id, dim: dim}
    |> __MODULE__.new(schedule_in: 1)
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:system_corpus_continuation_failed, reason}}
    end
  end

  defp handle_error(tenant_id, :no_api_key) do
    :telemetry.execute(
      [:loopctl, :embedding, :skipped_no_key],
      %{count: 1},
      %{tenant_id: tenant_id, source: "system_corpus"}
    )

    Llm.record_blocked(tenant_id, :embedding)
    {:discard, {:no_embedding_key, tenant_id}}
  end

  defp handle_error(_tenant_id, refusal) when is_egress_refusal(refusal),
    do: Egress.oban_result(refusal)

  defp handle_error(_tenant_id, :rate_limited_local),
    do: {:snooze, Admission.snooze_seconds()}

  defp handle_error(tenant_id, :circuit_open),
    do:
      {:snooze,
       max(Knowledge.circuit_breaker_cooldown_remaining(tenant_id), Admission.snooze_seconds())}

  defp handle_error(_tenant_id, {:api_error, _status, :provider_error, retry_after})
       when is_integer(retry_after),
       do: {:snooze, RetryAfter.snooze_seconds(retry_after)}

  defp handle_error(_tenant_id, reason) do
    sanitized = ProviderError.sanitize(reason)

    if Llm.permanent_provider_error?(reason) do
      {:discard, {:embedding_permanent_error, sanitized}}
    else
      {:error, sanitized}
    end
  end

  defp batch_size, do: Knowledge.embedding_batch_max()

  # The same 32,000-CHARACTER first attempt as before, named once (#617) so it cannot
  # drift from the rung `ShrinkLadder` starts below. Staleness hashes exactly this text
  # (`Embeddings.article_embedding_text/1`), so the cut must not change silently.
  defp embedding_text(article), do: Embeddings.article_embedding_text(article)

  defp content_hash(text), do: Embeddings.text_content_hash(text)

  defp hash_for(text, false), do: content_hash(text)
  defp hash_for(text, true), do: text |> content_hash() |> ShrinkLadder.truncated_hash()
end
