defmodule Loopctl.CorpusRlsTest do
  @moduledoc """
  US-43.1 AC-43.1.6 / TC-43.1.5 — the RLS half of the corpus tier's isolation.

  `Loopctl.Corpus` runs its OLTP on `Loopctl.AdminRepo` (BYPASSRLS), where the
  explicit `tenant_id` predicate is the only isolation — asserted in
  `Loopctl.CorpusTest`. The `tenant_isolation` POLICIES the `enable_rls/1` macro
  created on `corpora`, `document_chunks` and `document_chunk_embeddings` are what
  a hypothetical `Loopctl.Repo` caller would be held to, and that is what this file
  asserts.

  ## Why `async: false` + `Repo`-connection seeding

  `Repo.with_tenant/2` runs inside an RLS transaction with
  `SET LOCAL ROLE loopctl_app`, so it needs shared sandbox mode and rows on the
  SAME connection. Every row here is therefore seeded through `Repo`, NOT the
  AdminRepo-backed `fixture/2` — mirroring `test/loopctl/embeddings_rls_test.exs`.
  Because the assertion runs under the NON-owner app role (RLS is ENABLE, not
  FORCE), it proves isolation instead of silently passing as the table owner.
  """

  use Loopctl.DataCase, async: false

  alias Loopctl.Corpus.Corpus, as: CorpusSchema
  alias Loopctl.Corpus.DocumentChunk
  alias Loopctl.Corpus.DocumentChunkEmbedding
  alias Loopctl.Tenants.Tenant

  setup :verify_on_exit!

  defp repo_tenant do
    seq = System.unique_integer([:positive])

    %Tenant{}
    |> Tenant.create_changeset(%{
      name: "US-43.1 tenant #{seq}",
      slug: "us431-tenant-#{seq}",
      email: "us431-#{seq}@example.com",
      status: :active
    })
    |> Repo.insert!()
  end

  defp repo_corpus(tenant_id) do
    seq = System.unique_integer([:positive])

    %CorpusSchema{tenant_id: tenant_id}
    |> CorpusSchema.create_changeset(%{
      slug: "us431-corpus-#{seq}",
      name: "US-43.1 corpus #{seq}",
      mode: :server_embedded,
      embedding_model: "nomic-embed-text",
      dim: 768
    })
    |> Repo.insert!()
  end

  defp repo_chunk(tenant_id, corpus) do
    seq = System.unique_integer([:positive])

    %DocumentChunk{tenant_id: tenant_id}
    |> DocumentChunk.changeset(%{
      corpus_id: corpus.id,
      source_ref: "docs/us431-#{seq}.pdf",
      locator: %{"page" => seq},
      text: "chunk #{seq}",
      content_hash: "sha256:#{seq}"
    })
    |> Repo.insert!()
  end

  defp repo_embedding(tenant_id, chunk) do
    %DocumentChunkEmbedding{tenant_id: tenant_id}
    |> DocumentChunkEmbedding.changeset(
      %{document_chunk_id: chunk.id, embedding: test_vec(768)},
      768
    )
    |> Repo.insert!()
  end

  defp ids_under(tenant_id, schema) do
    {:ok, ids} =
      Repo.with_tenant(tenant_id, fn -> schema |> Repo.all() |> Enum.map(& &1.id) end)

    ids
  end

  describe "RLS on the three corpus-tier tables (TC-43.1.5)" do
    setup do
      tenant_a = repo_tenant()
      tenant_b = repo_tenant()

      corpus_a = repo_corpus(tenant_a.id)
      corpus_b = repo_corpus(tenant_b.id)

      chunk_a = repo_chunk(tenant_a.id, corpus_a)
      chunk_b = repo_chunk(tenant_b.id, corpus_b)

      %{
        tenant_a: tenant_a,
        tenant_b: tenant_b,
        corpus_a: corpus_a,
        corpus_b: corpus_b,
        chunk_a: chunk_a,
        chunk_b: chunk_b,
        embedding_a: repo_embedding(tenant_a.id, chunk_a),
        embedding_b: repo_embedding(tenant_b.id, chunk_b)
      }
    end

    test "tenant A cannot see tenant B's corpora", ctx do
      assert ids_under(ctx.tenant_a.id, CorpusSchema) == [ctx.corpus_a.id]
      assert ids_under(ctx.tenant_b.id, CorpusSchema) == [ctx.corpus_b.id]
    end

    test "tenant A cannot see tenant B's document_chunks", ctx do
      assert ids_under(ctx.tenant_a.id, DocumentChunk) == [ctx.chunk_a.id]
      assert ids_under(ctx.tenant_b.id, DocumentChunk) == [ctx.chunk_b.id]
    end

    test "tenant A cannot see tenant B's document_chunk_embeddings", ctx do
      assert ids_under(ctx.tenant_a.id, DocumentChunkEmbedding) == [ctx.embedding_a.id]
      assert ids_under(ctx.tenant_b.id, DocumentChunkEmbedding) == [ctx.embedding_b.id]
    end
  end
end
