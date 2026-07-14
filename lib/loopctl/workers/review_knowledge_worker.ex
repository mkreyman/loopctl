defmodule Loopctl.Workers.ReviewKnowledgeWorker do
  @moduledoc """
  Oban worker that extracts knowledge articles from review findings.

  Runs in the `:knowledge` queue with concurrency 5. When a review
  record is created (via `Progress.record_review/4`), this worker is
  enqueued atomically in the same transaction to extract reusable
  knowledge articles from the review context.

  ## Flow

  1. Check for duplicate extraction (source_type + source_id)
  2. Load the review record by `review_record_id` + `tenant_id`
  3. Build context map from the review record
  4. Call `@extractor.extract_articles/2` (tenant_id + context) via compile-time DI,
     using the tenant's BYO Anthropic key (Epic 28, #179)
  5. Validate extractor output (max 5 articles, body max 100KB, etc.)
  6. Insert valid articles in one Ecto.Multi with source_type: "review_finding"
  7. Log audit event "knowledge.articles_extracted"

  ## Retry Strategy

  Uses a custom polynomial backoff: `attempt^4 + 15 + rand(0..30*attempt)`.
  With `max_attempts: 3`, approximate delays are ~16s, ~31s.

  ## Uniqueness

  Unique per `review_record_id` within a 300-second window.
  """

  use Oban.Worker,
    queue: :knowledge,
    max_attempts: 3,
    unique: [period: 300, keys: [:review_record_id]]

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Artifacts.ReviewRecord
  alias Loopctl.Audit
  alias Loopctl.Knowledge.Article
  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError
  alias Loopctl.Oban.FairShare
  alias Loopctl.Provider.Admission

  @extractor Application.compile_env(
               :loopctl,
               :knowledge_extractor,
               Loopctl.Knowledge.LlmExtractor
             )

  @max_articles 5
  @max_body_length 100_000
  # Single source of truth: the canonical taxonomy (avoids drift).
  @valid_categories Loopctl.Knowledge.Categories.all()
  @tag_pattern ~r/^[a-zA-Z0-9_-]+$/
  # Single source of truth: the Article schema's tag cap (avoids drift).
  @max_tags Loopctl.Knowledge.Article.max_tags()
  @max_tag_length 100

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: id,
        args: %{"review_record_id" => review_record_id, "tenant_id" => tenant_id}
      }) do
    # US-36.2: fair-share gate on the shared :knowledge queue. Yield loss-free
    # ({:snooze, n}, no attempt consumed) when this tenant is at/above its fair share
    # of executing slots, before any (billed) extraction work.
    # `id` excludes THIS (already-executing) job from its own count — see FairShare.
    case FairShare.gate(tenant_id, :knowledge, id) do
      {:snooze, _n} = snooze -> snooze
      :ok -> extract_review_knowledge(tenant_id, review_record_id)
    end
  end

  defp extract_review_knowledge(tenant_id, review_record_id) do
    cond do
      already_extracted?(tenant_id, review_record_id) ->
        Logger.info(
          "ReviewKnowledgeWorker: skipping duplicate extraction " <>
            "(review_record_id=#{review_record_id})"
        )

        :ok

      # Mandatory BYO (Epic 28, #179): review-knowledge extraction runs on the
      # tenant's OWN Anthropic key. Without one, {:discard} cleanly (no crash, no
      # retry loop, no operator-billed spend) rather than falling back to a global
      # key. Defense in depth — the extractor also returns {:error, :no_api_key}.
      not Llm.has_api_key?(tenant_id) ->
        Llm.record_blocked(tenant_id, :extraction)
        {:discard, {:no_api_key, "tenant has no Anthropic API key configured (BYO required)"}}

      true ->
        extract_from_review(tenant_id, review_record_id)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  # --- Private ---

  defp already_extracted?(tenant_id, review_record_id) do
    import Ecto.Query

    AdminRepo.exists?(
      from(a in Article,
        where:
          a.source_type == "review_finding" and
            a.source_id == ^review_record_id and
            a.tenant_id == ^tenant_id
      )
    )
  end

  defp extract_from_review(tenant_id, review_record_id) do
    result =
      with {:ok, review_record} <- load_review_record(tenant_id, review_record_id),
           context <- build_context(review_record, tenant_id),
           {:ok, raw_articles} <- extract(tenant_id, context) do
        articles = validate_and_filter(raw_articles)
        insert_articles(tenant_id, review_record_id, articles)
      end

    # PERMANENT failures (non-408/429 4xx from a bad extraction_model, a
    # title-collision insert) must NOT retry 3x — each retry burns the TENANT's
    # paid Anthropic call (review #3). Mirror ContentIngestionWorker.permanent_error?/1.
    classify_result(result)
  end

  defp classify_result({:error, :rate_limited_local}) do
    # US-37.1 (AC-37.1.4): node-local provider admission backpressure is loss-free —
    # snooze (no Oban attempt consumed, never a discard) rather than burning a retry
    # against the TENANT's paid Anthropic call under sustained provider backpressure.
    {:snooze, Admission.snooze_seconds()}
  end

  defp classify_result({:error, reason}) do
    # Classify on the RAW reason (needs status), but SANITIZE what becomes the Oban
    # reason (review #5): a provider api_error body can echo a masked key fragment,
    # and both {:discard,_}/{:error,_} reasons are persisted into oban_jobs.errors.
    sanitized = ProviderError.sanitize(reason)
    if permanent_error?(reason), do: {:discard, sanitized}, else: {:error, sanitized}
  end

  defp classify_result(other), do: other

  # Backstop for a key removed between the perform/1 gate and here: map
  # {:error, :no_api_key} to a clean {:discard} rather than an infinite retry.
  defp extract(tenant_id, context) do
    case @extractor.extract_articles(tenant_id, context) do
      {:error, :no_api_key} ->
        {:discard, {:no_api_key, "tenant has no Anthropic API key configured (BYO required)"}}

      other ->
        other
    end
  end

  # A permanent failure a retry can't fix (mirrors ContentIngestionWorker):
  #   * a 4xx api_error other than 408 (timeout) / 429 (rate limited);
  #   * an insert that failed on a changeset (e.g. the active-title unique index
  #     `articles_tenant_title_active_idx` — review findings recur, so title
  #     collisions with an existing article are plausible and deterministic); or
  #   * an insert that raised a constraint Postgrex.Error.
  # Everything else (5xx / request_failed / json_parse_error / serialization) is transient.
  defp permanent_error?({:api_error, status, _body})
       when is_integer(status) and status >= 400 and status < 500 and status != 408 and
              status != 429,
       do: true

  defp permanent_error?({:insert_failed, _step, %Ecto.Changeset{}}), do: true

  defp permanent_error?({:insert_failed, _step, %Postgrex.Error{} = error}),
    do: constraint_violation?(error)

  defp permanent_error?(_), do: false

  @constraint_violation_codes ~w(
    unique_violation check_violation not_null_violation
    foreign_key_violation exclusion_violation
  )a
  defp constraint_violation?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in @constraint_violation_codes

  defp constraint_violation?(_), do: false

  defp load_review_record(tenant_id, review_record_id) do
    case AdminRepo.get_by(ReviewRecord, id: review_record_id, tenant_id: tenant_id) do
      nil ->
        Logger.warning(
          "ReviewKnowledgeWorker: review record not found " <>
            "(review_record_id=#{review_record_id})"
        )

        :ok

      record ->
        {:ok, record}
    end
  end

  defp build_context(review_record, tenant_id) do
    %{
      review_record_id: review_record.id,
      tenant_id: tenant_id,
      story_id: review_record.story_id,
      review_type: review_record.review_type,
      findings_count: review_record.findings_count,
      fixes_count: review_record.fixes_count,
      summary: review_record.summary
    }
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

  defp insert_articles(_tenant_id, _review_record_id, []) do
    :ok
  end

  defp insert_articles(tenant_id, review_record_id, articles) do
    multi =
      articles
      |> Enum.with_index()
      |> Enum.reduce(Multi.new(), fn {attrs, index}, multi ->
        attrs = normalize_attrs(attrs)

        changeset =
          %Article{
            tenant_id: tenant_id,
            source_type: "review_finding",
            source_id: review_record_id
          }
          |> Article.create_changeset(attrs)

        Multi.insert(multi, {:article, index}, changeset)
      end)
      |> Audit.log_in_multi(:audit, fn changes ->
        article_ids =
          changes
          |> Enum.filter(fn {key, _} -> match?({:article, _}, key) end)
          |> Enum.map(fn {_, article} -> article.id end)

        %{
          tenant_id: tenant_id,
          entity_type: "article",
          entity_id: review_record_id,
          action: "knowledge.articles_extracted",
          actor_type: "system",
          actor_id: nil,
          actor_label: "worker:review_knowledge",
          new_state: %{
            "review_record_id" => review_record_id,
            "article_count" => length(article_ids),
            "article_ids" => article_ids
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, _changes} ->
        Logger.info(
          "ReviewKnowledgeWorker: extracted #{length(articles)} articles " <>
            "(review_record_id=#{review_record_id})"
        )

        :ok

      {:error, step, changeset, _completed} ->
        Logger.warning(
          "ReviewKnowledgeWorker: insert failed at step #{inspect(step)} " <>
            "(review_record_id=#{review_record_id}): #{inspect(changeset)}"
        )

        {:error, {:insert_failed, step, changeset}}
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    # Ensure atom keys for changeset compatibility
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
end
