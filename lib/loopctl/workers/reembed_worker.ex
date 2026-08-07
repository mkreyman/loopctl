defmodule Loopctl.Workers.ReembedWorker do
  @moduledoc """
  US-41.1 AC-41.1.10 — the agent-triggerable RE-EMBED backfill that moves a
  tenant's corpus onto a NEW embedding dimension WITHOUT blacking out recall.

  Enqueued via `Loopctl.Embeddings.enqueue_reembed/2`. Reports progress through
  the existing job surfaces (Oban job state + `[:loopctl, :embedding, :reembed]`
  telemetry, which the cost/anomaly rollups already consume) and through
  `Loopctl.Embeddings.reembed_progress/2`.

  ## Why the OLD dimension must survive the window

  Uniqueness on the side table is `(id, dim)`, NOT `(id)`, precisely so the old and
  new vectors COEXIST. Recall keeps serving at the tenant's ACTIVE dimension for
  the whole window, and the QUERY embedding is generated against the model that
  produced the ACTIVE corpus — never the pending one. Only when the last batch
  reports completion does this worker flip `tenants.tenant_embedding_dimension` and
  drop the stale rows.

  That claim is IMPLEMENTED, not asserted (review): `tenants.tenant_embedding_model`
  pins the model that produced the active corpus, and
  `Loopctl.Embeddings.query_model_override/1` makes every ordinary embedding — query
  vectors AND newly-written article/memory vectors — use that PIN whenever the
  tenant's configured model has moved away from it. A re-embed requires the tenant to
  point `tenant_llm_settings.embedding_model` at the NEW model (that is the only way
  target-dimension vectors can be obtained at all), and from that moment the two
  disagree; this worker embeds with the PENDING model. The pending model is captured
  ONCE at ENQUEUE (`Embeddings.enqueue_reembed/2`) and threaded through every
  self-continuation in the job args, then embedded with as an explicit binary — NOT
  re-read from the tenant's live config per batch (review, finding 12). That keeps the
  whole corpus AND the completion pin on ONE model even if the tenant edits its
  configured model mid-run; a legacy job without the field falls back to `:configured`.
  `Embeddings.complete_reembed/3` then re-pins the dimension AND that same threaded
  model together, in the same transaction as the stale-row sweep — pinning the model
  only when it agrees with the target dimension, else NULL so the disagreement is
  disclosed (finding 8). Without the pin, either the re-embed could never complete
  (vectors kept arriving at the old length) or recall degraded to keyword-only for
  the entire, corpus-sized window.

  Do it the other way round — persist the new dimension first — and every query
  vector is at the pending dimension while the entire corpus is still at the old
  one, so NOTHING matches: a total search outage. That is the corpus blackhole this
  ordering exists to prevent.

  ## EVERYTHING the completion sweep deletes must be re-embedded first

  `Embeddings.drop_stale_dimensions/2` deletes off-dimension rows from BOTH side
  tables, so this worker migrates BOTH: tenant articles, per-tenant materializations
  of SYSTEM-scoped articles (whose `articles.tenant_id` is NULL — the embedding row
  carries the tenant), and agent MEMORIES. Anything the work queue does not
  enumerate but the sweep does delete is a permanent recall blackout for those rows;
  that is why the queue is sourced from the SIDE TABLES (`ae.tenant_id`), never from
  `articles.tenant_id`, and why `drop_stale_dimensions/2` re-checks the precondition
  itself and refuses to delete an incomplete corpus.

  ## One-time operation, not an online migration

  A re-embed re-bills the tenant for the whole corpus and takes as long as the
  corpus is large. It is documented and surfaced as a one-time operation; recall
  degrades in no way while it runs, but it is not something to trigger casually.
  """

  # UNIQUE STATES, load-bearing (review #2): Oban's DEFAULT unique states include
  # `:executing` and `:completed`, so a job re-enqueuing ITSELF from inside its own
  # `perform/1` conflicts with the very job doing the enqueueing — `Oban.insert/1`
  # returns the executing job, no continuation is created, and a corpus larger than
  # one batch silently stalls after batch 1 (never reaching `finish/2`, so the
  # dimension is never flipped). `:completed` is excluded for the same reason across
  # a re-run. The remaining states still collapse duplicate ENQUEUES, which is all
  # the uniqueness is for here.
  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 5,
    unique: [
      keys: [:tenant_id, :target_dim],
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
  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id, "target_dim" => target_dim} = args})
      when is_binary(tenant_id) and is_integer(target_dim) do
    if Embeddings.supported_dimension?(target_dim) do
      # The model that PRODUCES the pending corpus, captured at ENQUEUE and threaded
      # through every self-continuation (review, finding 12). Embedding with it — and
      # pinning it at completion — keeps the whole corpus AND the pin on ONE model even
      # if the tenant edits its configured model mid-run. A legacy job enqueued before
      # this field existed carries `nil` and falls back to `:configured`.
      run_batch(tenant_id, target_dim, Map.get(args, "embedding_model"))
    else
      {:discard, {:unsupported_dimension, target_dim}}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  # The work queue is keyed off "any dimension OTHER than the target", NOT off the
  # tenant's ACTIVE dimension (review #6). The active dimension is DERIVED
  # (`recorded || model || default`), so a model change alone can flip it to the
  # target while the whole corpus still sits at the old one — under the old
  # `active == target_dim -> :ok` short-circuit that tenant's re-embed became a
  # permanent no-op and its recall stayed empty forever.
  defp run_batch(tenant_id, target_dim, model) do
    batch = Knowledge.embedding_batch_max()

    case Embeddings.pending_reembed_articles(tenant_id, target_dim, batch) do
      [] -> memory_batch(tenant_id, target_dim, model, batch)
      articles -> embed_article_batch(tenant_id, target_dim, model, articles)
    end
  end

  # MEMORIES are re-embedded by the SAME job (review #1). They were previously
  # untouched, yet the completion sweep deletes `memory_embeddings` rows at every
  # non-target dimension — so a "successful" re-embed wiped 100% of the tenant's
  # agent-memory vectors with no replacement.
  defp memory_batch(tenant_id, target_dim, model, batch) do
    case Embeddings.pending_reembed_memories(tenant_id, target_dim, batch) do
      [] -> finish(tenant_id, target_dim, model)
      memories -> embed_memory_batch(tenant_id, target_dim, model, memories)
    end
  end

  # GROUPED BY PROJECT (review): every provider array call must carry exactly ONE
  # egress scope. `Knowledge.generate_embeddings/3` with no `:project_id` builds the
  # TENANT-WIDE `Egress.Scope`, and `Egress.Policy.local_only?/1` resolves the
  # effective marking as the MOST RESTRICTIVE of tenant and project — so a nil
  # project silently DROPS a project-only `local_only` marking. Since
  # `pending_reembed_articles/3` spans every project and `article_text/1` ships
  # title+body, an orchestrator-triggered re-embed was a one-shot bulk disclosure of
  # a local_only project's bodies to the tenant default endpoint. This mirrors
  # `BatchArticleEmbeddingWorker`, which groups for exactly this reason.
  #
  # Memories legitimately stay tenant-scoped: a memory has no project-level egress
  # marking to honour.
  defp embed_article_batch(tenant_id, target_dim, model, articles) do
    articles
    |> Enum.group_by(& &1.project_id)
    |> Enum.reduce_while(:ok, fn {project_id, group}, :ok ->
      entries = Enum.map(group, fn a -> {a, article_text(a)} end)

      result =
        embed_and_store(
          tenant_id,
          target_dim,
          model,
          entries,
          [project_id: project_id],
          fn triples ->
            Embeddings.upsert_article_embeddings(tenant_id, triples,
              dimension: target_dim,
              legacy_write: false
            )
          end
        )

      case result do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
    |> case do
      :ok -> finish_batch(tenant_id, target_dim, model)
      other -> other
    end
  end

  defp embed_memory_batch(tenant_id, target_dim, model, memories) do
    entries = Enum.map(memories, fn m -> {m, memory_text(m)} end)

    case embed_and_store(tenant_id, target_dim, model, entries, [], fn triples ->
           Embeddings.upsert_memory_embeddings(tenant_id, triples,
             dimension: target_dim,
             legacy_write: false
           )
         end) do
      :ok -> finish_batch(tenant_id, target_dim, model)
      other -> other
    end
  end

  defp finish_batch(tenant_id, target_dim, model) do
    emit_progress(tenant_id, Embeddings.reembed_progress(tenant_id, target_dim))
    continue(tenant_id, target_dim, model)
  end

  # ONE provider array call PER EGRESS SCOPE, ONE dimension check, then the batch
  # write. The dimension check is per BATCH and BEFORE the first write (review #10):
  # letting a wrong-length vector reach the changeset validator burned all five Oban
  # attempts on full-batch provider spend and discarded with an opaque changeset.
  #
  # `embedding_model: :configured` is the ONE deliberate opt-out from the AC-41.1.10
  # model pin (review): every OTHER embedding in the product is generated with the
  # model that produced the ACTIVE corpus, precisely so recall does not black out
  # while this runs. This worker's whole job is to produce vectors at the PENDING
  # model's dimension, so it — and only it — uses the tenant's currently configured
  # model.
  # The array call goes through `ShrinkLadder.embed_batch/3` (#617): an input-too-long
  # rejection used to fall through `handle_error/2` to `permanent_provider_error?/1`,
  # which is `true` for any 4xx — so ONE over-long article DISCARDED the job, the
  # re-embed never reached `complete_reembed/3`, and the tenant's recall stayed pinned
  # at the old dimension permanently. Dissolving to `ArticleEmbeddingWorker` (the
  # BatchArticleEmbeddingWorker answer) is wrong here: that worker writes the ACTIVE
  # dimension with the configured model, not this run's PENDING dimension and pinned
  # model. Bisect-then-ladder keeps both pins and truncates only the offender.
  #
  # Sub-split by the CUMULATIVE byte budget first (`Knowledge.embedding_batch_max_chars/0`),
  # exactly as `BatchArticleEmbeddingWorker` does and for the same reason: the count cap
  # does not bound aggregate tokens, so 100 x ~32K chars is ~800k tokens against a ~300k
  # per-request ceiling. That rejection names no member, so the ladder would bisect EVERY
  # batch EVERY night — paying the whole tree as routine rather than as the one-time
  # recovery it is for. Each sub-batch is embedded AND STORED before the next, so a
  # failure later in the run keeps what has already been paid for (the next attempt's
  # pending set no longer names those rows).
  defp embed_and_store(tenant_id, target_dim, model, entries, opts, store_fun) do
    entries
    |> ShrinkLadder.chunk_by_bytes(Knowledge.embedding_batch_max_chars(), fn {_s, text} ->
      text
    end)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case embed_sub_batch(tenant_id, target_dim, model, chunk, opts, store_fun) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  defp embed_sub_batch(tenant_id, target_dim, model, entries, opts, store_fun) do
    texts = Enum.map(entries, fn {_subject, text} -> text end)
    embed_opts = [embedding_model: reembed_model(model)] ++ opts

    result =
      ShrinkLadder.embed_batch(
        texts,
        &Knowledge.generate_embeddings(tenant_id, &1, embed_opts),
        label: "ReembedWorker tenant=#{tenant_id}"
      )

    case result do
      {:ok, vectors} ->
        store_checked(tenant_id, target_dim, entries, vectors, [], store_fun)

      # The ladder could only embed these members as a PREFIX. They are stored (recall
      # over part of an over-long text is the point of the ladder) but MARKED, so the
      # readers that COMPARE vectors — the consolidation corroboration gate, the memory
      # near-dup supersede — can tell a prefix from a whole text instead of judging one
      # against the other.
      {:ok, vectors, truncated} ->
        store_checked(tenant_id, target_dim, entries, vectors, truncated, store_fun)

      {:error, :embedding_batch_length_mismatch} = mismatch ->
        mismatch

      {:error, reason} ->
        handle_error(tenant_id, reason)
    end
  end

  # WHICH model this re-embed generates with. The model captured at ENQUEUE (finding
  # 12) is passed as an EXPLICIT binary so every batch — and the completion pin — uses
  # ONE model regardless of a mid-run config edit. A legacy job (`nil`, enqueued before
  # the field existed) falls back to `:configured`, the tenant's current setting, which
  # is the pre-review behaviour.
  defp reembed_model(nil), do: :configured
  defp reembed_model(model) when is_binary(model), do: model

  defp store_checked(tenant_id, target_dim, entries, vectors, truncated, store_fun) do
    case Dimensions.check_batch_length(vectors, target_dim) do
      :ok ->
        marked = MapSet.new(truncated)

        triples =
          entries
          |> Enum.zip(vectors)
          |> Enum.with_index(fn {{subject, text}, vector}, index ->
            {subject, vector, hash_for(text, MapSet.member?(marked, index))}
          end)

        # The side table ONLY (`legacy_write: false`, review). The target dimension
        # CAN legally be 1536 (reverting a 768 tenant to the hosted default), so the
        # dim-1536 dual-write guard is not enough on its own: writing `articles.embedding`
        # mid-run would publish the PENDING corpus's vectors to the still-serving legacy
        # read path, and for a system article (`articles.tenant_id IS NULL`, shared by
        # every tenant) it would clobber the global slot across tenants.
        with {:ok, _rows} <- store_fun.(triples) do
          :ok
        end

      {:error, {:dimension_mismatch, expected, actual}} ->
        Logger.error(
          "ReembedWorker: tenant=#{tenant_id} model returned #{inspect(actual)}-dimension " <>
            "vectors but the re-embed targets #{expected}; discarding rather than " <>
            "re-billing the provider for four more attempts."
        )

        {:discard, {:dimension_mismatch, expected, actual}}
    end
  end

  # Self-continuation. See the `unique:` comment above: without the narrowed unique
  # states this insert is swallowed by the CURRENTLY EXECUTING job and the run stops
  # after one batch. The insert result is checked so a genuine failure to schedule
  # the next batch retries the job rather than silently reporting success.
  defp continue(tenant_id, target_dim, model) do
    %{tenant_id: tenant_id, target_dim: target_dim, embedding_model: model}
    |> __MODULE__.new(schedule_in: 1)
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:reembed_continuation_failed, reason}}
    end
  end

  # COMPLETION — ONE transaction that VERIFIES, then pins, then sweeps
  # (`Embeddings.complete_reembed/2`).
  #
  # This used to pin FIRST and then call `drop_stale_dimensions/2`, which re-checks
  # `reembed_complete?/2` and can return `{:error, :reembed_incomplete}` — the
  # fail-closed guard for exactly the race where a new off-dimension row appears
  # after the last batch. When that guard fired the pin had ALREADY moved: recall
  # served the target corpus while the raced rows existed only at the old dimension,
  # silently absent from results; if the job then exhausted its attempts the tenant
  # was left permanently pinned at the target with un-migrated rows excluded from
  # recall (review). Verifying and pinning inside the sweep's transaction means the
  # pin moves only on an interleaving where the sweep is also safe.
  defp finish(tenant_id, target_dim, model) do
    case Embeddings.complete_reembed(tenant_id, target_dim, model) do
      {:ok, dropped} ->
        emit_progress(tenant_id, %{
          Embeddings.reembed_progress(tenant_id, target_dim)
          | complete: true
        })

        Logger.info(
          "ReembedWorker: tenant=#{tenant_id} completed re-embed onto #{target_dim} dims; " <>
            "dropped #{dropped} stale-dimension row(s)."
        )

        :ok

      # Something raced a new off-dimension row in: NOTHING was pinned or dropped,
      # so retrying is loss-free and recall is untouched meanwhile.
      {:error, :reembed_incomplete} ->
        {:error, :reembed_incomplete}

      {:error, :not_found} ->
        {:discard, {:tenant_not_found, tenant_id}}

      {:error, :unsupported_dimension} ->
        {:discard, {:unsupported_dimension, target_dim}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_progress(tenant_id, progress) do
    :telemetry.execute(
      [:loopctl, :embedding, :reembed],
      %{done: progress.done, pending: progress.pending, total: progress.total},
      %{
        tenant_id: tenant_id,
        target_dimension: progress.target_dimension,
        active_dimension: progress.active_dimension,
        complete: progress.complete
      }
    )
  end

  defp handle_error(tenant_id, :no_api_key) do
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

  # `TextBudget.initial/1` is the same 32,000-CHARACTER cut this worker has always
  # applied, now named once (#617) so the first attempt cannot drift away from the
  # rung the ladder starts below. It stays CHARACTERS on purpose: a byte cap here
  # would silently shorten multi-byte text the provider was already accepting.
  defp article_text(article) do
    TextBudget.initial("#{article.title}\n\n#{article.body}")
  end

  defp memory_text(memory), do: TextBudget.initial(memory.text || "")

  defp content_hash(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)

  defp hash_for(text, false), do: content_hash(text)
  defp hash_for(text, true), do: text |> content_hash() |> ShrinkLadder.truncated_hash()
end
