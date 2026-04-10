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
  4. Call `@extractor.extract_articles/1` via compile-time DI
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

  @extractor Application.compile_env(
               :loopctl,
               :knowledge_extractor,
               Loopctl.Knowledge.LlmExtractor
             )

  @max_articles 5
  @max_body_length 100_000
  @valid_categories ~w(pattern convention decision finding reference)a
  @tag_pattern ~r/^[a-zA-Z0-9_-]+$/
  @max_tags 20
  @max_tag_length 100

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"review_record_id" => review_record_id, "tenant_id" => tenant_id}
      }) do
    if already_extracted?(tenant_id, review_record_id) do
      Logger.info(
        "ReviewKnowledgeWorker: skipping duplicate extraction " <>
          "(review_record_id=#{review_record_id})"
      )

      :ok
    else
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
    with {:ok, review_record} <- load_review_record(tenant_id, review_record_id),
         context <- build_context(review_record, tenant_id),
         {:ok, raw_articles} <- @extractor.extract_articles(context) do
      articles = validate_and_filter(raw_articles)
      insert_articles(tenant_id, review_record_id, articles)
    end
  end

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
    is_binary(title) and title != ""
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
