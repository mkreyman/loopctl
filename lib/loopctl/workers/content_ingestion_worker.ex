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

  use Oban.Worker,
    queue: :knowledge,
    max_attempts: 3,
    unique: [keys: [:content_hash, :tenant_id], period: 3600]

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ContentChunker

  @content_extractor Application.compile_env(
                       :loopctl,
                       :content_extractor,
                       Loopctl.Knowledge.ClaudeContentExtractor
                     )

  @max_articles 10
  @max_body_length 100_000
  @valid_categories ~w(pattern convention decision finding reference)a
  @tag_pattern ~r/^[a-zA-Z0-9_-]+$/
  @max_tags 20
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
    project_id = args["project_id"]

    # Generate a deterministic source_id from the content_hash.
    # source_id must be a UUID (:binary_id), so we derive one from the hash.
    source_id = derive_source_id(content_hash)

    with {:ok, content} <- resolve_content(url, raw_content),
         {:ok, raw_articles} <- extract_with_chunking(content, source_type) do
      articles = validate_and_filter(raw_articles)
      insert_articles(tenant_id, source_id, source_type, project_id, articles, url)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  # --- Private ---

  defp extract_with_chunking(content, source_type) do
    chunks = ContentChunker.chunk(content)

    if length(chunks) > 1 do
      Logger.info(
        "ContentIngestionWorker: splitting #{byte_size(content)} bytes into #{length(chunks)} chunks"
      )
    end

    {articles, errors} =
      Enum.reduce(chunks, {[], []}, fn chunk, {arts, errs} ->
        case @content_extractor.extract_from_content(chunk, source_type: source_type) do
          {:ok, extracted} -> {arts ++ extracted, errs}
          {:error, reason} -> {arts, [reason | errs]}
        end
      end)

    cond do
      articles != [] ->
        # Got some articles — partial success is fine, log errors
        if errors != [] do
          Logger.warning(
            "ContentIngestionWorker: #{length(errors)} of #{length(chunks)} chunks failed"
          )
        end

        {:ok, Enum.take(articles, @max_articles)}

      errors != [] ->
        # All chunks failed — propagate the first error so Oban retries
        {:error, List.first(errors)}

      true ->
        # No chunks produced anything but no errors either (empty content)
        {:ok, []}
    end
  end

  defp resolve_content(nil, content) when is_binary(content) and content != "" do
    {:ok, content}
  end

  defp resolve_content(url, _content) when is_binary(url) do
    req_opts =
      [url: url, receive_timeout: 15_000, retry: :transient, max_retries: 1]
      |> maybe_add_plug()

    case Req.get(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, strip_html(body)}

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

  defp resolve_content(nil, _), do: {:error, :no_content}

  defp derive_source_id(content_hash) do
    # Derive a deterministic UUID from the content hash.
    # Hash the content_hash with SHA256 to ensure we always have 32 bytes,
    # then format the first 16 bytes as a UUID string.
    <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
      e::binary-size(6),
      _rest::binary>> =
      :crypto.hash(:sha256, content_hash)

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

  defp insert_articles(_tenant_id, _job_id, _source_type, _project_id, [], _url) do
    :ok
  end

  defp insert_articles(tenant_id, job_id, source_type, project_id, articles, url) do
    multi =
      articles
      |> Enum.with_index()
      |> Enum.reduce(Multi.new(), fn {attrs, index}, multi ->
        attrs = normalize_attrs(attrs)

        article = %Article{
          tenant_id: tenant_id,
          source_type: source_type,
          source_id: job_id
        }

        article =
          if project_id do
            %{article | project_id: project_id}
          else
            article
          end

        changeset = Article.create_changeset(article, attrs)

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
          entity_id: job_id,
          action: "knowledge.content_ingested",
          actor_type: "system",
          actor_id: nil,
          actor_label: "worker:content_ingestion",
          new_state: %{
            "source_type" => source_type,
            "url" => url,
            "article_count" => length(article_ids),
            "article_ids" => article_ids
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, _changes} ->
        Logger.info(
          "ContentIngestionWorker: extracted #{length(articles)} articles " <>
            "(source_type=#{source_type}, url=#{url || "inline"})"
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
end
