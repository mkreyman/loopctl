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
  array call, then re-enqueues itself if more remain. The batch query is an
  ANTI-JOIN against rows already present at the dimension, so the worker is
  resumable, idempotent and safe to enqueue at any time.

  ## Error taxonomy

  Mirrors `Loopctl.Workers.BatchArticleEmbeddingWorker`: `:no_api_key` DISCARDS
  (mandatory BYO — the tenant simply has no key, retrying can never help),
  admission/breaker/throttle SNOOZE loss-free, permanent provider errors discard,
  and everything else retries.
  """

  # UNIQUE STATES, load-bearing (review #2): Oban's DEFAULT unique states include
  # `:executing` and `:completed`, so this worker's self-continuation conflicted with
  # the very job performing it — `Oban.insert/1` returned the executing job, no
  # continuation was created, and `replace: [scheduled: …]` could not fire because
  # the conflict was not in `:scheduled`. A system corpus larger than one batch then
  # stayed partially materialized while `system_corpus_meta/2` kept reporting
  # `keyword_only` forever.
  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 5,
    unique: [
      keys: [:tenant_id, :dim],
      period: 300,
      states: [:available, :scheduled, :retryable]
    ],
    replace: [scheduled: [:args, :scheduled_at]]

  require Logger

  import Loopctl.Egress, only: [is_egress_refusal: 1]

  alias Loopctl.Egress
  alias Loopctl.Embeddings
  alias Loopctl.Embeddings.Dimensions
  alias Loopctl.Embeddings.ShrinkLadder
  alias Loopctl.Embeddings.TextBudget
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

  # Materialization is (re-)driven by `Embeddings.stale_system_articles/3`, which
  # reports both the NEVER-materialized articles and the ones whose parent has been
  # edited since (review: it used to be existence-only, so an edit to a system
  # article's body left every tenant's vector permanently stale, with
  # `system_corpus_meta/2` reporting "semantic" throughout and no repair path short
  # of manual deletion).
  #
  # Staleness is detected in SQL by `updated_at`, which is cheap but not exact: an
  # article can be touched without a content change. The ACTUAL content hash is
  # therefore compared HERE, before anything is spent — an unchanged article costs a
  # timestamp touch, never a provider call.
  defp materialize(tenant_id, dim, articles) do
    {unchanged, entries} =
      articles
      |> Enum.map(fn a -> {a, embedding_text(a)} end)
      |> split_unchanged(tenant_id, dim)

    # ONE update_all for every unchanged article (review) rather than a per-item UPDATE
    # in a path AC-41.1.11 otherwise de-N+1s.
    Embeddings.touch_system_article_embeddings(
      tenant_id,
      Enum.map(unchanged, fn {article, _text} -> article.id end),
      dim
    )

    embed_entries(tenant_id, dim, entries)
  end

  defp embed_entries(tenant_id, dim, []), do: continue(tenant_id, dim)

  # Through `ShrinkLadder.embed_batch/3` (#617). An input-too-long rejection used to
  # reach `handle_error/2`, where `permanent_provider_error?/1` is `true` for any 4xx —
  # so one over-long canonical DISCARDED the job and left that canonical keyword-only
  # for this tenant while `system_corpus_meta/2` kept reporting "semantic". The ladder
  # bisects to isolate the offender and truncates only it.
  defp embed_entries(tenant_id, dim, entries) do
    texts = Enum.map(entries, fn {_a, text} -> text end)

    result =
      ShrinkLadder.embed_batch(
        texts,
        &Knowledge.generate_embeddings(tenant_id, &1),
        label: "SystemCorpusEmbeddingWorker tenant=#{tenant_id}"
      )

    case result do
      {:ok, vectors} ->
        store_all(tenant_id, dim, Enum.zip(entries, vectors))

      {:error, :embedding_batch_length_mismatch} = mismatch ->
        mismatch

      {:error, reason} ->
        handle_error(tenant_id, reason)
    end
  end

  # ONE batched hash read for the whole batch (AC-41.1.11: no per-item query).
  defp split_unchanged(entries, tenant_id, dim) do
    hashes =
      Embeddings.article_embedded_hashes(
        tenant_id,
        Enum.map(entries, fn {a, _text} -> a.id end),
        dim
      )

    Enum.split_with(entries, fn {article, text} ->
      case Map.get(hashes, article.id) do
        stored when is_binary(stored) -> stored == content_hash(text)
        _ -> false
      end
    end)
  end

  # Vectors are written only after the WHOLE array call succeeded, so a provider
  # failure means zero writes and the batch retries as a unit. The batch's vector
  # LENGTH is checked once, before the first write, so a model that does not emit
  # `dim` fails legibly instead of burning five attempts of provider spend.
  defp store_all(tenant_id, dim, pairs) do
    case Dimensions.check_batch_length(Enum.map(pairs, fn {_entry, v} -> v end), dim) do
      :ok -> do_store_all(tenant_id, dim, pairs)
      {:error, {:dimension_mismatch, expected, actual}} -> discard_mismatch(expected, actual)
    end
  end

  defp do_store_all(tenant_id, dim, pairs) do
    result =
      Enum.reduce_while(pairs, :ok, fn {{article, text}, vector}, :ok ->
        case Embeddings.materialize_system_article_embedding(
               tenant_id,
               article,
               vector,
               content_hash(text),
               dim
             ) do
          {:ok, _row} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with :ok <- result do
      continue(tenant_id, dim)
    end
  end

  defp discard_mismatch(expected, actual) do
    Logger.error(
      "SystemCorpusEmbeddingWorker: model returned #{inspect(actual)}-dimension vectors but " <>
        "the tenant is recorded at #{expected}; discarding."
    )

    {:discard, {:dimension_mismatch, expected, actual}}
  end

  # Self-continuation: more unmaterialized rows means another batch. See the
  # `unique:` states comment above — with the default states this insert was
  # swallowed by the currently EXECUTING job and the run stopped after one batch.
  defp continue(tenant_id, dim) do
    if Embeddings.stale_system_articles(tenant_id, dim, limit: 1) == [] do
      :ok
    else
      %{tenant_id: tenant_id, dim: dim}
      |> __MODULE__.new(schedule_in: 1)
      |> Oban.insert()
      |> case do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, {:system_corpus_continuation_failed, reason}}
      end
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
  # drift from the rung `ShrinkLadder` starts below. The hash in `split_unchanged/3`
  # is computed over exactly this text, so the cut must not change silently.
  defp embedding_text(article) do
    TextBudget.initial("#{article.title}\n\n#{article.body}")
  end

  defp content_hash(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
end
