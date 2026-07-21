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

  Do it the other way round — persist the new dimension first — and every query
  vector is at the pending dimension while the entire corpus is still at the old
  one, so NOTHING matches: a total search outage. That is the corpus blackhole this
  ordering exists to prevent.

  ## One-time operation, not an online migration

  A re-embed re-bills the tenant for the whole corpus and takes as long as the
  corpus is large. It is documented and surfaced as a one-time operation; recall
  degrades in no way while it runs, but it is not something to trigger casually.
  """

  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 5,
    unique: [keys: [:tenant_id, :target_dim], period: 300],
    replace: [scheduled: [:args, :scheduled_at]]

  require Logger

  import Ecto.Query
  import Loopctl.Egress, only: [is_egress_refusal: 1]

  alias Loopctl.AdminRepo
  alias Loopctl.Egress
  alias Loopctl.Embeddings
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Provider.Admission
  alias Loopctl.Provider.RetryAfter

  @max_text_length 32_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id, "target_dim" => target_dim}})
      when is_binary(tenant_id) and is_integer(target_dim) do
    if Embeddings.supported_dimension?(target_dim) do
      run_batch(tenant_id, target_dim)
    else
      {:discard, {:unsupported_dimension, target_dim}}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  defp run_batch(tenant_id, target_dim) do
    active = Embeddings.active_dimension(tenant_id)

    if active == target_dim do
      # Already the active dimension — nothing pending, nothing to flip.
      :ok
    else
      pending_batch(tenant_id, active, target_dim)
    end
  end

  defp pending_batch(tenant_id, active, target_dim) do
    case pending_articles(tenant_id, active, target_dim, Knowledge.embedding_batch_max()) do
      [] -> finish(tenant_id, target_dim)
      articles -> embed_batch(tenant_id, target_dim, articles)
    end
  end

  # Articles with a vector at the ACTIVE dimension but none yet at the target — the
  # resumable, idempotent work queue. An anti-join, so an interrupted run resumes
  # exactly where it stopped and a completed run is an immediate no-op.
  defp pending_articles(tenant_id, active, target_dim, limit) do
    AdminRepo.all(
      from(a in Article,
        as: :article,
        join: ae in ArticleEmbedding,
        on: ae.article_id == a.id and ae.tenant_id == ^tenant_id and ae.dim == ^active,
        where: a.tenant_id == ^tenant_id,
        where:
          not exists(
            from(t in ArticleEmbedding,
              where:
                t.article_id == parent_as(:article).id and t.tenant_id == ^tenant_id and
                  t.dim == ^target_dim,
              select: 1
            )
          ),
        limit: ^limit,
        select: a
      )
    )
  end

  defp embed_batch(tenant_id, target_dim, articles) do
    entries = Enum.map(articles, fn a -> {a, embedding_text(a)} end)
    texts = Enum.map(entries, fn {_a, text} -> text end)

    case Knowledge.generate_embeddings(tenant_id, texts) do
      {:ok, vectors} when length(vectors) == length(entries) ->
        store_all(tenant_id, target_dim, Enum.zip(entries, vectors))

      {:ok, _mismatch} ->
        {:error, :embedding_batch_length_mismatch}

      {:error, reason} ->
        handle_error(tenant_id, reason)
    end
  end

  defp store_all(tenant_id, target_dim, pairs) do
    result =
      Enum.reduce_while(pairs, :ok, fn {{article, text}, vector}, :ok ->
        # The side table ONLY: the legacy column is vector(1536) and the target
        # dimension is by definition not the active one, so a dual-write here is
        # either physically impossible (non-1536) or would clobber the still-serving
        # active corpus. AC-41.1.8's dual-write is dim-1536-scoped for this reason.
        case Embeddings.upsert_article_embedding(
               tenant_id,
               article,
               vector,
               content_hash(text),
               target_dim
             ) do
          {:ok, _row} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with :ok <- result do
      progress = Embeddings.reembed_progress(tenant_id, target_dim)
      emit_progress(tenant_id, progress)
      continue(tenant_id, target_dim)
    end
  end

  defp continue(tenant_id, target_dim) do
    %{tenant_id: tenant_id, target_dim: target_dim}
    |> __MODULE__.new(schedule_in: 1)
    |> Oban.insert()

    :ok
  end

  # COMPLETION, in the only safe order: flip the tenant's active dimension FIRST
  # (the whole corpus is now present at the target), then drop the stale-dimension
  # rows. Between the two, recall is already correct at the new dimension and the
  # old rows are merely unused — the reverse order would leave a window with no
  # corpus at either dimension.
  defp finish(tenant_id, target_dim) do
    with {:ok, _tenant} <- Embeddings.set_tenant_dimension(tenant_id, target_dim) do
      {:ok, dropped} = Embeddings.drop_stale_dimensions(tenant_id, target_dim)

      emit_progress(tenant_id, %{
        Embeddings.reembed_progress(tenant_id, target_dim)
        | complete: true
      })

      Logger.info(
        "ReembedWorker: tenant=#{tenant_id} completed re-embed onto #{target_dim} dims; " <>
          "dropped #{dropped} stale-dimension row(s)."
      )

      :ok
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

  defp embedding_text(article) do
    String.slice("#{article.title}\n\n#{article.body}", 0, @max_text_length)
  end

  defp content_hash(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
end
