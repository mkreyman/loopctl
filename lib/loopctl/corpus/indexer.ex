defmodule Loopctl.Corpus.Indexer do
  @moduledoc """
  The ingest path for BOTH corpus modes: `POST /api/v1/corpora/:id/index`.

  In mode A (`:server_embedded`) the client sends verbatim chunks; loopctl computes
  each chunk's `content_hash` server-side, embeds only what actually moved, and
  writes every chunk and its vector in ONE `Ecto.Multi`, committed once.

  ## Mode B (`:client_embedded`) — US-43.3

  The client embeds locally and sends `{source_ref, locator, vector, content_hash,
  ordinal, snippet?}`. loopctl NEVER receives the chunk text: there is no parameter
  that accepts it, and a chunk carrying a `text` key is REFUSED
  (`{:text_not_accepted, index}`) rather than silently ignored — a dropped `text`
  would let a client believe the keyword lane works on a corpus that has no text to
  index.

  Everything downstream of `build_item/3` is shared with mode A: the same
  classification, the same ONE `Ecto.Multi`, the same `(corpus_id, source_ref,
  locator)` key, the same `source_complete` reconciliation and the same audit entry.
  Only two things differ — `content_hash` ARRIVES instead of being computed, and
  `embed_changed/3` makes no provider call because the vector arrived too.

  `content_hash` in mode B is an OPAQUE IDEMPOTENCY TOKEN and is never treated as an
  integrity proof. loopctl cannot verify that it corresponds to the vector, to the
  file, or to anything at all — it holds no text to hash — so the client owns that
  correspondence. What IS enforced is the vector's LENGTH against the corpus's pinned
  `dim`, twice: here at the boundary (`{:vector_dimension_mismatch, index, got,
  expected}`, which names both numbers) and again by the
  `document_chunk_embeddings_dim_matches_vector` CHECK constraint. Nothing verifies
  that the vector came from the declared model — that is not computable from a
  vector, and a check that appeared to prove it while proving nothing would be worse
  than saying so.

  `snippet` defaults to NULL. A corpus whose `allow_snippets` is false — the mode B
  DEFAULT — refuses any item carrying one (`{:snippets_not_allowed, index}`).

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

  `content_hash` covers the TEXT, so it decides the EMBEDDING. It does not decide the
  WRITE: `snippet` and `ordinal` are cast from the client and are in the upsert's
  replace list, so a chunk whose text held still while one of them moved is rewritten
  (`replaced`) without re-embedding. Deciding both on the hash silently discarded a
  corrected snippet and left no later re-index able to apply it.

  ## Pruning is reconciliation against a DECLARED chunk set, never inference

  A batch is not a document. So the request NAMES the sources it is reconciling
  (`source_complete`) and only those are touched — a source whose chunk set shrank has
  its surplus chunks deleted, so a document that lost a page stops serving it.

  A name carries the source's COMPLETE chunk set, in one of two forms:

    * `"a.pdf"` — the complete set is what THIS request carries for `"a.pdf"`. The
      form for a document that fits in one batch.
    * `%{"source_ref" => "big.pdf", "locators" => [loc, ...]}` — the complete set is
      the DECLARED locator manifest, which may name chunks earlier batches of the same
      re-index wrote. The form for a document larger than `max_batch_size/0`.

  The manifest form is what makes a large document reconcilable at all. Without it a
  source of more than `max_batch_size/0` chunks could never be named — naming it on the
  batch that completed it deleted what the earlier batches had just written, and not
  naming it pruned nothing — so a 500-chunk book that lost page 47 kept serving page 47
  forever, and the only removal path was destroying the whole corpus. With it, the
  completing batch names the source and lists the document's locators, and nothing an
  earlier batch wrote is deleted.

  Two rules keep the verb below the `:user` line, and they are what make "no request
  prunes content it did not account for" TRUE rather than asserted:

    * a `source_ref` may be named ONLY if the same request carries at least one chunk
      for it, and
    * every chunk the request carries for a named source must appear in that source's
      manifest — otherwise the request would write a chunk and delete it in the same
      transaction.

  And a BARE name — which declares no manifest — may delete at most as many chunks as the
  request carried for that source (`refute_runaway_prune/4`). Without that interlock a
  request carrying ONE chunk of a 5,000-chunk source deleted 4,999 rows, which is a
  set-based delete however it is named. A caller genuinely removing most of a document
  says so with a manifest.

  The delete set is therefore the exact complement of a set the caller wrote down, per
  source, and re-indexing the file restores what a prune took. `pruned_by_source` in
  the response reports what each name cost, and the audit entry records the same map.

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

  # The ceiling on ONE source's declared locator manifest. Unlike the batch ceiling
  # this does not bound the WRITE — a manifest carries no content — it bounds the set
  # the request asks the server to hold in memory while it resolves the keep set. Read
  # by the guard and by the OpenAPI `maxItems`, the same way `@max_batch_size` is.
  @max_source_manifest 20_000

  @doc "The maximum number of locators one `source_complete` manifest may declare."
  @spec max_source_manifest() :: pos_integer()
  def max_source_manifest, do: @max_source_manifest

  @type item_report :: %{source_ref: String.t(), locator: term(), status: atom()}

  @type error ::
          :not_found
          | :audit_write_failed
          | {:batch_too_large, pos_integer()}
          | {:invalid_chunk, non_neg_integer(), String.t() | Ecto.Changeset.t()}
          | {:duplicate_chunk_key, {String.t(), term()}}
          | {:text_not_accepted, non_neg_integer()}
          | {:vector_dimension_mismatch, non_neg_integer(), non_neg_integer(), pos_integer()}
          | {:vector_out_of_range, non_neg_integer(), non_neg_integer()}
          | {:snippets_not_allowed, non_neg_integer()}
          | {:source_complete_not_carried, [term()]}
          | {:source_complete_invalid, term()}
          | {:source_manifest_too_large, String.t(), pos_integer()}
          | {:source_manifest_omits_carried, String.t(), [term()]}
          | {:prune_exceeds_carried, String.t(), non_neg_integer(), non_neg_integer()}
          | {:embedding_failed, term(), [map()]}
          | {:write_failed, term(), term()}

  @doc """
  Indexes `chunks` into `corpus_id` (an id or a slug) for `tenant_id`.

  In mode A each chunk is `%{source_ref, locator, text, ordinal}` — `content_hash`
  is NOT accepted from the client; it is computed here from the text. In mode B each
  chunk is `%{source_ref, locator, vector, content_hash, ordinal, snippet?}` — there
  is no `text` parameter at all, and sending one is refused.

  `opts`:

    * `:source_complete` — the sources to RECONCILE. Each member is either a
      `source_ref` string (the complete set is what this request carries for it) or
      `%{"source_ref" => ref, "locators" => [locator, ...]}` (the complete set is the
      declared manifest, so a document spanning several batches can be reconciled on
      the batch that completes it). Each named source must be carried by the batch,
      and every carried chunk of it must appear in its manifest.
    * `:audit` — the actor-context keyword list from
      `LoopctlWeb.AuditContext.from_conn/1`.

  Returns `{:ok, %{items: [...], pruned: n, pruned_by_source: %{ref => n}, corpus:
  corpus}}`, where each item reports `unchanged | inserted | replaced` for its
  `(source_ref, locator)`. A chunk whose TEXT is unchanged but whose `snippet` or
  `ordinal` moved is `replaced`: the row is rewritten, and no embedding is spent.
  """
  @spec index_chunks(Ecto.UUID.t(), String.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, error()}
  def index_chunks(tenant_id, corpus_id, chunks, opts \\ [])
      when is_binary(tenant_id) and is_list(chunks) do
    with {:ok, corpus} <- Corpus.get_corpus(tenant_id, corpus_id),
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
        {:error, reason} -> {:halt, {:error, wrap_item_error(reason, index)}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp build_item(%CorpusRow{mode: :server_embedded} = corpus, attrs, index)
       when is_map(attrs) do
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

  # Mode B (US-43.3). The `text` refusal is FIRST and is checked on the KEY's presence,
  # not on its value: a client that sends `text: ""` or `text: nil` to a corpus with no
  # text lane has the same misunderstanding as one that sends a page of it, and answering
  # 200 to either would let it believe the keyword lane works.
  #
  # Every other refusal here names what arrived, because the alternative — accepting the
  # item and letting the CHECK constraint raise — is a raw Postgrex 500 the caller cannot
  # act on.
  defp build_item(%CorpusRow{mode: :client_embedded} = corpus, attrs, index)
       when is_map(attrs) do
    attrs = stringify_keys(attrs)
    vector = Map.get(attrs, "vector")

    cond do
      Map.has_key?(attrs, "text") ->
        {:error, {:text_not_accepted, index}}

      not present?(Map.get(attrs, "source_ref")) ->
        {:error, "source_ref is required"}

      not present?(Map.get(attrs, "content_hash")) ->
        {:error,
         "content_hash is required — a client_embedded corpus sends no text, so loopctl " <>
           "has nothing to hash and takes yours as an opaque idempotency token"}

      not vector?(vector) ->
        {:error,
         "vector is required and must be a non-empty array of numbers — a " <>
           "client_embedded corpus stores the vector you embedded locally"}

      length(vector) != corpus.dim ->
        {:error, {:vector_dimension_mismatch, index, length(vector), corpus.dim}}

      out_of_range_index(vector) ->
        {:error, {:vector_out_of_range, index, out_of_range_index(vector)}}

      snippet_forbidden?(corpus, attrs) ->
        {:error, {:snippets_not_allowed, index}}

      true ->
        client_item(corpus, attrs, vector, index)
    end
  end

  defp build_item(_corpus, _attrs, _index), do: {:error, "each chunk must be an object"}

  # The dedicated mode B terms already carry their own index and are passed through
  # whole; a plain message or a changeset is the generic per-item shape and is wrapped.
  defp wrap_item_error(reason, index) when is_binary(reason), do: {:invalid_chunk, index, reason}

  defp wrap_item_error(%Ecto.Changeset{} = changeset, index),
    do: {:invalid_chunk, index, changeset}

  defp wrap_item_error(reason, _index), do: reason

  defp snippet_forbidden?(%CorpusRow{allow_snippets: true}, _attrs), do: false
  defp snippet_forbidden?(_corpus, attrs), do: not is_nil(Map.get(attrs, "snippet"))

  defp vector?(value) when is_list(value),
    do: value != [] and Enum.all?(value, &is_number/1)

  defp vector?(_value), do: false

  # `Pgvector.Ecto.Vector`'s cast DISCARDS an element outside pgvector's float32 element
  # range instead of erroring, so a 1536-element vector carrying one arrives at the
  # changeset 1535 long and fails the dimension validator with numbers that describe
  # nothing the caller sent — surfacing as an opaque 500. Refused here, at the same
  # boundary and in the same shape as the length mismatch above.
  defp out_of_range_index(vector),
    do: DocumentChunkEmbedding.out_of_float32_range_index(vector)

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

  # `text` is forced to nil rather than merely absent: the field is castable, and a
  # `%DocumentChunk{}` reused across a re-index must not carry a value from anywhere.
  # `vector` is dropped before the cast — it belongs to the EMBEDDING row, not the chunk.
  defp client_item(corpus, attrs, vector, index) do
    hash = Map.fetch!(attrs, "content_hash")

    changeset =
      DocumentChunk.changeset(
        %DocumentChunk{tenant_id: corpus.tenant_id},
        attrs
        |> Map.drop(["vector"])
        |> Map.merge(%{"corpus_id" => corpus.id, "content_hash" => hash, "text" => nil})
      )

    if changeset.valid? do
      chunk = Ecto.Changeset.apply_changes(changeset)

      {:ok,
       %{
         index: index,
         source_ref: chunk.source_ref,
         locator: chunk.locator,
         text: nil,
         snippet: chunk.snippet,
         ordinal: chunk.ordinal,
         content_hash: hash,
         vector: vector
       }}
    else
      {:error, changeset}
    end
  end

  # AC-43.2.3. Normalises every member to `%{source_ref: ref, locators: manifest | nil}`
  # and enforces the two rules that bound the delete:
  #
  #   * a source may be named ONLY if this request carries at least one chunk for it,
  #     and
  #   * every carried chunk of a named source must appear in that source's manifest —
  #     otherwise the request would write a chunk and delete it in the same transaction.
  #
  # `nil` locators means "the complete set is what this request carries", which is the
  # bare-string form and the whole document for anything that fits in one batch.
  defp validate_source_complete(_items, nil), do: {:ok, []}
  defp validate_source_complete(_items, []), do: {:ok, []}

  defp validate_source_complete(items, members) when is_list(members) do
    carried = carried_locators(items)

    Enum.reduce_while(members, {:ok, []}, fn member, {:ok, acc} ->
      case normalise_member(member, carried) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, entries |> Enum.reverse() |> Enum.uniq_by(& &1.source_ref)}
      error -> error
    end
  end

  # A `source_complete` that is not a LIST at all — `source_complete: "docs/837p.pdf"`,
  # the obvious client mistake. It gets its OWN code rather than being folded into
  # `source_complete_not_carried`, which would have told the caller that a source it DOES
  # carry is not carried, with an empty `missing` list as the only evidence and no way to
  # learn the real fault is the type.
  defp validate_source_complete(_items, value),
    do: {:error, {:source_complete_invalid, value}}

  # Every member is checked against the carried set, INCLUDING a non-binary one. Filtering
  # non-binaries out first discarded them BEFORE the carried-check could refuse them, so
  # `source_complete: [123]` collapsed to the empty list, pruned nothing and returned 200
  # — a client that believed it had reconciled a shrunk document while the surplus chunks
  # stayed indexed and kept being returned by search. A `source_ref` column is a string,
  # so a non-binary is never carried and takes the same 422 the string case takes.
  defp normalise_member(source_ref, carried) when is_binary(source_ref) do
    if Map.has_key?(carried, source_ref) do
      {:ok, %{source_ref: source_ref, locators: nil}}
    else
      {:error, {:source_complete_not_carried, [source_ref]}}
    end
  end

  defp normalise_member(member, carried) when is_map(member) and not is_struct(member),
    do: normalise_object(stringify_keys(member), carried)

  # A member that is neither a string nor an object is never carried — a `source_ref`
  # column is a string — so it takes the carried refusal, which NAMES it rather than
  # dropping it.
  defp normalise_member(member, _carried),
    do: {:error, {:source_complete_not_carried, [member]}}

  defp normalise_object(%{"source_ref" => source_ref, "locators" => locators}, carried)
       when is_binary(source_ref) and is_list(locators) do
    with :ok <- refute_uncarried(source_ref, carried),
         :ok <- refute_oversize_manifest(source_ref, locators) do
      manifest = MapSet.new(locators, &Corpus.canonical_locator/1)

      case Enum.reject(Map.fetch!(carried, source_ref), &MapSet.member?(manifest, &1)) do
        [] -> {:ok, %{source_ref: source_ref, locators: manifest}}
        omitted -> {:error, {:source_manifest_omits_carried, source_ref, omitted}}
      end
    end
  end

  defp normalise_object(object, _carried), do: {:error, {:source_complete_invalid, object}}

  defp refute_uncarried(source_ref, carried) do
    if Map.has_key?(carried, source_ref),
      do: :ok,
      else: {:error, {:source_complete_not_carried, [source_ref]}}
  end

  defp refute_oversize_manifest(source_ref, locators)
       when length(locators) > @max_source_manifest,
       do: {:error, {:source_manifest_too_large, source_ref, @max_source_manifest}}

  defp refute_oversize_manifest(_source_ref, _locators), do: :ok

  # `source_ref => [canonical locator]` for what this request carries, canonicalised the
  # way Postgres compares jsonb so a manifest written `{"page": 1}` matches a carried
  # `{"page": 1.0}` exactly as the unique index would.
  defp carried_locators(items) do
    Enum.group_by(items, & &1.source_ref, &Corpus.canonical_locator(&1.locator))
  end

  # --- classification ---

  defp classify(tenant_id, corpus, items) do
    existing = load_existing(tenant_id, corpus, Enum.map(items, & &1.source_ref))

    {:ok, Enum.map(items, &classify_item(&1, existing))}
  end

  # TWO decisions, deliberately separate. `status` is what the caller is told; `rewrite`
  # is what the transaction does.
  #
  # `content_hash` covers TEXT only, and it is the right input for the EMBEDDING decision
  # — re-embedding text that did not move spends tokens for an identical vector. It is
  # the wrong input for the WRITE decision: `snippet` and `ordinal` are cast from the
  # client and are both in the upsert's replace list, so deciding on the hash alone
  # answered "unchanged" to a request that corrected a snippet or renumbered a chunk,
  # dropped the values, and left no later re-index able to apply them — the text hash
  # never moves again. A metadata-only change therefore rewrites the ROW (reported
  # `replaced`, because the row was) and skips the embedding entirely.
  defp classify_item(item, existing) do
    case Map.get(existing, {item.source_ref, Corpus.canonical_locator(item.locator)}) do
      nil ->
        Map.merge(item, %{status: :inserted, rewrite: :full, chunk_id: nil})

      %{id: id} = stored ->
        {status, rewrite} = classify_change(stored, item)
        Map.merge(item, %{status: status, rewrite: rewrite, chunk_id: id})
    end
  end

  defp classify_change(stored, item) do
    cond do
      stored.content_hash != item.content_hash -> {:replaced, :full}
      stored.snippet != item.snippet -> {:replaced, :metadata}
      stored.ordinal != item.ordinal -> {:replaced, :metadata}
      true -> {:unchanged, :none}
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
        content_hash: c.content_hash,
        snippet: c.snippet,
        ordinal: c.ordinal
      }
    )
    |> AdminRepo.all()
    |> Map.new(fn row ->
      {{row.source_ref, Corpus.canonical_locator(row.locator)},
       Map.take(row, [:id, :content_hash, :snippet, :ordinal])}
    end)
  end

  # --- embedding ---

  # ONE provider call for the whole batch (one admission token, one concurrency
  # slot), and vectors map back by the response's `index` field inside the client —
  # never by array position here. A partial response fails the whole batch. Only
  # changed items are sent, so a re-index of an unchanged corpus spends nothing.
  # Mode B makes NO provider call: the vector arrived with the chunk, so there is no
  # admission token, no `ShrinkLadder` run and nothing to truncate. A vector is attached
  # only where the row is actually being rewritten, so an unchanged mode B re-index
  # writes no embedding row for the same reason an unchanged mode A one does not.
  defp embed_changed(_tenant_id, %CorpusRow{mode: :client_embedded}, items) do
    {:ok, Enum.map(items, &attach_client_vector/1)}
  end

  defp embed_changed(tenant_id, corpus, items) do
    targets = Enum.filter(items, &(&1.rewrite == :full))

    if targets == [] do
      {:ok, Enum.map(items, &Map.merge(&1, %{embedding: nil, truncated?: false}))}
    else
      run_embed(tenant_id, corpus, items, targets)
    end
  end

  defp attach_client_vector(%{rewrite: :full} = item),
    do: Map.merge(item, %{embedding: item.vector, truncated?: false})

  defp attach_client_vector(item), do: Map.merge(item, %{embedding: nil, truncated?: false})

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
      # The prune steps run BEFORE this one, so `changes` already carries every prune
      # count — which is why the closure reads its argument rather than discarding it.
      # `POST /corpora/:id/index` is the one index verb that DESTROYS data and it is held
      # at `role: :agent` on the argument that its delete is bounded and attributable, so
      # an append-only log that could not say what an agent-role key deleted would not be
      # answering the question the gate is justified by.
      |> Audit.log_in_multi(:audit, fn changes ->
        audit_attrs(
          tenant_id,
          corpus,
          items,
          complete,
          audit,
          pruned_by_source(changes, complete)
        )
      end)

    case AdminRepo.transaction(multi) do
      {:ok, changes} ->
        by_source = pruned_by_source(changes, complete)

        {:ok,
         %{
           corpus: corpus,
           items: Enum.map(items, &Map.take(&1, [:source_ref, :locator, :status])),
           # Reported PER SOURCE as well as in total: a named source is reconciled
           # against this request alone, so the caller must be able to see exactly what
           # each name cost rather than reading one aggregate.
           pruned: by_source |> Map.values() |> Enum.sum(),
           pruned_by_source: by_source
         }}

      # Matching `:audit` explicitly (never `_step`) keeps the compile-time gate: if
      # `Audit.log_in_multi/3` is ever changed to fail with a non-changeset value this
      # clause stops covering it and the build fails here instead of silently
      # mis-mapping an audit failure onto a write failure.
      {:error, :audit, %Ecto.Changeset{}, _changes} ->
        {:error, :audit_write_failed}

      # The bare-name interlock, raised from inside the prune step so the whole request
      # rolls back. Mapped to its OWN term (a 422 the caller can act on), never to the
      # generic write failure, whose 500 would read as a server fault.
      {:error, {:prune, _ref}, {:prune_exceeds_carried, _, _, _} = reason, _changes} ->
        {:error, reason}

      {:error, step, reason, _changes} ->
        {:error, {:write_failed, step, reason}}
    end
  end

  defp add_item(multi, _tenant_id, _corpus, %{rewrite: :none}), do: multi

  # Metadata-only: the row is rewritten so the corrected snippet/ordinal land, and the
  # embedding step is SKIPPED — the text did not move, so the stored vector and its hash
  # are still the right ones and there is nothing to re-embed.
  defp add_item(multi, tenant_id, corpus, %{rewrite: :metadata} = item) do
    Multi.run(multi, {:chunk, item.index}, fn repo, _changes ->
      upsert_chunk(repo, tenant_id, corpus, item)
    end)
  end

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
  #
  # The kept set is the ids this request wrote or confirmed, PLUS — for a manifest name —
  # the ids of stored chunks the manifest declares. That second half is what lets a
  # document larger than `max_batch_size/0` be reconciled at all: the completing batch
  # lists the document's locators, so the chunks earlier batches wrote are kept instead of
  # deleted. A bare name declares no manifest and reconciles against the carried set alone.
  defp add_prunes(multi, tenant_id, corpus, complete, items) do
    Enum.reduce(complete, multi, fn %{source_ref: source_ref, locators: manifest}, acc ->
      of_source = Enum.filter(items, &(&1.source_ref == source_ref))
      unchanged = for i <- of_source, i.rewrite == :none, do: i.chunk_id
      written = for i <- of_source, i.rewrite != :none, do: i.index

      Multi.run(acc, {:prune, source_ref}, fn repo, changes ->
        kept =
          unchanged ++
            Enum.map(written, &Map.fetch!(changes, {:chunk, &1}).id) ++
            declared_ids(repo, tenant_id, corpus, source_ref, manifest)

        {count, _} =
          from(c in DocumentChunk,
            where:
              c.tenant_id == ^tenant_id and c.corpus_id == ^corpus.id and
                c.source_ref == ^source_ref and c.id not in ^kept
          )
          |> repo.delete_all()

        refute_runaway_prune(source_ref, manifest, count, length(of_source))
      end)
    end)
  end

  # The BARE-name safety interlock, and the reason `POST /corpora/:id/index` can hold its
  # `role: :agent` gate honestly.
  #
  # A bare name asserts "the complete set is what I carry", and the server cannot tell a
  # genuine shrink from a client that named the source on the LAST batch of a split
  # document — both look like "carries fewer chunks than are stored". Unguarded, one
  # request carrying ONE chunk of a 5,000-chunk source deleted 4,999 rows and their
  # vectors, which is a set-based delete wearing an index request's clothes.
  #
  # So a bare name may delete at most as many chunks as the request carried for that
  # source. A real reconciliation resends the document and removes a few pages, which
  # clears this comfortably; the batch-3-of-3 mistake does not. The refusal happens INSIDE
  # the transaction, after the delete has counted itself, so the whole request rolls back
  # and nothing is lost. A caller that really is removing most of a document declares the
  # surviving locators explicitly — the manifest form, which is exempt precisely because
  # the caller then wrote the keep set down.
  defp refute_runaway_prune(_source_ref, manifest, count, _carried) when manifest != nil,
    do: {:ok, count}

  defp refute_runaway_prune(source_ref, _manifest, count, carried) when count > carried,
    do: {:error, {:prune_exceeds_carried, source_ref, count, carried}}

  defp refute_runaway_prune(_source_ref, _manifest, count, _carried), do: {:ok, count}

  # The stored chunks of `source_ref` whose locator the manifest declares. Resolved to
  # IDS here, in Elixir, against `Corpus.canonical_locator/1` — the same normalisation the
  # duplicate-key guard uses and the one jsonb itself applies — so the delete stays an
  # `id not in` and never becomes a jsonb comparison in the WHERE clause.
  defp declared_ids(_repo, _tenant_id, _corpus, _source_ref, nil), do: []

  defp declared_ids(repo, tenant_id, corpus, source_ref, manifest) do
    from(c in DocumentChunk,
      where:
        c.tenant_id == ^tenant_id and c.corpus_id == ^corpus.id and
          c.source_ref == ^source_ref,
      select: %{id: c.id, locator: c.locator}
    )
    |> repo.all()
    |> Enum.filter(&MapSet.member?(manifest, Corpus.canonical_locator(&1.locator)))
    |> Enum.map(& &1.id)
  end

  defp pruned_by_source(changes, complete) do
    Map.new(complete, fn %{source_ref: source_ref} ->
      {source_ref, Map.get(changes, {:prune, source_ref}, 0)}
    end)
  end

  defp audit_attrs(tenant_id, corpus, items, complete, audit, pruned_by_source) do
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
        "pruned" => pruned_by_source |> Map.values() |> Enum.sum(),
        "pruned_by_source" => pruned_by_source,
        "source_complete" => Enum.map(complete, & &1.source_ref)
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
