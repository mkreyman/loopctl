defmodule Loopctl.Corpus do
  @moduledoc """
  Context for the CORPUS TIER (Epic 43) — the index loopctl hosts for reference
  documents whose physical files stay in the client's own repo.

  It sits BESIDE the Knowledge Wiki with a different contract: verbatim chunks
  rather than distilled articles, a pointer plus a snippet rather than a body, and
  truth that lives in the file on the agent's disk rather than in loopctl. Because
  the chunks live in their OWN tables, they are excluded from `/api/v1/recall`,
  `knowledge_heat_index`, novelty scoring and the consolidation pass BY
  CONSTRUCTION — every one of those paths queries `Loopctl.Knowledge.Article`.
  There is no exclusion flag to set and nothing a later change can forget;
  `test/loopctl/corpus_isolation_guard_test.exs` asserts the property.

  ## The corpus pins its own dimension

  `dim` and `embedding_model` belong to the CORPUS, not the tenant, and are
  immutable after creation. The per-tenant resolvers in `Loopctl.Embeddings` are
  NOT consulted here and must never be: one of them returns the tenant's ARTICLE
  dimension (1536 for a 768 corpus), and the write-resolving one PINS
  `tenants.tenant_embedding_dimension` as a side effect, so a single corpus write
  by a tenant that had not yet embedded an article would pin that tenant's article
  corpus to the local document model. The dimension a chunk vector is written at is
  read from the corpus row and from nowhere else, and
  `test/loopctl/corpus_isolation_guard_test.exs` asserts that too.

  ## Repos and isolation

  Every public function takes `tenant_id` as its FIRST argument and `tenant_id` is
  never cast — it is set programmatically on the struct.

  OLTP writes and reads go through `Loopctl.AdminRepo` with an EXPLICIT `tenant_id`
  predicate on every query, mirroring `Loopctl.Memory` and `Loopctl.Knowledge`.
  `AdminRepo` connects with a BYPASSRLS role, so the RLS policies on the three
  tables do NOT engage on any path in this context: the explicit predicate is the
  only isolation here, not a second layer behind RLS. The policies exist for a
  hypothetical `Loopctl.Repo` caller and are what the isolation test exercises.

  Vector and analytical reads arrive in US-43.2 and go through `Loopctl.HeavyRead`
  (never `HeavyReadRepo` directly). Its structural guard requires a conjunctive
  `x.tenant_id == ^tenant_id` on the `from` source AND on every joined source — a
  `document_chunks` join to `document_chunk_embeddings` satisfies that because both
  tables carry `tenant_id`.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Corpus.Corpus
  alias Loopctl.Corpus.DocumentChunk

  @default_list_limit 50
  @max_list_limit 200

  @doc """
  Creates a corpus for `tenant_id`.

  `tenant_id` is set on the struct, never cast. `dim` must be a published
  supported dimension (AC-43.1.4) and, together with `embedding_model` and `mode`,
  is pinned here and immutable thereafter.
  """
  @spec create_corpus(Ecto.UUID.t(), map()) ::
          {:ok, Corpus.t()} | {:error, Ecto.Changeset.t()}
  def create_corpus(tenant_id, attrs) when is_binary(tenant_id) do
    %Corpus{tenant_id: tenant_id}
    |> Corpus.create_changeset(attrs)
    |> AdminRepo.insert()
  end

  @doc """
  Fetches one corpus of `tenant_id` by id, or — when `id_or_slug` is not a UUID —
  by its `(tenant_id, slug)` unique key.
  """
  @spec get_corpus(Ecto.UUID.t(), String.t()) :: {:ok, Corpus.t()} | {:error, :not_found}
  def get_corpus(tenant_id, id_or_slug) when is_binary(tenant_id) and is_binary(id_or_slug) do
    query =
      case Ecto.UUID.cast(id_or_slug) do
        {:ok, id} -> from(c in Corpus, where: c.tenant_id == ^tenant_id and c.id == ^id)
        :error -> from(c in Corpus, where: c.tenant_id == ^tenant_id and c.slug == ^id_or_slug)
      end

    case AdminRepo.one(query) do
      nil -> {:error, :not_found}
      corpus -> {:ok, corpus}
    end
  end

  @doc """
  Lists `tenant_id`'s corpora, newest first.

  Options: `:project_id` (restrict to one project scope), `:limit` (clamped to
  #{@max_list_limit}), `:offset`.
  """
  @spec list_corpora(Ecto.UUID.t(), keyword()) :: [Corpus.t()]
  def list_corpora(tenant_id, opts \\ []) when is_binary(tenant_id) do
    limit = opts |> Keyword.get(:limit, @default_list_limit) |> clamp_limit()

    Corpus
    |> where([c], c.tenant_id == ^tenant_id)
    |> maybe_filter_project(Keyword.get(opts, :project_id))
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(^limit)
    |> offset(^Keyword.get(opts, :offset, 0))
    |> AdminRepo.all()
  end

  @doc """
  Deletes a corpus of `tenant_id`.

  The chunks and their vectors go with it via `ON DELETE CASCADE` declared in the
  DDL (AC-43.1.9) — this function issues ONE statement and no application-level
  child cleanup, so no path can leave orphans behind.
  """
  @spec delete_corpus(Ecto.UUID.t(), String.t()) ::
          {:ok, Corpus.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_corpus(tenant_id, id_or_slug) when is_binary(tenant_id) do
    with {:ok, corpus} <- get_corpus(tenant_id, id_or_slug) do
      AdminRepo.delete(corpus)
    end
  end

  @doc """
  Inserts or replaces `chunks` in `corpus_id`, keyed on
  `(corpus_id, source_ref, locator)`.

  That key — WITHOUT `content_hash` — is what makes re-indexing idempotent: a chunk
  whose text moved REPLACES the row at its locator instead of adding a second one.
  `locator` is stored verbatim and never normalised.

  Each chunk is validated through `DocumentChunk.changeset/2` before anything is
  written, so a malformed chunk fails the whole batch rather than leaving a partial
  index behind. Two chunks sharing one `(source_ref, locator)` within a single
  batch are refused (`{:error, {:duplicate_chunk_key, key}}`): Postgres cannot
  affect the same row twice in one `ON CONFLICT DO UPDATE`, and silently keeping
  the last one would hide a client-side chunking bug.
  """
  @spec upsert_chunks(Ecto.UUID.t(), String.t(), [map()]) ::
          {:ok, [DocumentChunk.t()]}
          | {:error, :not_found | {:invalid_chunk, non_neg_integer(), Ecto.Changeset.t()}}
          | {:error, {:duplicate_chunk_key, {String.t(), map()}}}
  def upsert_chunks(tenant_id, corpus_id, chunks)
      when is_binary(tenant_id) and is_list(chunks) do
    with {:ok, corpus} <- get_corpus(tenant_id, corpus_id),
         {:ok, rows} <- build_chunk_rows(tenant_id, corpus, chunks),
         :ok <- refute_duplicate_keys(rows) do
      {_count, inserted} =
        AdminRepo.insert_all(DocumentChunk, rows,
          on_conflict: {:replace, [:text, :snippet, :content_hash, :ordinal, :updated_at]},
          conflict_target: [:corpus_id, :source_ref, :locator],
          returning: true
        )

      {:ok, inserted}
    end
  end

  @doc """
  Deletes every chunk of `source_ref` in `corpus_id`, returning how many rows went.

  The chunk vectors follow via `ON DELETE CASCADE`. Scoped to ONE `source_ref` of
  ONE corpus of ONE tenant: this is the narrow verb US-43.2's re-index prune needs,
  not a set-based delete.
  """
  @spec delete_chunks_for_source(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def delete_chunks_for_source(tenant_id, corpus_id, source_ref)
      when is_binary(tenant_id) and is_binary(source_ref) do
    with {:ok, corpus} <- get_corpus(tenant_id, corpus_id) do
      {count, _} =
        DocumentChunk
        |> where(
          [c],
          c.tenant_id == ^tenant_id and c.corpus_id == ^corpus.id and
            c.source_ref == ^source_ref
        )
        |> AdminRepo.delete_all()

      {:ok, count}
    end
  end

  # --- internals ---

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, project_id),
    do: where(query, [c], c.project_id == ^project_id)

  defp clamp_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @max_list_limit)

  defp clamp_limit(_), do: @default_list_limit

  # Validated through the changeset (so `locator`'s default and the required fields
  # are enforced once, in one place), then flattened to `insert_all` rows: one
  # statement per batch rather than one transaction per chunk.
  defp build_chunk_rows(tenant_id, %Corpus{} = corpus, chunks) do
    now = DateTime.utc_now()

    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, acc} ->
      changeset =
        DocumentChunk.changeset(
          %DocumentChunk{tenant_id: tenant_id},
          Map.put(stringify_keys(attrs), "corpus_id", corpus.id)
        )

      if changeset.valid? do
        {:cont, {:ok, [chunk_row(changeset, tenant_id, now) | acc]}}
      else
        {:halt, {:error, {:invalid_chunk, index, changeset}}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp chunk_row(changeset, tenant_id, now) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> Map.take([:corpus_id, :source_ref, :locator, :text, :snippet, :content_hash, :ordinal])
    |> Map.merge(%{
      id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      inserted_at: now,
      updated_at: now
    })
    |> Map.to_list()
  end

  defp refute_duplicate_keys(rows) do
    keys = Enum.map(rows, &{Keyword.fetch!(&1, :source_ref), Keyword.fetch!(&1, :locator)})

    case keys -- Enum.uniq(keys) do
      [] -> :ok
      [duplicate | _] -> {:error, {:duplicate_chunk_key, duplicate}}
    end
  end

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
