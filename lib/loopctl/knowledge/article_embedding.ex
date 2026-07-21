defmodule Loopctl.Knowledge.ArticleEmbedding do
  @moduledoc """
  US-41.1 — a DIMENSION-TAGGED article embedding row.

  The vector no longer lives in the fixed-width `articles.embedding vector(1536)`
  column but here, in an UNCONSTRAINED `vector` column paired with an explicit
  `dim` discriminator, so a tenant may run a 768/1024/3072-dimension model on the
  shared hosted instance (AC-41.1.1).

  ## Invariants owned by the DATABASE, not this module

    * `live_denorm` — mirrors `articles.status <> 'superseded'`, synced by the
      `article_embeddings_live_denorm_trg` / `articles_live_denorm_propagate_trg`
      PL/pgSQL trigger pair. `put_live_denorm/2` here is a CONVENIENCE only; the
      trigger is the enforcing mechanism because `update_all`, raw SQL and
      migration backfills bypass every changeset (TC-41.1.6).
    * `vector_dims(embedding) = dim` — a CHECK constraint, so a wrong-length
      vector cannot be stored even if it bypasses `changeset/2`.

  ## `tenant_id` on a SYSTEM-scoped article (AC-41.1.7)

  System-scoped articles (`articles.tenant_id IS NULL`, `scope: :system`) are read
  by every tenant. Their embeddings are materialized ON DEMAND PER TENANT with the
  REQUESTING tenant's own BYO credential and stored as ordinary rows here carrying
  THAT tenant's `tenant_id`. A NULL `tenant_id` was rejected: it can never satisfy
  the conjunctive `x.tenant_id == ^tenant_id` predicate `Loopctl.HeavyRead`'s
  `guard!/2` requires of every BYPASSRLS read, and the only "fix" would be to
  weaken that guard for the whole product.
  """

  use Loopctl.Schema

  import Ecto.Changeset

  alias Loopctl.Embeddings.Dimensions
  alias Loopctl.Knowledge.Article

  @type t :: %__MODULE__{}

  schema "article_embeddings" do
    tenant_field()

    field :dim, :integer
    field :embedding, Pgvector.Ecto.Vector
    field :live_denorm, :boolean, default: true
    field :embedding_content_hash, :string

    belongs_to :article, Article

    timestamps()
  end

  @doc """
  Changeset for an embedding row.

  `tenant_id` is NEVER cast — it is set programmatically by
  `Loopctl.Embeddings.upsert_article_embedding/4`, which knows whether the row is
  a tenant article's own vector or a per-tenant materialization of a system
  article.

  `expected_dimension` is passed IN by the caller (AC-41.1.11) — resolved ONCE per
  operation or batch — so this validator stays PURE: no `Repo` read, no process
  dictionary, no `Application.get_env` fallback that could disagree with the
  tenant's recorded dimension.
  """
  @spec changeset(t(), map(), pos_integer()) :: Ecto.Changeset.t()
  def changeset(embedding_row, attrs, expected_dimension) when is_integer(expected_dimension) do
    embedding_row
    |> cast(attrs, [:article_id, :dim, :embedding, :embedding_content_hash])
    |> put_change(:dim, expected_dimension)
    |> validate_required([:article_id, :dim, :embedding])
    |> Dimensions.validate_vector_length(:embedding, expected_dimension)
    |> foreign_key_constraint(:article_id)
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint([:tenant_id, :article_id, :dim],
      name: :article_embeddings_tenant_article_dim_index
    )
    |> check_constraint(:embedding,
      name: :article_embeddings_dim_matches_vector,
      message: "vector length must equal dim"
    )
  end

  @doc """
  The live-row predicate for an article, derived from its status.

  Articles have NO `superseded_by` column — supersession is the `:superseded`
  status value. This is the Elixir mirror of the SQL the trigger runs; the trigger
  remains the source of truth.
  """
  @spec live?(Article.t() | atom() | String.t() | nil) :: boolean()
  def live?(%Article{status: status}), do: live?(status)
  def live?(nil), do: false
  def live?(status) when is_atom(status), do: status != :superseded
  def live?(status) when is_binary(status), do: status != "superseded"
end
