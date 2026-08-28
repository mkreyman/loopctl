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
  alias Loopctl.Projects

  @default_list_limit 50
  @max_list_limit 200

  @doc """
  Creates a corpus for `tenant_id`.

  `tenant_id` is set on the struct, never cast. `dim` must be a published
  supported dimension (AC-43.1.4) and, together with `embedding_model` and `mode`,
  is pinned here and immutable thereafter.

  A `project_id` is validated for tenant OWNERSHIP here, before the write — the
  schema's `foreign_key_constraint(:project_id)` is an existence check and never
  the tenant boundary.
  """
  @spec create_corpus(Ecto.UUID.t(), map()) ::
          {:ok, Corpus.t()} | {:error, Ecto.Changeset.t()}
  def create_corpus(tenant_id, attrs) when is_binary(tenant_id) do
    %Corpus{tenant_id: tenant_id}
    |> Corpus.create_changeset(attrs)
    |> validate_project_ownership(tenant_id)
    |> AdminRepo.insert()
  end

  @doc """
  Fetches one corpus of `tenant_id` by id, falling back to its `(tenant_id, slug)`
  unique key when the id lookup misses.

  The fallback is what makes the contract true for every slug the create changeset
  accepts: `Ecto.UUID.cast/1` parses a canonical lowercase UUID (all of whose
  characters the slug format validator allows) AND any 16-BYTE string as a raw
  UUID, so an id-only resolver made such a corpus creatable and then permanently
  unreachable by slug — including through `delete_corpus/2`, `upsert_chunks/3` and
  `delete_chunks_for_source/3`, which all resolve here. The second query is paid
  only when the id branch was attempted and missed.
  """
  @spec get_corpus(Ecto.UUID.t(), String.t()) :: {:ok, Corpus.t()} | {:error, :not_found}
  def get_corpus(tenant_id, id_or_slug) when is_binary(tenant_id) and is_binary(id_or_slug) do
    with :error <- fetch_corpus_by_id(tenant_id, id_or_slug),
         :error <- fetch_corpus_by_slug(tenant_id, id_or_slug) do
      {:error, :not_found}
    end
  end

  @doc """
  Lists `tenant_id`'s corpora, newest first.

  Options: `:project_id` (restrict to one project scope), `:limit` (clamped to
  #{@max_list_limit}), `:offset` (floored at 0 — Postgres refuses a negative
  OFFSET, and this function sanitises BOTH pagination opts or neither).
  """
  @spec list_corpora(Ecto.UUID.t(), keyword()) :: [Corpus.t()]
  def list_corpora(tenant_id, opts \\ []) when is_binary(tenant_id) do
    limit = opts |> Keyword.get(:limit, @default_list_limit) |> clamp_limit()

    offset = opts |> Keyword.get(:offset, 0) |> clamp_offset()

    Corpus
    |> where([c], c.tenant_id == ^tenant_id)
    |> maybe_filter_project(Keyword.get(opts, :project_id))
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(^limit)
    |> offset(^offset)
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
  the last one would hide a client-side chunking bug. "Sharing" is judged as
  POSTGRES will judge it — `%{page: 1}`, `%{"page" => 1}` and `%{"page" => 1.0}`
  are one jsonb key and one row — so the refusal covers every pair the index does.
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

  # `project_id` IS cast from caller input, and the insert runs on the BYPASSRLS
  # `AdminRepo`, so the schema's `foreign_key_constraint(:project_id)` is evaluated
  # against `projects` in EVERY tenant: it is an EXISTENCE check, never the tenant
  # boundary. Validating ownership here makes a foreign project and a nonexistent
  # one take the SAME error path, so the FK cannot serve as a cross-tenant
  # existence oracle, and no cross-tenant edge is persisted — which would also let
  # the OTHER tenant deleting its project mutate this row through the DDL's
  # `ON DELETE SET NULL`. `nil` (tenant-wide) is always allowed. Mirrors
  # `Loopctl.Knowledge.validate_project_ownership/2` and
  # `Loopctl.Memory.validate_project_scope/1`; `Projects.get_project/2` carries the
  # UUID guard, so a malformed value is a changeset error, never a CastError 500.
  defp validate_project_ownership(changeset, tenant_id) do
    case Ecto.Changeset.get_field(changeset, :project_id) do
      nil ->
        changeset

      project_id ->
        case Projects.get_project(tenant_id, project_id) do
          {:ok, _project} ->
            changeset

          {:error, :not_found} ->
            Ecto.Changeset.add_error(
              changeset,
              :project_id,
              "is invalid or does not belong to this tenant"
            )
        end
    end
  end

  defp fetch_corpus_by_id(tenant_id, id_or_slug) do
    case Ecto.UUID.cast(id_or_slug) do
      {:ok, id} ->
        fetch_corpus(from(c in Corpus, where: c.tenant_id == ^tenant_id and c.id == ^id))

      :error ->
        :error
    end
  end

  defp fetch_corpus_by_slug(tenant_id, slug) do
    fetch_corpus(from(c in Corpus, where: c.tenant_id == ^tenant_id and c.slug == ^slug))
  end

  defp fetch_corpus(query) do
    case AdminRepo.one(query) do
      nil -> :error
      corpus -> {:ok, corpus}
    end
  end

  defp maybe_filter_project(query, nil), do: query

  defp maybe_filter_project(query, project_id),
    do: where(query, [c], c.project_id == ^project_id)

  defp clamp_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @max_list_limit)

  defp clamp_limit(_), do: @default_list_limit

  defp clamp_offset(offset) when is_integer(offset) and offset > 0, do: offset
  defp clamp_offset(_), do: 0

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

  # Compared on the form POSTGRES will compare, not on the Elixir term: the
  # uniqueness this guards is a btree over a jsonb `locator`, so two locators that
  # are distinct maps but equal as jsonb reach one row twice and Postgres raises
  # `cardinality_violation` ("ON CONFLICT DO UPDATE command cannot affect row a
  # second time") — an unmatched raise where the @spec promises
  # `{:error, {:duplicate_chunk_key, key}}`. Two classes get past a term
  # comparison: atom vs string keys (`stringify_keys/1` normalises the TOP-LEVEL
  # attrs only, and it must — the STORED locator is never normalised), and jsonb's
  # numeric equality, where `1` and `1.0` are the same key but different terms.
  # The canonical form is used for the COMPARISON only; the reported key and the
  # stored value stay verbatim.
  defp refute_duplicate_keys(rows) do
    rows
    |> Enum.reduce_while(MapSet.new(), fn row, seen ->
      source_ref = Keyword.fetch!(row, :source_ref)
      locator = Keyword.fetch!(row, :locator)
      key = {source_ref, canonical_locator(locator)}

      if MapSet.member?(seen, key) do
        {:halt, {:error, {:duplicate_chunk_key, {source_ref, locator}}}}
      else
        {:cont, MapSet.put(seen, key)}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _seen -> :ok
    end
  end

  # jsonb sorts object keys, renders every key as a string, and compares numbers
  # numerically (`1 = 1.0`). A sorted list of stringified-key pairs with integral
  # floats folded to integers reproduces that equality without touching the value
  # that gets stored.
  defp canonical_locator(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {key, inner} -> {to_string(key), canonical_locator(inner)} end)
    |> Enum.sort()
  end

  defp canonical_locator(value) when is_list(value), do: Enum.map(value, &canonical_locator/1)

  defp canonical_locator(value) when is_float(value) do
    if value == trunc(value), do: trunc(value), else: value
  end

  defp canonical_locator(value), do: value

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
