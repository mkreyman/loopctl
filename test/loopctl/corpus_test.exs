defmodule Loopctl.CorpusTest do
  @moduledoc """
  US-43.1 — the corpus tier's storage contract.

  Covers TC-43.1.1 (a corpus pins its OWN dimension, independent of the tenant
  pin), TC-43.1.2 (the DB CHECK holds against raw SQL), TC-43.1.3 (`dim` / `mode` /
  `embedding_model` are immutable), TC-43.1.4 (an unsupported dimension is refused
  with a message that names the supported set), TC-43.1.7 (a chunk-to-embedding
  join satisfies `Loopctl.HeavyRead`'s conjunctive tenant guard) and TC-43.1.8
  (corpus delete cascades to chunks and vectors).

  TC-43.1.5's RLS half lives in `Loopctl.CorpusRlsTest` (it needs `async: false`
  and `Repo`-connection seeding); TC-43.1.6's exclusion guard lives in
  `Loopctl.CorpusIsolationGuardTest`.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Corpus
  alias Loopctl.Corpus.Corpus, as: CorpusSchema
  alias Loopctl.Corpus.DocumentChunk
  alias Loopctl.Corpus.DocumentChunkEmbedding
  alias Loopctl.Embeddings
  alias Loopctl.HeavyRead

  setup :verify_on_exit!

  defp corpus_attrs(attrs \\ %{}) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        slug: "hcpf-edi-#{seq}",
        name: "HCPF EDI companion guides",
        mode: :server_embedded,
        embedding_model: "nomic-embed-text",
        dim: 768
      },
      attrs
    )
  end

  defp create_corpus!(tenant_id, attrs \\ %{}) do
    {:ok, corpus} = Corpus.create_corpus(tenant_id, corpus_attrs(attrs))
    corpus
  end

  defp chunk_attrs(attrs \\ %{}) do
    seq = System.unique_integer([:positive])

    Map.merge(
      %{
        source_ref: "docs/hcpf-edi/837p.pdf",
        locator: %{"page" => seq},
        text: "Loop 2310B carries the rendering provider.",
        content_hash: "sha256:#{seq}",
        ordinal: seq
      },
      attrs
    )
  end

  defp embed_chunk!(tenant_id, chunk, dim) do
    %DocumentChunkEmbedding{tenant_id: tenant_id}
    |> DocumentChunkEmbedding.changeset(
      %{document_chunk_id: chunk.id, embedding: test_vec(dim)},
      dim
    )
    |> AdminRepo.insert!()
  end

  describe "create_corpus/2" do
    test "creates a corpus with tenant_id set programmatically, never cast" do
      tenant = fixture(:tenant)
      other = fixture(:tenant)

      {:ok, corpus} =
        Corpus.create_corpus(tenant.id, corpus_attrs(%{tenant_id: other.id}))

      assert corpus.tenant_id == tenant.id
      assert corpus.mode == :server_embedded
      assert corpus.dim == 768
      assert corpus.embedding_model == "nomic-embed-text"
    end

    test "allow_snippets defaults from mode: true server-side, false client-side" do
      tenant = fixture(:tenant)

      assert create_corpus!(tenant.id, %{mode: :server_embedded}).allow_snippets == true
      assert create_corpus!(tenant.id, %{mode: :client_embedded}).allow_snippets == false
    end

    test "an explicit allow_snippets wins over the mode-derived default" do
      tenant = fixture(:tenant)

      corpus = create_corpus!(tenant.id, %{mode: :server_embedded, allow_snippets: false})
      assert corpus.allow_snippets == false
    end

    test "(tenant_id, slug) is unique, and the same slug is free in another tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      attrs = corpus_attrs()

      assert {:ok, _} = Corpus.create_corpus(tenant_a.id, attrs)
      assert {:error, changeset} = Corpus.create_corpus(tenant_a.id, attrs)
      assert %{tenant_id: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, _} = Corpus.create_corpus(tenant_b.id, attrs)
    end

    # TC-43.1.4
    test "an unsupported dimension is refused, naming the supported set and the reason" do
      tenant = fixture(:tenant)

      assert {:error, changeset} = Corpus.create_corpus(tenant.id, corpus_attrs(%{dim: 3072}))
      assert [message] = errors_on(changeset).dim

      assert message =~ inspect(Embeddings.supported_dimensions())
      assert message =~ "no pre-built"
      assert message =~ "migration"
    end
  end

  # TC-43.1.3 / AC-43.1.13
  describe "immutability of dim, mode and embedding_model" do
    setup do
      tenant = fixture(:tenant)
      %{corpus: create_corpus!(tenant.id), tenant: tenant}
    end

    test "changing dim is an ERROR on :dim, not a silent drop", %{corpus: corpus} do
      changeset = CorpusSchema.update_changeset(corpus, %{name: corpus.name, dim: 1536})

      refute changeset.valid?
      assert [message] = errors_on(changeset).dim
      assert message =~ "pinned at creation"
      refute Map.has_key?(changeset.changes, :dim)
    end

    test "changing mode is an ERROR on :mode", %{corpus: corpus} do
      changeset =
        CorpusSchema.update_changeset(corpus, %{name: corpus.name, mode: :client_embedded})

      refute changeset.valid?
      assert [_] = errors_on(changeset).mode
      refute Map.has_key?(changeset.changes, :mode)
    end

    test "changing embedding_model is an ERROR on :embedding_model", %{corpus: corpus} do
      changeset =
        CorpusSchema.update_changeset(corpus, %{
          name: corpus.name,
          embedding_model: "text-embedding-3-small"
        })

      refute changeset.valid?
      assert [_] = errors_on(changeset).embedding_model
      refute Map.has_key?(changeset.changes, :embedding_model)
    end

    test "string keys are rejected too — the shape a params map arrives in", %{corpus: corpus} do
      changeset = CorpusSchema.update_changeset(corpus, %{"name" => "x", "dim" => 1536})

      refute changeset.valid?
      assert [_] = errors_on(changeset).dim
    end

    test "restating the pinned values unchanged is not a change", %{corpus: corpus} do
      changeset =
        CorpusSchema.update_changeset(corpus, %{
          name: "renamed",
          dim: corpus.dim,
          mode: corpus.mode,
          embedding_model: corpus.embedding_model
        })

      assert changeset.valid?
    end

    test "no path in the context module can alter a corpus row at all" do
      source = File.read!(Path.expand("../../lib/loopctl/corpus.ex", __DIR__))

      for forbidden <- ["update_changeset", "AdminRepo.update", "update_all", "Repo.update"] do
        refute source =~ forbidden,
               "Loopctl.Corpus reaches #{forbidden}; AC-43.1.13 requires that NO context " <>
                 "function can alter dim, embedding_model or mode, and the context has no " <>
                 "update path at all in this story."
      end
    end
  end

  # TC-43.1.1
  describe "a corpus pins its own dimension independently of the tenant pin" do
    test "a 768 corpus coexists with a tenant pinned at 1536" do
      tenant = fixture(:tenant)
      {:ok, _} = Embeddings.set_tenant_dimension(tenant.id, 1536)
      assert Embeddings.active_dimension(tenant.id) == 1536

      corpus = create_corpus!(tenant.id, %{dim: 768, embedding_model: "nomic-embed-text"})
      assert corpus.dim == 768

      {:ok, [chunk]} = Corpus.upsert_chunks(tenant.id, corpus.id, [chunk_attrs()])
      row = embed_chunk!(tenant.id, chunk, corpus.dim)

      assert row.dim == 768
      assert stored_vector_dims(row.id) == 768

      # The tenant's ARTICLE corpus is untouched: the corpus write neither read nor
      # wrote the tenant pin.
      assert Embeddings.active_dimension(tenant.id) == 1536

      article = fixture(:article, tenant_id: tenant.id)

      assert {:ok, article_embedding} =
               Embeddings.upsert_article_embedding(
                 tenant.id,
                 article,
                 test_vec(1536),
                 "hash",
                 1536
               )

      assert article_embedding.dim == 1536
      assert Embeddings.active_dimension(tenant.id) == 1536
    end
  end

  # TC-43.1.2
  describe "the vector_dims CHECK" do
    test "a 1536-length vector tagged dim 768 is refused even via raw SQL" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id, %{dim: 768})
      {:ok, [chunk]} = Corpus.upsert_chunks(tenant.id, corpus.id, [chunk_attrs()])

      error =
        assert_raise Postgrex.Error, fn ->
          AdminRepo.query!(
            """
            INSERT INTO document_chunk_embeddings
              (id, tenant_id, document_chunk_id, dim, embedding, live_denorm,
               inserted_at, updated_at)
            VALUES (gen_random_uuid(), $1, $2, 768, $3::vector, true, NOW(), NOW())
            """,
            [
              Ecto.UUID.dump!(tenant.id),
              Ecto.UUID.dump!(chunk.id),
              Pgvector.new(Enum.map(1..1536, &(&1 / 1536)))
            ]
          )
        end

      assert error.postgres.constraint == "document_chunk_embeddings_dim_matches_vector"
    end

    test "the changeset refuses the same mismatch legibly" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id, %{dim: 768})
      {:ok, [chunk]} = Corpus.upsert_chunks(tenant.id, corpus.id, [chunk_attrs()])

      changeset =
        DocumentChunkEmbedding.changeset(
          %DocumentChunkEmbedding{tenant_id: tenant.id},
          %{document_chunk_id: chunk.id, embedding: test_vec(1536)},
          768
        )

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :embedding)
    end
  end

  describe "upsert_chunks/3" do
    test "is idempotent on (corpus_id, source_ref, locator) and REPLACES a moved chunk" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      attrs = chunk_attrs(%{text: "first", content_hash: "sha256:one"})

      {:ok, [first]} = Corpus.upsert_chunks(tenant.id, corpus.id, [attrs])

      {:ok, [second]} =
        Corpus.upsert_chunks(tenant.id, corpus.id, [
          %{attrs | text: "second", content_hash: "sha256:two"}
        ])

      assert second.id == first.id
      assert second.text == "second"
      assert second.content_hash == "sha256:two"
      assert chunk_count(corpus.id) == 1
    end

    test "stores the locator verbatim, without normalising it" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      locator = %{"loop" => "2310B", "segment" => "NM1", "occurrence" => 2}

      {:ok, [chunk]} =
        Corpus.upsert_chunks(tenant.id, corpus.id, [chunk_attrs(%{locator: locator})])

      assert AdminRepo.get!(DocumentChunk, chunk.id).locator == locator
    end

    test "a mode B chunk stores a NULL text" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id, %{mode: :client_embedded})

      {:ok, [chunk]} =
        Corpus.upsert_chunks(tenant.id, corpus.id, [chunk_attrs(%{text: nil, snippet: nil})])

      assert chunk.text == nil
      assert chunk.snippet == nil
    end

    test "an invalid chunk fails the whole batch, naming its index" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      assert {:error, {:invalid_chunk, 1, changeset}} =
               Corpus.upsert_chunks(tenant.id, corpus.id, [
                 chunk_attrs(),
                 chunk_attrs(%{content_hash: nil})
               ])

      assert Map.has_key?(errors_on(changeset), :content_hash)
      assert chunk_count(corpus.id) == 0
    end

    test "two chunks sharing a key in one batch are refused rather than silently merged" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      attrs = chunk_attrs()

      assert {:error, {:duplicate_chunk_key, _}} =
               Corpus.upsert_chunks(tenant.id, corpus.id, [attrs, attrs])
    end

    test "another tenant's corpus is not found" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      corpus = create_corpus!(tenant_a.id)

      assert {:error, :not_found} = Corpus.upsert_chunks(tenant_b.id, corpus.id, [chunk_attrs()])
    end
  end

  describe "get_corpus/2, list_corpora/2 and delete_chunks_for_source/3" do
    test "get_corpus/2 resolves by id or slug and is tenant scoped" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      corpus = create_corpus!(tenant_a.id)

      assert {:ok, %{id: id}} = Corpus.get_corpus(tenant_a.id, corpus.id)
      assert id == corpus.id
      assert {:ok, %{id: ^id}} = Corpus.get_corpus(tenant_a.id, corpus.slug)
      assert {:error, :not_found} = Corpus.get_corpus(tenant_b.id, corpus.id)
      assert {:error, :not_found} = Corpus.get_corpus(tenant_b.id, corpus.slug)
    end

    test "list_corpora/2 returns only the tenant's own rows" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      mine = create_corpus!(tenant_a.id)
      _theirs = create_corpus!(tenant_b.id)

      assert Enum.map(Corpus.list_corpora(tenant_a.id), & &1.id) == [mine.id]
    end

    test "list_corpora/2 filters by project scope" do
      tenant = fixture(:tenant)
      project = fixture(:project, tenant_id: tenant.id)
      scoped = create_corpus!(tenant.id, %{project_id: project.id})
      _unscoped = create_corpus!(tenant.id)

      assert Enum.map(Corpus.list_corpora(tenant.id, project_id: project.id), & &1.id) ==
               [scoped.id]
    end

    test "delete_chunks_for_source/3 removes one source's chunks and leaves the rest" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      {:ok, _} =
        Corpus.upsert_chunks(tenant.id, corpus.id, [
          chunk_attrs(%{source_ref: "a.pdf"}),
          chunk_attrs(%{source_ref: "a.pdf"}),
          chunk_attrs(%{source_ref: "b.pdf"})
        ])

      assert {:ok, 2} = Corpus.delete_chunks_for_source(tenant.id, corpus.id, "a.pdf")
      assert chunk_count(corpus.id) == 1
    end

    test "delete_chunks_for_source/3 cannot reach another tenant's corpus" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      corpus = create_corpus!(tenant_a.id)
      {:ok, _} = Corpus.upsert_chunks(tenant_a.id, corpus.id, [chunk_attrs()])

      assert {:error, :not_found} =
               Corpus.delete_chunks_for_source(tenant_b.id, corpus.id, "docs/hcpf-edi/837p.pdf")

      assert chunk_count(corpus.id) == 1
    end
  end

  # TC-43.1.8 / AC-43.1.9
  describe "delete_corpus/2" do
    test "cascades to chunks and their embeddings, leaving no orphans" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id, %{dim: 768})

      {:ok, chunks} =
        Corpus.upsert_chunks(
          tenant.id,
          corpus.id,
          Enum.map(1..3, fn i -> chunk_attrs(%{locator: %{"page" => i}}) end)
        )

      Enum.each(chunks, &embed_chunk!(tenant.id, &1, 768))

      assert chunk_count(corpus.id) == 3
      assert embedding_count(tenant.id) == 3

      assert {:ok, _} = Corpus.delete_corpus(tenant.id, corpus.id)

      assert chunk_count(corpus.id) == 0
      assert embedding_count(tenant.id) == 0
    end

    test "another tenant cannot delete it" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      corpus = create_corpus!(tenant_a.id)

      assert {:error, :not_found} = Corpus.delete_corpus(tenant_b.id, corpus.id)
      assert {:ok, _} = Corpus.get_corpus(tenant_a.id, corpus.id)
    end
  end

  # TC-43.1.7 / AC-43.1.7
  describe "the heavy-read tenant guard on a chunk-to-embedding join" do
    test "accepts the join scoped on BOTH sources and refuses the from-only variant" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id, %{dim: 768})
      {:ok, [chunk]} = Corpus.upsert_chunks(tenant.id, corpus.id, [chunk_attrs()])
      embed_chunk!(tenant.id, chunk, 768)

      scoped =
        from(c in DocumentChunk,
          join: e in DocumentChunkEmbedding,
          on: e.document_chunk_id == c.id and e.tenant_id == ^tenant.id,
          where: c.tenant_id == ^tenant.id and c.corpus_id == ^corpus.id and e.dim == 768,
          select: %{chunk_id: c.id, dim: e.dim}
        )

      assert [%{chunk_id: chunk_id, dim: 768}] = HeavyRead.all(tenant.id, scoped)
      assert chunk_id == chunk.id

      from_only =
        from(c in DocumentChunk,
          join: e in DocumentChunkEmbedding,
          on: e.document_chunk_id == c.id,
          where: c.tenant_id == ^tenant.id,
          select: %{chunk_id: c.id}
        )

      assert_raise ArgumentError, ~r/not fully scoped to the given tenant/, fn ->
        HeavyRead.all(tenant.id, from_only)
      end
    end
  end

  defp stored_vector_dims(embedding_id) do
    %{rows: [[dims]]} =
      AdminRepo.query!(
        "SELECT vector_dims(embedding) FROM document_chunk_embeddings WHERE id = $1",
        [Ecto.UUID.dump!(embedding_id)]
      )

    dims
  end

  defp chunk_count(corpus_id) do
    AdminRepo.aggregate(from(c in DocumentChunk, where: c.corpus_id == ^corpus_id), :count)
  end

  defp embedding_count(tenant_id) do
    AdminRepo.aggregate(
      from(e in DocumentChunkEmbedding, where: e.tenant_id == ^tenant_id),
      :count
    )
  end
end
