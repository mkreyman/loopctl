defmodule Loopctl.Corpus.IndexerTest do
  @moduledoc """
  US-43.2 — mode A ingest.

  Covers TC-43.2.1 (an unchanged re-index is a no-op: no writes, no provider call, no
  `updated_at` churn), TC-43.2.2 (a changed document replaces only its own chunk),
  TC-43.2.3 (`source_complete` is what prunes, and only what the request carries),
  TC-43.2.7 (a failed batch leaves nothing behind, names the failing item, and the
  corrected resubmit converges) and TC-43.2.10 (a failed audit write rolls the whole
  request back and is distinguishable from a validation error), plus the mandatory
  tenant-isolation case.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Corpus
  alias Loopctl.Corpus.DocumentChunk
  alias Loopctl.Corpus.DocumentChunkEmbedding
  alias Loopctl.Corpus.Indexer
  alias Loopctl.Embeddings.ShrinkLadder

  setup :verify_on_exit!

  # The default MockEmbeddingClient stub returns a 1536-dim vector per text, so the
  # corpus is pinned at the model whose NATIVE dimension is 1536. That is also what
  # makes each TENANT's vectors a distinct family (the stub is a pure function of
  # tenant_id), which is what keeps the shared HNSW index navigable across the suite.
  defp create_corpus!(tenant_id, attrs \\ %{}) do
    seq = System.unique_integer([:positive])

    {:ok, corpus} =
      Corpus.create_corpus(
        tenant_id,
        Map.merge(
          %{
            slug: "guides-#{seq}",
            name: "Companion guides",
            mode: :server_embedded,
            embedding_model: "text-embedding-3-small",
            dim: 1536
          },
          attrs
        )
      )

    corpus
  end

  defp chunk(source_ref, page, text) do
    %{
      "source_ref" => source_ref,
      "locator" => %{"page" => page},
      "text" => text,
      "ordinal" => page
    }
  end

  defp pages(source_ref, count, prefix \\ "Loop 2310B carries the rendering provider, page ") do
    for page <- 1..count, do: chunk(source_ref, page, prefix <> Integer.to_string(page))
  end

  defp audit_opts, do: [actor_type: "api_key", actor_label: "agent:test"]

  defp chunks_of(corpus) do
    AdminRepo.all(from(c in DocumentChunk, where: c.corpus_id == ^corpus.id))
  end

  defp embedding_count(corpus) do
    AdminRepo.aggregate(
      from(e in DocumentChunkEmbedding,
        join: c in DocumentChunk,
        on: c.id == e.document_chunk_id,
        where: c.corpus_id == ^corpus.id
      ),
      :count,
      :id
    )
  end

  defp index!(tenant_id, corpus, chunks, opts \\ []) do
    {:ok, result} =
      Indexer.index_chunks(
        tenant_id,
        corpus.id,
        chunks,
        Keyword.put_new(opts, :audit, audit_opts())
      )

    result
  end

  defp statuses(result), do: Enum.map(result.items, & &1.status)

  defp index_audit_entries(tenant_id) do
    AdminRepo.all(
      from(a in Loopctl.Audit.AuditLog,
        where: a.tenant_id == ^tenant_id and a.action == "corpus_indexed",
        order_by: [asc: a.inserted_at, asc: a.id]
      )
    )
  end

  describe "index_chunks/4 — first pass" do
    test "inserts every chunk with a server-computed hash and its embedding" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      result = index!(tenant.id, corpus, pages("a.pdf", 3))

      assert statuses(result) == [:inserted, :inserted, :inserted]
      assert length(chunks_of(corpus)) == 3
      assert embedding_count(corpus) == 3

      # The client never supplies content_hash in mode A — the server derives it from
      # the text, so a client cannot claim a chunk is unchanged when its text moved.
      [%DocumentChunk{} = stored | _] = chunks_of(corpus)
      assert stored.content_hash =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "an empty batch is refused rather than committing a transaction that does nothing" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      assert {:error, {:invalid_chunk, 0, _}} = Indexer.index_chunks(tenant.id, corpus.id, [])
    end

    test "a batch above the ceiling is refused, and the ceiling is the published one" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      oversize = pages("a.pdf", Indexer.max_batch_size() + 1)

      assert {:error, {:batch_too_large, max}} =
               Indexer.index_chunks(tenant.id, corpus.id, oversize)

      assert max == Indexer.max_batch_size()
    end

    test "a client_embedded corpus refuses this endpoint" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id, %{mode: :client_embedded})

      assert {:error, :mode_mismatch} =
               Indexer.index_chunks(tenant.id, corpus.id, pages("a.pdf", 1))
    end

    test "two chunks sharing one (source_ref, locator) in ONE batch are refused" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      batch = [chunk("a.pdf", 1, "first"), chunk("a.pdf", 1, "second")]

      assert {:error, {:duplicate_chunk_key, {"a.pdf", _}}} =
               Indexer.index_chunks(tenant.id, corpus.id, batch)
    end
  end

  # TC-43.2.1
  describe "re-indexing an unchanged corpus" do
    test "is a no-op: every item unchanged, no provider call, no row or timestamp churn" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      batch = pages("a.pdf", 5)

      index!(tenant.id, corpus, batch)
      before = chunks_of(corpus) |> Map.new(&{&1.id, &1.updated_at})

      # Zero permitted invocations: a re-index that re-embedded would re-bill the
      # provider for a corpus that did not move, which is the whole point of hashing.
      expect(Loopctl.MockEmbeddingClient, :generate_embeddings, 0, fn _scope, _texts, _opts ->
        {:ok, []}
      end)

      result = index!(tenant.id, corpus, batch)

      assert statuses(result) == List.duplicate(:unchanged, 5)
      assert result.pruned == 0
      assert length(chunks_of(corpus)) == 5
      assert embedding_count(corpus) == 5
      assert Map.new(chunks_of(corpus), &{&1.id, &1.updated_at}) == before
    end
  end

  # TC-43.2.2
  describe "a changed document" do
    test "replaces only its own chunk and leaves its siblings and the other source alone" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("a.pdf", 3) ++ pages("b.pdf", 2))
      before = chunks_of(corpus) |> Map.new(&{{&1.source_ref, &1.locator}, &1})

      changed = [
        chunk("a.pdf", 1, "Loop 2310B carries the rendering provider, page 1"),
        chunk("a.pdf", 2, "REWRITTEN: loop 2310B is now the referring provider"),
        chunk("a.pdf", 3, "Loop 2310B carries the rendering provider, page 3")
      ]

      result = index!(tenant.id, corpus, changed)

      assert statuses(result) == [:unchanged, :replaced, :unchanged]

      after_rows = chunks_of(corpus) |> Map.new(&{{&1.source_ref, &1.locator}, &1})

      # Replaced IN PLACE at the same (corpus_id, source_ref, locator) — a second row
      # at the same locator is exactly what keying on content_hash would have produced.
      assert map_size(after_rows) == 5
      replaced = after_rows[{"a.pdf", %{"page" => 2}}]
      assert replaced.id == before[{"a.pdf", %{"page" => 2}}].id
      assert replaced.text =~ "REWRITTEN"
      assert replaced.content_hash != before[{"a.pdf", %{"page" => 2}}].content_hash

      for key <- [{"a.pdf", %{"page" => 1}}, {"a.pdf", %{"page" => 3}}, {"b.pdf", %{"page" => 1}}] do
        assert after_rows[key].updated_at == before[key].updated_at
      end

      assert embedding_count(corpus) == 5
    end
  end

  # TC-43.2.3
  describe "a document that lost chunks" do
    test "keeps serving them until the source is named complete, then stops" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("a.pdf", 10) ++ pages("b.pdf", 2))
      assert length(chunks_of(corpus)) == 12

      # Batch one of a multi-batch document: it does NOT name the source, so it must
      # not delete the chunks the later batches are about to send.
      shrunk = Enum.take(pages("a.pdf", 10), 7)
      result = index!(tenant.id, corpus, shrunk)

      assert result.pruned == 0
      assert length(chunks_of(corpus)) == 12

      # The same seven chunks, now declared to be the whole document.
      result = index!(tenant.id, corpus, shrunk, source_complete: ["a.pdf"])

      assert result.pruned == 3
      assert statuses(result) == List.duplicate(:unchanged, 7)

      remaining = chunks_of(corpus)
      assert length(remaining) == 9
      assert embedding_count(corpus) == 9

      surviving_pages =
        remaining |> Enum.filter(&(&1.source_ref == "a.pdf")) |> Enum.map(& &1.locator)

      refute %{"page" => 8} in surviving_pages
      refute %{"page" => 9} in surviving_pages
      refute %{"page" => 10} in surviving_pages
      assert Enum.count(remaining, &(&1.source_ref == "b.pdf")) == 2
    end

    # A NON-STRING member used to be filtered out before the carried-check could see it,
    # so `source_complete: [123]` collapsed to the empty list, pruned nothing and returned
    # 200 — a client that believed it had reconciled a shrunk document while the surplus
    # chunks stayed indexed and kept being served by search.
    test "a non-string source_complete member is refused, not silently dropped" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("a.pdf", 4))

      assert {:error, {:source_complete_not_carried, [123]}} =
               Indexer.index_chunks(tenant.id, corpus.id, Enum.take(pages("a.pdf", 4), 2),
                 source_complete: [123],
                 audit: audit_opts()
               )

      assert length(chunks_of(corpus)) == 4
    end

    # THE case a bare name cannot serve, and the interlock that stops it destroying the
    # document instead. A bare name asserts "what I carry IS the whole source"; on the
    # last batch of a split document that assertion is false, and unguarded it deleted
    # everything the earlier batches wrote. The refusal happens inside the transaction,
    # so nothing is lost and the caller is pointed at the form that does work.
    test "a bare name whose prune would exceed what the request carries is refused" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      all = pages("big.pdf", 9)

      index!(tenant.id, corpus, Enum.slice(all, 0..2))
      index!(tenant.id, corpus, Enum.slice(all, 3..5))
      assert length(chunks_of(corpus)) == 6

      assert {:error, {:prune_exceeds_carried, "big.pdf", 6, 3}} =
               Indexer.index_chunks(tenant.id, corpus.id, Enum.slice(all, 6..8),
                 source_complete: ["big.pdf"],
                 audit: audit_opts()
               )

      # Rolled back in full: the earlier batches survive AND the last batch is not
      # half-applied.
      assert length(chunks_of(corpus)) == 6
    end

    # The finding this interlock closes, at its named scale: ONE chunk of a large source,
    # bare-named, used to delete every other chunk of it on a `role: :agent` key.
    test "one chunk of a large source cannot bare-name away the rest" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("big.pdf", 40))

      assert {:error, {:prune_exceeds_carried, "big.pdf", 39, 1}} =
               Indexer.index_chunks(tenant.id, corpus.id, [chunk("big.pdf", 1, "page 1")],
                 source_complete: ["big.pdf"],
                 audit: audit_opts()
               )

      assert length(chunks_of(corpus)) == 40
      assert embedding_count(corpus) == 40
    end

    # The manifest form, and the reason it exists: a document larger than one batch could
    # otherwise never be reconciled at all — naming it on the completing batch deleted the
    # earlier batches, and not naming it pruned nothing, so a book that lost a page kept
    # serving that page forever and the only removal path was destroying the corpus.
    test "a manifest reconciles a document spanning several batches without deleting them" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      all = pages("big.pdf", 9)

      index!(tenant.id, corpus, Enum.slice(all, 0..2))
      index!(tenant.id, corpus, Enum.slice(all, 3..5))
      index!(tenant.id, corpus, Enum.slice(all, 6..8))
      assert length(chunks_of(corpus)) == 9

      # The document lost page 4. It is re-indexed across the same bounded batches, and
      # the LAST one names it with the whole surviving locator set.
      surviving = Enum.reject(all, &(&1["locator"] == %{"page" => 4}))

      index!(tenant.id, corpus, Enum.slice(surviving, 0..2))
      index!(tenant.id, corpus, Enum.slice(surviving, 3..4))

      result =
        index!(tenant.id, corpus, Enum.slice(surviving, 5..7),
          source_complete: [
            %{
              "source_ref" => "big.pdf",
              "locators" => Enum.map(surviving, & &1["locator"])
            }
          ]
        )

      assert result.pruned == 1
      assert result.pruned_by_source == %{"big.pdf" => 1}

      locators = chunks_of(corpus) |> Enum.map(& &1.locator)
      assert length(locators) == 8
      refute %{"page" => 4} in locators
      assert embedding_count(corpus) == 8
    end

    # jsonb compares numbers numerically and renders every key as a string, so a manifest
    # must match a stored locator the way the unique index does — not by term equality.
    test "a manifest locator matches a stored one the way jsonb compares them" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("a.pdf", 3))

      result =
        index!(
          tenant.id,
          corpus,
          [chunk("a.pdf", 3, "Loop 2310B carries the rendering provider, page 3")],
          source_complete: [
            %{
              source_ref: "a.pdf",
              locators: [%{"page" => 1.0}, %{page: 2}, %{"page" => 3}]
            }
          ]
        )

      assert result.pruned == 0
      assert length(chunks_of(corpus)) == 3
    end

    test "a manifest that omits a locator this request carries is refused" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("a.pdf", 3))

      assert {:error, {:source_manifest_omits_carried, "a.pdf", omitted}} =
               Indexer.index_chunks(tenant.id, corpus.id, pages("a.pdf", 3),
                 source_complete: [%{"source_ref" => "a.pdf", "locators" => [%{"page" => 1}]}],
                 audit: audit_opts()
               )

      assert length(omitted) == 2
      assert length(chunks_of(corpus)) == 3
    end

    test "a manifest naming a source the batch does not carry is refused" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("a.pdf", 2) ++ pages("b.pdf", 2))

      assert {:error, {:source_complete_not_carried, ["b.pdf"]}} =
               Indexer.index_chunks(tenant.id, corpus.id, pages("a.pdf", 2),
                 source_complete: [%{"source_ref" => "b.pdf", "locators" => []}],
                 audit: audit_opts()
               )

      assert length(chunks_of(corpus)) == 4
    end

    test "a manifest larger than the ceiling is refused" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("a.pdf", 1))

      oversize = for page <- 1..(Indexer.max_source_manifest() + 1), do: %{"page" => page}

      assert {:error, {:source_manifest_too_large, "a.pdf", _max}} =
               Indexer.index_chunks(tenant.id, corpus.id, pages("a.pdf", 1),
                 source_complete: [%{"source_ref" => "a.pdf", "locators" => oversize}],
                 audit: audit_opts()
               )

      assert length(chunks_of(corpus)) == 1
    end

    # A `source_complete` that is not a LIST at all. It used to take the carried refusal
    # with an EMPTY `missing` list, telling the caller that a source it plainly DID carry
    # was not carried, with no way to learn the real fault was the type.
    test "a non-list source_complete is refused with its own code, echoing what arrived" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("a.pdf", 2))

      assert {:error, {:source_complete_invalid, "a.pdf"}} =
               Indexer.index_chunks(tenant.id, corpus.id, pages("a.pdf", 2),
                 source_complete: "a.pdf",
                 audit: audit_opts()
               )

      assert length(chunks_of(corpus)) == 2
    end

    test "a member that is an object without a locators list is refused as invalid" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("a.pdf", 2))

      assert {:error, {:source_complete_invalid, %{"source_ref" => "a.pdf"}}} =
               Indexer.index_chunks(tenant.id, corpus.id, pages("a.pdf", 2),
                 source_complete: [%{"source_ref" => "a.pdf"}],
                 audit: audit_opts()
               )

      assert length(chunks_of(corpus)) == 2
    end

    test "naming a source the batch does not carry is refused" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("a.pdf", 2) ++ pages("b.pdf", 2))

      assert {:error, {:source_complete_not_carried, ["b.pdf"]}} =
               Indexer.index_chunks(tenant.id, corpus.id, pages("a.pdf", 2),
                 source_complete: ["a.pdf", "b.pdf"],
                 audit: audit_opts()
               )

      # Nothing was pruned: the refusal is what keeps this verb below the :user line.
      assert length(chunks_of(corpus)) == 4
    end
  end

  describe "the audit entry for a request that pruned" do
    # `POST /corpora/:id/index` is the one index verb that DESTROYS data, and it is held
    # at `role: :agent` on the argument that its delete is bounded and attributable. An
    # append-only log that recorded only item counts could not say what an agent-role key
    # deleted, so the request that removed three pages and the one that removed none were
    # indistinguishable in it.
    test "records the prune, in total and per named source" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("a.pdf", 5))
      index!(tenant.id, corpus, Enum.take(pages("a.pdf", 5), 3), source_complete: ["a.pdf"])

      [_first, pruning] = index_audit_entries(tenant.id)

      assert pruning.new_state["pruned"] == 2
      assert pruning.new_state["pruned_by_source"] == %{"a.pdf" => 2}
      assert pruning.new_state["source_complete"] == ["a.pdf"]
    end

    test "records a zero prune for a request that named nothing" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("a.pdf", 2))

      [entry] = index_audit_entries(tenant.id)

      assert entry.new_state["pruned"] == 0
      assert entry.new_state["pruned_by_source"] == %{}
    end
  end

  describe "a snippet longer than the documented bound" do
    # The ingest request schema publishes `snippet.maxLength`; nothing enforced it, so a
    # 50 KB snippet was accepted and stored verbatim against a cap the server did not
    # have. Both ends now read `DocumentChunk.max_snippet_chars/0`.
    test "is refused rather than stored against a cap the server does not have" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      over = String.duplicate("y", DocumentChunk.max_snippet_chars() + 1)
      item = Map.put(chunk("a.pdf", 1, "the loop 2310B body"), "snippet", over)

      assert {:error, {:invalid_chunk, 0, %Ecto.Changeset{} = changeset}} =
               Indexer.index_chunks(tenant.id, corpus.id, [item], audit: audit_opts())

      assert %{snippet: [_message]} = Ecto.Changeset.traverse_errors(changeset, & &1)
      assert chunks_of(corpus) == []
    end

    test "a snippet at exactly the bound is accepted" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      at_bound = String.duplicate("y", DocumentChunk.max_snippet_chars())
      item = Map.put(chunk("a.pdf", 1, "the loop 2310B body"), "snippet", at_bound)

      index!(tenant.id, corpus, [item])

      assert [stored] = chunks_of(corpus)
      assert stored.snippet == at_bound
    end
  end

  describe "a chunk whose text held still while its snippet or ordinal moved" do
    # `content_hash` covers the TEXT only. Deciding the WRITE on it too answered
    # "unchanged" to a request that corrected a snippet or renumbered a chunk, dropped
    # both values, and left no later re-index able to apply them — the hash never moves
    # again. The row is rewritten; the embedding is NOT re-spent.
    test "is rewritten and reported replaced, without spending an embedding" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      first =
        Map.merge(chunk("a.pdf", 1, "the loop 2310B body"), %{
          "snippet" => "old snippet",
          "ordinal" => 1
        })

      index!(tenant.id, corpus, [first])

      calls = :counters.new(1, [])

      stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, texts, _opts ->
        :counters.add(calls, 1, 1)
        {:ok, Enum.map(texts, fn _text -> List.duplicate(0.02, 1536) end)}
      end)

      corrected = Map.merge(first, %{"snippet" => "corrected snippet", "ordinal" => 7})
      result = index!(tenant.id, corpus, [corrected])

      assert statuses(result) == [:replaced]
      assert :counters.get(calls, 1) == 0

      [stored] = chunks_of(corpus)
      assert stored.snippet == "corrected snippet"
      assert stored.ordinal == 7
      assert embedding_count(corpus) == 1
    end

    test "an identical resubmit is still unchanged and writes nothing" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      item = Map.put(chunk("a.pdf", 1, "the loop 2310B body"), "snippet", "a snippet")

      index!(tenant.id, corpus, [item])
      [before] = chunks_of(corpus)

      result = index!(tenant.id, corpus, [item])

      assert statuses(result) == [:unchanged]
      [after_row] = chunks_of(corpus)
      assert after_row.updated_at == before.updated_at
    end

    # A metadata rewrite is a row this request wrote, so the prune must KEEP it.
    test "survives the prune of a source named complete in the same request" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      index!(tenant.id, corpus, pages("a.pdf", 3))

      kept = Enum.map(Enum.take(pages("a.pdf", 3), 2), &Map.put(&1, "snippet", "new"))
      result = index!(tenant.id, corpus, kept, source_complete: ["a.pdf"])

      assert statuses(result) == [:replaced, :replaced]
      assert result.pruned == 1
      assert length(chunks_of(corpus)) == 2
      assert Enum.all?(chunks_of(corpus), &(&1.snippet == "new"))
    end
  end

  # TC-43.2.7
  describe "a failed batch" do
    test "leaves nothing behind, names the failing item, and a corrected resubmit converges" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      batch =
        for page <- 1..10 do
          text = if page == 6, do: "OVER-LONG PAGE", else: "page #{page} body"
          chunk("a.pdf", page, text)
        end

      # The provider rejects any array containing the offending member and names no
      # member (its real behaviour). The ShrinkLadder bisect is what isolates it.
      stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, texts, _opts ->
        if Enum.any?(texts, &(&1 == "OVER-LONG PAGE")) do
          {:error, {:api_error, 400, :context_length_exceeded}}
        else
          {:ok, Enum.map(texts, fn _text -> List.duplicate(0.01, 1536) end)}
        end
      end)

      assert {:error, {:embedding_failed, _reason, failed}} =
               Indexer.index_chunks(tenant.id, corpus.id, batch, audit: audit_opts())

      # The item at fault is named — by its position in the submitted batch and by the
      # pointer the client can act on.
      assert %{index: 5, source_ref: "a.pdf", locator: %{"page" => 6}} =
               Enum.find(failed, &(&1.index == 5))

      # All-or-nothing: not one chunk and not one vector survived the failure.
      assert chunks_of(corpus) == []
      assert embedding_count(corpus) == 0

      corrected = List.replace_at(batch, 5, chunk("a.pdf", 6, "page 6 body"))
      result = index!(tenant.id, corpus, corrected)

      assert statuses(result) == List.duplicate(:inserted, 10)
      assert length(chunks_of(corpus)) == 10
      assert embedding_count(corpus) == 10
    end

    test "a truncated vector is marked in the STORED embedding hash, never in the chunk hash" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      long = String.duplicate("edi table row ", 2_000)

      stub(Loopctl.MockEmbeddingClient, :generate_embeddings, fn _scope, texts, _opts ->
        if Enum.any?(texts, &(byte_size(&1) > 16_000)) do
          {:error, {:api_error, 400, :context_length_exceeded}}
        else
          {:ok, Enum.map(texts, fn _text -> List.duplicate(0.02, 1536) end)}
        end
      end)

      index!(tenant.id, corpus, [chunk("a.pdf", 1, long)])

      [stored] = chunks_of(corpus)

      [embedding] =
        AdminRepo.all(from(e in DocumentChunkEmbedding, where: e.tenant_id == ^tenant.id))

      # The vector covers a PREFIX, so it is not comparable with whole-text vectors and
      # says so. The CHUNK hash stays the whole-text hash — it is the idempotency key's
      # input, and marking it there would make an unchanged chunk look changed forever.
      assert ShrinkLadder.truncated_hash?(embedding.embedding_content_hash)
      refute ShrinkLadder.truncated_hash?(stored.content_hash)
      assert ShrinkLadder.whole_hash(embedding.embedding_content_hash) == stored.content_hash
    end
  end

  # TC-43.2.10
  describe "an audit write failure" do
    test "fails the request, persists nothing, and is distinguishable from a validation error" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      # `actor_type` is required by `AuditLog.create_changeset/1`, so a nil one is an
      # audit write that cannot succeed — the fail-closed path, exercised end to end.
      assert {:error, :audit_write_failed} =
               Indexer.index_chunks(tenant.id, corpus.id, pages("a.pdf", 3),
                 audit: [actor_type: nil]
               )

      assert chunks_of(corpus) == []
      assert embedding_count(corpus) == 0

      # A validation error is a DIFFERENT term, so the controller can render one as a
      # 422 the caller fixes and the other as a 500 the caller retries.
      assert {:error, {:invalid_chunk, 0, _}} =
               Indexer.index_chunks(tenant.id, corpus.id, [chunk("a.pdf", 1, "   ")],
                 audit: audit_opts()
               )
    end
  end

  describe "tenant isolation" do
    test "a corpus of another tenant is not indexable and its chunks are untouched" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      corpus_b = create_corpus!(tenant_b.id)

      index!(tenant_b.id, corpus_b, pages("b.pdf", 2))

      assert {:error, :not_found} =
               Indexer.index_chunks(tenant_a.id, corpus_b.id, pages("b.pdf", 2),
                 source_complete: ["b.pdf"],
                 audit: audit_opts()
               )

      assert length(chunks_of(corpus_b)) == 2
    end
  end
end
