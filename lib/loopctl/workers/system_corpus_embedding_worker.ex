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

  use Oban.Worker,
    queue: :embeddings,
    max_attempts: 5,
    unique: [keys: [:tenant_id, :dim], period: 300],
    replace: [scheduled: [:args, :scheduled_at]]

  require Logger

  import Loopctl.Egress, only: [is_egress_refusal: 1]

  alias Loopctl.Egress
  alias Loopctl.Embeddings
  alias Loopctl.Knowledge
  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Provider.Admission
  alias Loopctl.Provider.RetryAfter

  @max_text_length 32_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenant_id" => tenant_id} = args}) when is_binary(tenant_id) do
    # AC-41.1.11: the dimension is resolved ONCE for the whole batch and threaded
    # into every changeset — never re-read per article.
    dim = args["dim"] || Embeddings.active_dimension(tenant_id)

    case Embeddings.unmaterialized_system_articles(tenant_id, dim, limit: batch_size()) do
      [] -> :ok
      articles -> materialize(tenant_id, dim, articles)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  defp materialize(tenant_id, dim, articles) do
    entries = Enum.map(articles, fn a -> {a, embedding_text(a)} end)
    texts = Enum.map(entries, fn {_a, text} -> text end)

    case Knowledge.generate_embeddings(tenant_id, texts) do
      {:ok, vectors} when length(vectors) == length(entries) ->
        store_all(tenant_id, dim, Enum.zip(entries, vectors))

      {:ok, _mismatch} ->
        {:error, :embedding_batch_length_mismatch}

      {:error, reason} ->
        handle_error(tenant_id, reason)
    end
  end

  # Vectors are written only after the WHOLE array call succeeded, so a provider
  # failure means zero writes and the batch retries as a unit.
  defp store_all(tenant_id, dim, pairs) do
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

  # Self-continuation: more unmaterialized rows means another batch. The unique
  # window would swallow an immediate duplicate, so the follow-up is scheduled just
  # past nothing — `replace: [scheduled: ...]` makes a racing enqueue idempotent.
  defp continue(tenant_id, dim) do
    if Embeddings.unmaterialized_system_articles(tenant_id, dim, limit: 1) == [] do
      :ok
    else
      %{tenant_id: tenant_id, dim: dim}
      |> __MODULE__.new(schedule_in: 1)
      |> Oban.insert()

      :ok
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

  defp embedding_text(article) do
    String.slice("#{article.title}\n\n#{article.body}", 0, @max_text_length)
  end

  defp content_hash(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
end
