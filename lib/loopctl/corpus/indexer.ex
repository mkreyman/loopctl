defmodule Loopctl.Corpus.Indexer do
  @moduledoc """
  US-43.2 — the MODE A ingest path: `POST /api/v1/corpora/:id/index`.

  The client sends verbatim chunks; loopctl computes each chunk's `content_hash`
  server-side, embeds only what actually moved, and writes every chunk and its
  vector in ONE `Ecto.Multi`, committed once.

  ## One transaction, per-item step names

  This follows `Loopctl.Embeddings.upsert_article_embeddings/3`. Its per-item
  predecessor opened ~100 transactions against the 3-connection admin pool and had
  no atomicity, so a failure at item 60 left 59 rows written while the job re-ran
  and re-billed the provider for all 100 texts. Convergence on failure here comes
  from the batch being BOUNDED (`max_batch_size/0`) plus the idempotency below, not
  from partial commits.

  ## Idempotency, and what decides a rewrite

  A chunk row is KEYED by `(corpus_id, source_ref, locator)` — the unique index of
  US-43.1. `content_hash` is an ORDINARY COLUMN, compared against the incoming
  chunk to classify it `unchanged | inserted | replaced`. An unchanged batch writes
  no chunk row, spends no embedding token, and leaves `updated_at` alone.

  ## Pruning is reconciliation, never inference

  A batch is not a document. A large document split across several bounded batches
  would otherwise have batch one delete the chunks batches two and three are about
  to send. So the request NAMES the sources it carries in full
  (`source_complete: [source_ref, ...]`) and only those are reconciled — a source
  whose chunk set shrank has its surplus chunks deleted, so a document that lost a
  page stops serving it.

  A `source_ref` may be named ONLY if the same request carries at least one chunk
  for it. That is what keeps the verb below the `:user` line: no request can prune
  content it does not resend, and re-indexing the file restores what a prune took.

  ## Over-long chunks

  A page of dense EDI tables can exceed the provider's input limit, so the array
  call goes through `Loopctl.Embeddings.ShrinkLadder`, which bisects to isolate the
  offending member and then walks the byte ladder on it alone. A vector the ladder
  had to shrink covers a PREFIX and is not comparable with whole-text vectors, so it
  is marked in the STORED embedding hash via `ShrinkLadder.truncated_hash/1`. The
  CHUNK's own `content_hash` stays the whole-text hash — that is the idempotency
  key's input, and marking it there would make an unchanged chunk look changed on
  every run.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Corpus
  alias Loopctl.Corpus.Corpus, as: CorpusRow
  alias Loopctl.Corpus.DocumentChunk
  alias Loopctl.Corpus.DocumentChunkEmbedding
  alias Loopctl.Embeddings.ShrinkLadder
  alias Loopctl.Knowledge

  # The batch ceiling. ONE attribute, read by the controller's runtime guard AND by
  # its OpenAPI `maxItems`, so a caller can size its batches and the documented bound
  # and the enforced bound cannot drift (AC-43.2.2).
  @max_batch_size 200

  @doc "The maximum number of chunks one index request may carry."
  @spec max_batch_size() :: pos_integer()
  def max_batch_size, do: @max_batch_size

  @type item_report :: %{source_ref: String.t(), locator: term(), status: atom()}

  @type error ::
          :not_found
          | :mode_mismatch
          | :audit_write_failed
          | {:batch_too_large, pos_integer()}
          | {:invalid_chunk, non_neg_integer(), String.t() | Ecto.Changeset.t()}
          | {:duplicate_chunk_key, {String.t(), term()}}
          | {:source_complete_not_carried, [String.t()]}
          | {:embedding_failed, term(), [map()]}
          | {:write_failed, term(), term()}

  @doc """
  Indexes `chunks` into `corpus_id` (an id or a slug) for `tenant_id`.

  Each chunk is `%{source_ref, locator, text, ordinal}` — `content_hash` is NOT
  accepted from the client in mode A; it is computed here from the text.

  `opts`:

    * `:source_complete` — the `source_ref`s this request carries in FULL. Only
      these are reconciled, and each must be carried by the batch.
    * `:audit` — the actor-context keyword list from
      `LoopctlWeb.AuditContext.from_conn/1`.

  Returns `{:ok, %{items: [...], pruned: n, corpus: corpus}}`, where each item
  reports `unchanged | inserted | replaced` for its `(source_ref, locator)`.
  """
  @spec index_chunks(Ecto.UUID.t(), String.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, error()}
  def index_chunks(tenant_id, corpus_id, chunks, opts \\ [])
      when is_binary(tenant_id) and is_list(chunks) do
    with {:ok, corpus} <- Corpus.get_corpus(tenant_id, corpus_id),
         :ok <- validate_mode(corpus),
         :ok <- validate_batch_size(chunks),
         {:ok, items} <- build_items(corpus, chunks),
         :ok <- Corpus.refute_duplicate_keys(Enum.map(items, &{&1.source_ref, &1.locator})),
         {:ok, complete} <- validate_source_complete(items, Keyword.get(opts, :source_complete)),
         {:ok, classified} <- classify(tenant_id, corpus, items),
         {:ok, embedded} <- embed_changed(tenant_id, corpus, classified) do
      commit(tenant_id, corpus, embedded, complete, Keyword.get(opts, :audit, []))
    end
  end

  # --- validation ---

  defp validate_mode(%CorpusRow{mode: :server_embedded}), do: :ok
  defp validate_mode(%CorpusRow{}), do: {:error, :mode_mismatch}

  defp validate_batch_size(chunks) when length(chunks) > @max_batch_size,
    do: {:error, {:batch_too_large, @max_batch_size}}

  defp validate_batch_size([]), do: {:error, {:invalid_chunk, 0, "the batch carries no chunks"}}
  defp validate_batch_size(_chunks), do: :ok

  # Validated through `DocumentChunk.changeset/2` so the locator's default and its
  # ONE refusal (an object whose keys collide once rendered as jsonb) are enforced in
  # the one place that owns them, rather than re-derived here.
  defp build_items(corpus, chunks) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, acc} ->
      case build_item(corpus, attrs, index) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_chunk, index, reason}}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp build_item(corpus, attrs, index) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    cond do
      not present?(Map.get(attrs, "source_ref")) ->
        {:error, "source_ref is required"}

      not present?(Map.get(attrs, "text")) ->
        {:error, "text is required — a server_embedded corpus embeds the text you send"}

      true ->
        changeset_item(corpus, attrs, index)
    end
  end

  defp build_item(_corpus, _attrs, _index), do: {:error, "each chunk must be an object"}

  defp changeset_item(corpus, attrs, index) do
    text = Map.fetch!(attrs, "text")
    hash = content_hash(text)

    changeset =
      DocumentChunk.changeset(
        %DocumentChunk{tenant_id: corpus.tenant_id},
        Map.merge(attrs, %{"corpus_id" => corpus.id, "content_hash" => hash})
      )

    if changeset.valid? do
      chunk = Ecto.Changeset.apply_changes(changeset)

      {:ok,
       %{
         index: index,
         source_ref: chunk.source_ref,
         locator: chunk.locator,
         text: chunk.text,
         snippet: chunk.snippet,
         ordinal: chunk.ordinal,
         content_hash: hash
       }}
    else
      {:error, changeset}
    end
  end

  # AC-43.2.3: a source may be named complete ONLY if this request carries at least
  # one chunk for it. Naming a source the batch does not carry would let one request
  # prune content it never resent — a set-based delete wearing an index request's
  # clothes, and the reason this verb could not otherwise stay at `role: :agent`.
  defp validate_source_complete(_items, nil), do: {:ok, []}
  defp validate_source_complete(_items, []), do: {:ok, []}

  defp validate_source_complete(items, refs) when is_list(refs) do
    carried = MapSet.new(items, & &1.source_ref)
    refs = refs |> Enum.filter(&is_binary/1) |> Enum.uniq()

    case Enum.reject(refs, &MapSet.member?(carried, &1)) do
      [] -> {:ok, refs}
      missing -> {:error, {:source_complete_not_carried, missing}}
    end
  end

  defp validate_source_complete(_items, _refs),
    do: {:error, {:source_complete_not_carried, []}}

  # --- classification ---

  defp classify(tenant_id, corpus, items) do
    existing = load_existing(tenant_id, corpus, Enum.map(items, & &1.source_ref))

    {:ok, Enum.map(items, &classify_item(&1, existing))}
  end

  defp classify_item(item, existing) do
    case Map.get(existing, {item.source_ref, Corpus.canonical_locator(item.locator)}) do
      nil ->
        Map.merge(item, %{status: :inserted, chunk_id: nil})

      %{id: id, content_hash: stored} ->
        status = if stored == item.content_hash, do: :unchanged, else: :replaced
        Map.merge(item, %{status: status, chunk_id: id})
    end
  end

  defp load_existing(tenant_id, corpus, source_refs) do
    refs = Enum.uniq(source_refs)

    from(c in DocumentChunk,
      where: c.tenant_id == ^tenant_id and c.corpus_id == ^corpus.id and c.source_ref in ^refs,
      select: %{
        id: c.id,
        source_ref: c.source_ref,
        locator: c.locator,
        content_hash: c.content_hash
      }
    )
    |> AdminRepo.all()
    |> Map.new(fn row ->
      {{row.source_ref, Corpus.canonical_locator(row.locator)},
       %{id: row.id, content_hash: row.content_hash}}
    end)
  end

  # --- embedding ---

  # ONE provider call for the whole batch (one admission token, one concurrency
  # slot), and vectors map back by the response's `index` field inside the client —
  # never by array position here. A partial response fails the whole batch. Only
  # changed items are sent, so a re-index of an unchanged corpus spends nothing.
  defp embed_changed(tenant_id, corpus, items) do
    targets = Enum.reject(items, &(&1.status == :unchanged))

    if targets == [] do
      {:ok, Enum.map(items, &Map.merge(&1, %{embedding: nil, truncated?: false}))}
    else
      run_embed(tenant_id, corpus, items, targets)
    end
  end

  defp run_embed(tenant_id, corpus, items, targets) do
    texts = Enum.map(targets, & &1.text)

    result =
      ShrinkLadder.embed_batch(
        texts,
        &Knowledge.generate_embeddings(tenant_id, &1, embedding_model: corpus.embedding_model),
        label: "Corpus.Indexer corpus=#{corpus.id}"
      )

    case result do
      {:ok, vectors} -> {:ok, attach(items, targets, vectors, [])}
      {:ok, vectors, truncated} -> {:ok, attach(items, targets, vectors, truncated)}
      {:error, reason, partial} -> {:error, embedding_error(reason, targets, partial)}
      {:error, reason} -> {:error, embedding_error(reason, targets, [])}
    end
  end

  defp attach(items, targets, vectors, truncated) do
    truncated = MapSet.new(truncated)

    by_index =
      targets
      |> Enum.zip(vectors)
      |> Enum.with_index()
      |> Map.new(fn {{target, vector}, position} ->
        {target.index, {vector, MapSet.member?(truncated, position)}}
      end)

    Enum.map(items, fn item ->
      case Map.fetch(by_index, item.index) do
        {:ok, {vector, truncated?}} ->
          Map.merge(item, %{embedding: vector, truncated?: truncated?})

        :error ->
          Map.merge(item, %{embedding: nil, truncated?: false})
      end
    end)
  end

  # Names the ITEMS that could not be embedded. `ShrinkLadder`'s bisect reports the
  # members it DID embed with their ORIGINAL positions, so what it could not reach is
  # the complement. That set always CONTAINS the offender and may be wider than it: a
  # half that fails short-circuits its sibling deliberately (a non-length failure —
  # breaker open, egress refusal — would fail the sibling too), so members it never
  # attempted are named as well. With no partials at all the whole batch is named,
  # because a provider that rejected the array outright named no member and neither
  # may we. Nothing is written either way, so the caller resubmits the whole batch and
  # the idempotency makes the unchanged members free.
  defp embedding_error(reason, targets, partial) do
    embedded = MapSet.new(partial, &elem(&1, 0))

    failed =
      targets
      |> Enum.with_index()
      |> Enum.reject(fn {_target, position} -> MapSet.member?(embedded, position) end)
      |> Enum.map(fn {target, _position} ->
        %{index: target.index, source_ref: target.source_ref, locator: target.locator}
      end)

    {:embedding_failed, reason, failed}
  end

  # --- the one transaction ---

  defp commit(tenant_id, corpus, items, complete, audit) do
    multi =
      items
      |> Enum.reduce(Multi.new(), &add_item(&2, tenant_id, corpus, &1))
      |> add_prunes(tenant_id, corpus, complete, items)
      |> Audit.log_in_multi(:audit, fn _changes ->
        audit_attrs(tenant_id, corpus, items, complete, audit)
      end)

    case AdminRepo.transaction(multi) do
      {:ok, changes} ->
        {:ok,
         %{
           corpus: corpus,
           items: Enum.map(items, &Map.take(&1, [:source_ref, :locator, :status])),
           pruned: pruned_count(changes, complete)
         }}

      # Matching `:audit` explicitly (never `_step`) keeps the compile-time gate: if
      # `Audit.log_in_multi/3` is ever changed to fail with a non-changeset value this
      # clause stops covering it and the build fails here instead of silently
      # mis-mapping an audit failure onto a write failure.
      {:error, :audit, %Ecto.Changeset{}, _changes} ->
        {:error, :audit_write_failed}

      {:error, step, reason, _changes} ->
        {:error, {:write_failed, step, reason}}
    end
  end

  defp add_item(multi, _tenant_id, _corpus, %{status: :unchanged}), do: multi

  defp add_item(multi, tenant_id, corpus, item) do
    multi
    |> Multi.run({:chunk, item.index}, fn repo, _changes ->
      upsert_chunk(repo, tenant_id, corpus, item)
    end)
    |> Multi.run({:embedding, item.index}, fn repo, changes ->
      upsert_embedding(repo, tenant_id, corpus, Map.fetch!(changes, {:chunk, item.index}), item)
    end)
  end

  defp upsert_chunk(repo, tenant_id, corpus, item) do
    %DocumentChunk{tenant_id: tenant_id}
    |> DocumentChunk.changeset(%{
      corpus_id: corpus.id,
      source_ref: item.source_ref,
      locator: item.locator,
      text: item.text,
      snippet: item.snippet,
      ordinal: item.ordinal,
      content_hash: item.content_hash
    })
    |> repo.insert(
      on_conflict: {:replace, [:text, :snippet, :content_hash, :ordinal, :updated_at]},
      conflict_target: [:corpus_id, :source_ref, :locator],
      returning: true
    )
  end

  defp upsert_embedding(repo, tenant_id, corpus, chunk, item) do
    %DocumentChunkEmbedding{tenant_id: tenant_id}
    |> DocumentChunkEmbedding.changeset(
      %{
        document_chunk_id: chunk.id,
        embedding: item.embedding,
        embedding_content_hash: embedding_hash(item)
      },
      corpus.dim
    )
    |> repo.insert(
      on_conflict: {:replace, [:embedding, :embedding_content_hash, :live_denorm, :updated_at]},
      conflict_target: [:tenant_id, :document_chunk_id, :dim],
      returning: true
    )
  end

  defp embedding_hash(%{truncated?: true, content_hash: hash}),
    do: ShrinkLadder.truncated_hash(hash)

  defp embedding_hash(%{content_hash: hash}), do: hash

  # Prune steps are added AFTER every chunk step, so `changes` already carries the
  # ids this request wrote and the kept set is exact. Deleting by id (rather than by
  # "locator NOT IN") is what keeps the comparison out of jsonb entirely.
  defp add_prunes(multi, tenant_id, corpus, complete, items) do
    Enum.reduce(complete, multi, fn source_ref, acc ->
      of_source = Enum.filter(items, &(&1.source_ref == source_ref))
      unchanged = for i <- of_source, i.status == :unchanged, do: i.chunk_id
      written = for i <- of_source, i.status != :unchanged, do: i.index

      Multi.run(acc, {:prune, source_ref}, fn repo, changes ->
        kept = unchanged ++ Enum.map(written, &Map.fetch!(changes, {:chunk, &1}).id)

        {count, _} =
          from(c in DocumentChunk,
            where:
              c.tenant_id == ^tenant_id and c.corpus_id == ^corpus.id and
                c.source_ref == ^source_ref and c.id not in ^kept
          )
          |> repo.delete_all()

        {:ok, count}
      end)
    end)
  end

  defp pruned_count(changes, complete) do
    Enum.reduce(complete, 0, fn source_ref, acc ->
      acc + Map.get(changes, {:prune, source_ref}, 0)
    end)
  end

  defp audit_attrs(tenant_id, corpus, items, complete, audit) do
    counts = Enum.frequencies_by(items, & &1.status)

    %{
      tenant_id: tenant_id,
      project_id: corpus.project_id,
      entity_type: "corpus",
      entity_id: corpus.id,
      action: "corpus_indexed",
      actor_type: Keyword.get(audit, :actor_type, "system"),
      actor_id: Keyword.get(audit, :actor_id),
      actor_label: Keyword.get(audit, :actor_label),
      new_state: %{
        "inserted" => Map.get(counts, :inserted, 0),
        "replaced" => Map.get(counts, :replaced, 0),
        "unchanged" => Map.get(counts, :unchanged, 0),
        "source_complete" => complete
      },
      metadata: Keyword.get(audit, :metadata, %{})
    }
  end

  # --- small helpers ---

  defp content_hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
