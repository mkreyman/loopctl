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

      # The collision is attributed to `:slug`, NOT to `:tenant_id` — the index's first field,
      # and one the caller never sends. `error_key:` is what holds that.
      assert %{slug: ["has already been taken for this tenant"]} = errors_on(changeset)
      refute Map.has_key?(errors_on(changeset), :tenant_id)

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

    test "a project_id belonging to ANOTHER tenant is refused, persisting no row" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      theirs = fixture(:project, tenant_id: tenant_b.id)

      assert {:error, changeset} =
               Corpus.create_corpus(tenant_a.id, corpus_attrs(%{project_id: theirs.id}))

      assert %{project_id: ["is invalid or does not belong to this tenant"]} =
               errors_on(changeset)

      assert Corpus.list_corpora(tenant_a.id) == []
      assert Corpus.list_corpora(tenant_a.id, project_id: theirs.id) == []
    end

    test "a NONEXISTENT project_id is indistinguishable from a foreign one" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      theirs = fixture(:project, tenant_id: tenant_b.id)

      assert {:error, foreign} =
               Corpus.create_corpus(tenant_a.id, corpus_attrs(%{project_id: theirs.id}))

      assert {:error, absent} =
               Corpus.create_corpus(
                 tenant_a.id,
                 corpus_attrs(%{project_id: Ecto.UUID.generate()})
               )

      assert errors_on(foreign).project_id == errors_on(absent).project_id,
             "the two must not be distinguishable — that is the cross-tenant existence oracle"
    end

    test "a malformed project_id is a changeset error, never a raise" do
      tenant = fixture(:tenant)

      for value <- ["not-a-uuid", 42] do
        assert {:error, changeset} =
                 Corpus.create_corpus(tenant.id, corpus_attrs(%{project_id: value}))

        assert Map.has_key?(errors_on(changeset), :project_id)
      end
    end

    test "the tenant's own project_id is accepted and scopes the corpus" do
      tenant = fixture(:tenant)
      project = fixture(:project, tenant_id: tenant.id)

      assert {:ok, corpus} =
               Corpus.create_corpus(tenant.id, corpus_attrs(%{project_id: project.id}))

      assert corpus.project_id == project.id
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

    # TC-43.3.7 — BOTH directions. A mode A corpus can never become mode B and a mode B
    # corpus can never become mode A: mode decides whether the server holds text at all,
    # so a flip would leave every stored chunk in the wrong shape with no repair. The
    # error names the supported path.
    test "changing mode is an ERROR on :mode in BOTH directions", %{
      corpus: corpus,
      tenant: tenant
    } do
      changeset =
        CorpusSchema.update_changeset(corpus, %{name: corpus.name, mode: :client_embedded})

      refute changeset.valid?
      assert [message] = errors_on(changeset).mode
      assert message =~ "pinned at creation"
      assert message =~ "delete-and-re-index"
      refute Map.has_key?(changeset.changes, :mode)

      mode_b = create_corpus!(tenant.id, %{mode: :client_embedded})

      reverse =
        CorpusSchema.update_changeset(mode_b, %{name: mode_b.name, mode: :server_embedded})

      refute reverse.valid?
      assert [reverse_message] = errors_on(reverse).mode
      assert reverse_message =~ "delete-and-re-index"
      refute Map.has_key?(reverse.changes, :mode)
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

    test "project_id is not castable on update — ownership is the context's to check",
         %{corpus: corpus, tenant: tenant} do
      other = fixture(:tenant)
      theirs = fixture(:project, tenant_id: other.id)
      mine = fixture(:project, tenant_id: tenant.id)

      for project <- [theirs, mine] do
        changeset =
          CorpusSchema.update_changeset(corpus, %{name: corpus.name, project_id: project.id})

        assert changeset.valid?
        refute Map.has_key?(changeset.changes, :project_id)
      end
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

    test "a second embedding for the same chunk and dim is attributed to the chunk, not tenant_id" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id, %{dim: 768})
      {:ok, [chunk]} = Corpus.upsert_chunks(tenant.id, corpus.id, [chunk_attrs()])
      embed_chunk!(tenant.id, chunk, 768)

      assert {:error, changeset} =
               %DocumentChunkEmbedding{tenant_id: tenant.id}
               |> DocumentChunkEmbedding.changeset(
                 %{document_chunk_id: chunk.id, embedding: test_vec(768)},
                 768
               )
               |> AdminRepo.insert()

      # `:tenant_id` is never cast and `:dim` is forced from the corpus — neither is a field the
      # caller could act on, so the index's first field is the wrong place for this error.
      assert %{document_chunk_id: ["already has an embedding at this dimension"]} =
               errors_on(changeset)

      refute Map.has_key?(errors_on(changeset), :tenant_id)
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

    test "a duplicate key reaching the index is attributed to source_ref, not corpus_id" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      attrs = chunk_attrs(%{locator: %{"page" => 7}})

      {:ok, [_]} = Corpus.upsert_chunks(tenant.id, corpus.id, [attrs])

      # The upsert's ON CONFLICT masks this today; US-43.2 surfaces the changeset directly.
      # `:corpus_id` is the index's first field but `upsert_chunks/3` overrides it server-side,
      # so the caller cannot act on it.
      assert {:error, changeset} =
               %DocumentChunk{tenant_id: tenant.id}
               |> DocumentChunk.changeset(Map.put(attrs, :corpus_id, corpus.id))
               |> AdminRepo.insert()

      assert %{source_ref: ["has already been taken for this locator in this corpus"]} =
               errors_on(changeset)

      refute Map.has_key?(errors_on(changeset), :corpus_id)
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

    test "locators that are DISTINCT terms but EQUAL as jsonb are refused, not raised" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      # Each pair reaches ONE row of the (corpus_id, source_ref, locator) unique
      # index, where Postgres raises cardinality_violation out of ON CONFLICT DO
      # UPDATE. The guard must name it instead: jsonb renders keys as strings and
      # compares numbers numerically.
      pairs = [
        {%{page: 1}, %{"page" => 1}},
        {%{"page" => 1}, %{"page" => 1.0}},
        {%{"page" => 1, "line" => 2}, %{"line" => 2, "page" => 1}},
        {%{"path" => ["a", 1]}, %{"path" => ["a", 1.0]}},
        # VALUES, not just keys: the jsonb encoder renders an atom and a struct as
        # STRINGS, so each of these pairs is one jsonb value and one row.
        {%{"kind" => :page}, %{"kind" => "page"}},
        {%{"on" => ~D[2026-01-01]}, %{"on" => "2026-01-01"}},
        {%{"path" => [:a, "b"]}, %{"path" => ["a", "b"]}},
        {:page, "page"}
      ]

      for {left, right} <- pairs do
        chunks = [
          chunk_attrs(%{source_ref: "same.pdf", locator: left}),
          chunk_attrs(%{source_ref: "same.pdf", locator: right})
        ]

        assert {:error, {:duplicate_chunk_key, {"same.pdf", _}}} =
                 Corpus.upsert_chunks(tenant.id, corpus.id, chunks),
               "#{inspect(left)} and #{inspect(right)} are one jsonb key"
      end

      assert chunk_count(corpus.id) == 0
    end

    test "locators that differ as jsonb are both written" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      chunks = [
        chunk_attrs(%{source_ref: "same.pdf", locator: %{"page" => 1}}),
        chunk_attrs(%{source_ref: "same.pdf", locator: %{"page" => 1.5}}),
        chunk_attrs(%{source_ref: "same.pdf", locator: %{"page" => "1"}}),
        chunk_attrs(%{source_ref: "other.pdf", locator: %{"page" => 1}})
      ]

      assert {:ok, written} = Corpus.upsert_chunks(tenant.id, corpus.id, chunks)
      assert length(written) == 4
    end

    test "a locator may be ANY jsonb value — an array or a scalar, not only an object" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      # AC-43.1.2 gives the shape to the client ("loopctl only stores and returns
      # it") and the column is plain jsonb. `field :locator, :map` refused a heading
      # path (the AC's own third example) and a bare page number on the way IN, and
      # could not LOAD either on the way out.
      locators = [
        ["Chapter 1", "Section 2"],
        7,
        "page-7",
        true,
        %{"path" => ["a", "b"]}
      ]

      for locator <- locators do
        assert {:ok, [chunk]} =
                 Corpus.upsert_chunks(tenant.id, corpus.id, [chunk_attrs(%{locator: locator})])

        assert chunk.locator == locator
        assert AdminRepo.get!(DocumentChunk, chunk.id).locator == locator
      end

      assert chunk_count(corpus.id) == length(locators)
    end

    test "an array locator is the idempotency key it claims to be" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)
      attrs = chunk_attrs(%{locator: ["Chapter 1", "Section 2"], content_hash: "sha256:one"})

      {:ok, [first]} = Corpus.upsert_chunks(tenant.id, corpus.id, [attrs])
      {:ok, [second]} = Corpus.upsert_chunks(tenant.id, corpus.id, [%{attrs | text: "moved"}])

      assert second.id == first.id
      assert chunk_count(corpus.id) == 1
    end

    test "a locator the jsonb encoder cannot render is a changeset error, never a raise" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      assert {:error, {:invalid_chunk, 0, changeset}} =
               Corpus.upsert_chunks(tenant.id, corpus.id, [
                 chunk_attrs(%{locator: %{"span" => {1, 2}}})
               ])

      assert Map.has_key?(errors_on(changeset), :locator)
      assert chunk_count(corpus.id) == 0
    end

    test "a locator whose keys collide as jsonb strings is refused, not silently truncated" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id)

      # `'{"a":1,"a":2}'::jsonb` is `{"a": 2}` — Postgres keeps the LAST duplicate
      # key, so this locator has no faithful stored form and the term-comparing
      # duplicate guard cannot see the collision either.
      for locator <- [%{:page => 1, "page" => 2}, %{"loc" => %{:page => 1, "page" => 2}}] do
        assert {:error, {:invalid_chunk, 0, changeset}} =
                 Corpus.upsert_chunks(tenant.id, corpus.id, [chunk_attrs(%{locator: locator})])

        assert [message] = errors_on(changeset).locator
        assert message =~ "collide"
      end

      assert chunk_count(corpus.id) == 0
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

    test "a UUID-shaped slug is still reachable — and still deletable — by slug" do
      tenant = fixture(:tenant)

      # The slug format validator accepts both: a canonical lowercase UUID is
      # lowercase hex plus hyphens, and any 16-BYTE string is a raw UUID to
      # `Ecto.UUID.cast/1`. An id-only resolver made either corpus unreachable on
      # every verb, including the one that would remove it.
      for slug <- [Ecto.UUID.generate(), "abcdefghijklmnop"] do
        corpus = create_corpus!(tenant.id, %{slug: slug})

        assert {:ok, %{id: id}} = Corpus.get_corpus(tenant.id, slug)
        assert id == corpus.id

        assert {:ok, _} = Corpus.upsert_chunks(tenant.id, slug, [chunk_attrs()])

        assert {:ok, 1} =
                 Corpus.delete_chunks_for_source(tenant.id, slug, "docs/hcpf-edi/837p.pdf")

        assert {:ok, _} = Corpus.delete_corpus(tenant.id, slug)
        assert {:error, :not_found} = Corpus.get_corpus(tenant.id, slug)
      end
    end

    test "a slug that is already another corpus's id in this tenant is refused at creation" do
      tenant = fixture(:tenant)
      other = create_corpus!(tenant.id)

      # `get_corpus/2` resolves an id BEFORE a slug, so this corpus would be
      # addressable by nobody and `delete_corpus/2` would destroy the OTHER row —
      # with its chunks and vectors — for a caller that named its own slug.
      assert {:error, changeset} =
               Corpus.create_corpus(tenant.id, corpus_attrs(%{slug: other.id}))

      assert [message] = errors_on(changeset).slug
      assert message =~ "id of another corpus"

      # Scoped to the tenant, and the UUID-shaped-slug support itself is untouched.
      assert {:ok, _} =
               Corpus.create_corpus(fixture(:tenant).id, corpus_attrs(%{slug: other.id}))
    end

    test "a UUID-shaped slug of ANOTHER tenant stays not_found" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      slug = Ecto.UUID.generate()
      _theirs = create_corpus!(tenant_b.id, %{slug: slug})

      assert {:error, :not_found} = Corpus.get_corpus(tenant_a.id, slug)
    end

    test "list_corpora/2 returns no rows for a malformed project_id rather than raising" do
      tenant = fixture(:tenant)
      _corpus = create_corpus!(tenant.id)

      # A caller-supplied value lands on a `:binary_id` column, where a non-UUID
      # raises `Ecto.Query.CastError` — a 500 out of a function whose @spec promises
      # a list. `Projects.get_project/2` carries the same guard.
      assert Corpus.list_corpora(tenant.id, project_id: "not-a-uuid") == []
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

    test "list_corpora/2 sanitises BOTH pagination opts, not just :limit" do
      tenant = fixture(:tenant)
      mine = create_corpus!(tenant.id)

      # Postgres refuses a negative OFFSET, so an unsanitised one raises where the
      # @spec declares a list. :limit was already clamped; :offset was not.
      assert Enum.map(Corpus.list_corpora(tenant.id, limit: 5, offset: -1), & &1.id) == [mine.id]
      assert Corpus.list_corpora(tenant.id, offset: "3") == [mine]
      assert Corpus.list_corpora(tenant.id, offset: 1) == []
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

  # AC-43.2.7 — EVERY mutating verb on this surface audits, inside the mutation's own
  # transaction. Delete is the one that is both set-based and irreversible, so it is the
  # one whose absence from the trail would matter most.
  describe "the audit entry of create_corpus/3 and delete_corpus/3" do
    test "create records corpus_created with the caller's actor context" do
      tenant = fixture(:tenant)

      {:ok, corpus} =
        Corpus.create_corpus(
          tenant.id,
          corpus_attrs(),
          actor_type: "api_key",
          actor_id: nil,
          actor_label: "agent:test"
        )

      entry = only_audit_entry!(tenant.id, "corpus_created")

      assert entry.entity_type == "corpus"
      assert entry.entity_id == corpus.id
      assert entry.actor_label == "agent:test"
      assert entry.new_state["slug"] == corpus.slug
      assert entry.new_state["dim"] == corpus.dim
    end

    test "delete records corpus_deleted with the state that went" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id, %{dim: 768})

      {:ok, _} =
        Corpus.delete_corpus(tenant.id, corpus.id,
          actor_type: "api_key",
          actor_label: "user:operator"
        )

      entry = only_audit_entry!(tenant.id, "corpus_deleted")

      assert entry.entity_id == corpus.id
      assert entry.actor_label == "user:operator"
      assert entry.old_state["slug"] == corpus.slug
    end

    # Fail-closed, and the SAME shape the index path already has: `actor_type` is
    # required by `AuditLog.create_changeset/1`, so a nil one is an audit write that
    # cannot succeed. The mutation must go with it.
    test "an audit write that cannot succeed rolls the create back" do
      tenant = fixture(:tenant)

      assert {:error, :audit_write_failed} =
               Corpus.create_corpus(tenant.id, corpus_attrs(), actor_type: nil)

      assert Corpus.list_corpora(tenant.id) == []
    end

    test "an audit write that cannot succeed rolls the delete back, chunks and all" do
      tenant = fixture(:tenant)
      corpus = create_corpus!(tenant.id, %{dim: 768})

      {:ok, chunks} =
        Corpus.upsert_chunks(tenant.id, corpus.id, [chunk_attrs(%{locator: %{"page" => 1}})])

      Enum.each(chunks, &embed_chunk!(tenant.id, &1, 768))

      assert {:error, :audit_write_failed} =
               Corpus.delete_corpus(tenant.id, corpus.id, actor_type: nil)

      assert {:ok, _} = Corpus.get_corpus(tenant.id, corpus.id)
      assert chunk_count(corpus.id) == 1
      assert embedding_count(tenant.id) == 1
    end

    # A validation failure is still a CHANGESET, never the audit term — the controller
    # renders one as a 422 the caller fixes and the other as a 500 it retries.
    test "a validation failure is still reported as a changeset" do
      tenant = fixture(:tenant)

      assert {:error, %Ecto.Changeset{}} =
               Corpus.create_corpus(tenant.id, corpus_attrs(%{dim: 7}), actor_type: "api_key")
    end
  end

  defp only_audit_entry!(tenant_id, action) do
    [entry] =
      AdminRepo.all(
        from(a in Loopctl.Audit.AuditLog,
          where: a.tenant_id == ^tenant_id and a.action == ^action
        )
      )

    entry
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

  describe "cascade-path indexes" do
    test "every new FK has an index LEADING with its referencing column" do
      # Postgres's RI cascade issues `DELETE FROM <child> WHERE <fk> = $1` with no
      # tenant predicate, so a btree leading with `tenant_id` cannot serve it. This
      # is the defect `20260721090000` fixed on `article_embeddings`; the corpus
      # tier copied that table's create migration and not its corrective index.
      for {table, column} <- [
            {"document_chunk_embeddings", "document_chunk_id"},
            {"document_chunks", "tenant_id"},
            {"corpora", "project_id"}
          ] do
        assert leading_index?(table, column),
               "#{table}.#{column} has no valid index leading with it, so its cascade seq-scans"
      end
    end
  end

  # `indkey[0]` is the index's FIRST key column (int2vector, 0-based). `indisvalid`
  # matters because a failed CONCURRENTLY build leaves an INVALID index behind that
  # `pg_indexes` still renders and the planner never uses.
  defp leading_index?(table, column) do
    %{rows: [[count]]} =
      AdminRepo.query!(
        """
        SELECT count(*)
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = i.indkey[0]
        WHERE c.relname = $1 AND a.attname = $2 AND i.indisvalid
        """,
        [table, column]
      )

    count > 0
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
