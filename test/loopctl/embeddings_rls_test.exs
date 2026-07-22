defmodule Loopctl.EmbeddingsRlsTest do
  @moduledoc """
  US-41.1 AC-41.1.6 / TC-41.1.5, the RLS half.

  `Loopctl.Embeddings`' isolation has to hold on BOTH paths, and they are
  different mechanisms:

    * on `Loopctl.HeavyRead` (BYPASSRLS) the ONLY thing isolating tenants is the
      structural `guard!/2` predicate — asserted in `Loopctl.EmbeddingsTest`;
    * on `Loopctl.Repo` it is the `tenant_isolation` RLS POLICY the
      `enable_rls/1` macro created on the new side tables — asserted here.

  ## Why `async: false` + `Repo`-connection seeding

  `Repo.with_tenant/2` runs inside an RLS transaction with
  `SET LOCAL ROLE loopctl_app`, so it needs shared sandbox mode and rows on the
  SAME connection. The tenants/articles/embedding rows are therefore seeded via
  `Repo` (NOT the AdminRepo-backed `fixture/2`), mirroring
  `context_retriever/executor_test.exs`. Because the assertion runs under the
  NON-owner app role (RLS is ENABLE, not FORCE), it actually proves isolation
  instead of silently passing as the table owner.
  """

  use Loopctl.DataCase, async: false

  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Tenants.Tenant

  setup :verify_on_exit!

  defp repo_tenant do
    seq = System.unique_integer([:positive])

    %Tenant{}
    |> Tenant.create_changeset(%{
      name: "US-41.1 tenant #{seq}",
      slug: "us411-tenant-#{seq}",
      email: "us411-#{seq}@example.com",
      status: :active
    })
    |> Repo.insert!()
  end

  defp repo_article(tenant_id) do
    seq = System.unique_integer([:positive])

    %Article{tenant_id: tenant_id}
    |> Article.create_changeset(%{
      title: "US-41.1 article #{seq}",
      body: "body #{seq}",
      category: :reference,
      status: :published
    })
    |> Repo.insert!()
  end

  defp repo_embedding(tenant_id, article, dim) do
    %ArticleEmbedding{tenant_id: tenant_id}
    |> ArticleEmbedding.changeset(
      %{article_id: article.id, embedding: Enum.map(1..dim, &(&1 / dim))},
      dim
    )
    |> Repo.insert!()
  end

  describe "RLS on the embedding side tables (TC-41.1.5)" do
    test "tenant A cannot see tenant B's article_embeddings rows" do
      tenant_a = repo_tenant()
      tenant_b = repo_tenant()

      row_a = repo_embedding(tenant_a.id, repo_article(tenant_a.id), 1536)
      row_b = repo_embedding(tenant_b.id, repo_article(tenant_b.id), 1536)

      assert {:ok, [row_a.id]} ==
               Repo.with_tenant(tenant_a.id, fn ->
                 ArticleEmbedding |> Repo.all() |> Enum.map(& &1.id)
               end)

      assert {:ok, [row_b.id]} ==
               Repo.with_tenant(tenant_b.id, fn ->
                 ArticleEmbedding |> Repo.all() |> Enum.map(& &1.id)
               end)
    end

    test "a wrong-length vector is refused by the DB CHECK even outside the changeset" do
      # Defence in depth for AC-41.1.4: the changeset validation is the legible
      # error, but the `vector_dims(embedding) = dim` CHECK means a raw write
      # cannot silently store a mismatched vector either.
      tenant = repo_tenant()
      article = repo_article(tenant.id)

      assert_raise Postgrex.Error, ~r/article_embeddings_dim_matches_vector/, fn ->
        Repo.query!(
          """
          INSERT INTO article_embeddings
            (id, tenant_id, article_id, dim, embedding, live_denorm, inserted_at, updated_at)
          VALUES (gen_random_uuid(), $1, $2, 768, $3::vector, true, NOW(), NOW())
          """,
          [
            Ecto.UUID.dump!(tenant.id),
            Ecto.UUID.dump!(article.id),
            Pgvector.new(Enum.map(1..1536, &(&1 / 1536)))
          ]
        )
      end
    end
  end
end
