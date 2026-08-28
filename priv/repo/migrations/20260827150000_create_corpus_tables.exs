defmodule Loopctl.Repo.Migrations.CreateCorpusTables do
  use Ecto.Migration

  import Loopctl.Repo.RlsHelpers

  @moduledoc """
  US-43.1 AC-43.1.1 / AC-43.1.2 / AC-43.1.3 / AC-43.1.6 / AC-43.1.9 / AC-43.1.12.

  The corpus tier's three tables: `corpora`, `document_chunks` and
  `document_chunk_embeddings`. Modelled on
  `20260721000100_create_embedding_side_tables.exs`, which is the reference for an
  UNCONSTRAINED `vector` column paired with an explicit `dim` discriminator and a
  `vector_dims(embedding) = dim` CHECK.

  ## Why a separate table rather than an article subtype

  `/api/v1/recall`, `knowledge_heat_index`, novelty scoring and the consolidation
  pass all query `Loopctl.Knowledge.Article`. Verbatim document chunks living in
  their OWN tables are excluded from every one of those paths BY CONSTRUCTION — no
  exclusion flag, no policy a later change can forget to apply. A guard test
  (`test/loopctl/corpus_isolation_guard_test.exs`) asserts the property rather than
  assuming it.

  ## Dimension is a property of the CORPUS, not the tenant

  `corpora.dim` and `corpora.embedding_model` are pinned at creation and immutable
  thereafter. A tenant whose ARTICLE corpus is pinned at 1536 must be able to index
  a document corpus with a local 768-dimension model at the same time, so the
  per-tenant resolvers in `Loopctl.Embeddings` are not consulted on this path. The
  `dim` a chunk embedding is written at is read from the corpus row and nowhere
  else.

  ## `mode` is a text column with a CHECK, not a Postgres enum

  Matching this repo's existing practice: no migration here creates a `CREATE TYPE`
  enum; every other enumerated column (`articles.status`, `projects.kind`,
  `memories.source`) is a text column read through `Ecto.Enum`. A CHECK keeps the
  DB-side guarantee without the ALTER TYPE ceremony a new mode would otherwise
  need.

  ## `allow_snippets` carries NO DDL default, deliberately

  It is TRUE for a `server_embedded` corpus (loopctl already holds the text) and
  FALSE for a `client_embedded` one (US-43.3 AC-43.3.6's privacy-preserving
  default). A mode-conditional default is expressible in the changeset and not in
  DDL, so the changeset supplies it — a DDL default would silently break mode B's
  privacy default the moment a caller omitted the field.

  ## `document_chunks` uniqueness — `(corpus_id, source_ref, locator)`

  This is what makes re-indexing idempotent (US-43.2). `content_hash` is
  deliberately NOT in the key: it is an ordinary column compared against the
  incoming chunk to decide unchanged-vs-replaced. In the key, a chunk whose text
  moved would insert a SECOND row at the same locator instead of replacing the
  first.

  `locator` is jsonb and its INTERNAL shape belongs to the client (a PDF page, a
  byte range, an EDI loop/segment). loopctl stores and returns it verbatim and
  never normalises it — a normalisation that reordered keys would change the
  idempotency key and silently duplicate every chunk on the next index run. jsonb's
  own key-order normalisation is the one that is safe, because Postgres does it
  consistently, which is why the unique index is on the jsonb column directly. It
  is NOT NULL with a `'{}'` default because a NULL locator is DISTINCT from every
  other NULL in a btree unique index, which would silently defeat the idempotency
  the index exists to provide.

  Note the btree limit: an index entry caps at ~2704 bytes and an oversized insert
  RAISES. Every anticipated locator (a page number, a byte range, a heading path)
  is far under that. If a client ever needs a large locator the fix is a generated
  `locator_hash` column in the index, not a wider entry.

  ## `document_chunk_embeddings.live_denorm` is load-bearing AND deliberately inert

  The column carries NO trigger and is never written false: a document chunk has no
  supersession state, so the PL/pgSQL trigger pair `article_embeddings` needs has
  nothing to mirror here. The COLUMN is still required —
  `Loopctl.Repo.HnswIndex.create_dimension_index_sql/2` emits
  `WHERE dim = N AND live_denorm`, and the query builder's
  `maybe_live_denorm_only/2` adds the matching predicate — so removing it as dead
  code would fork both the shared index SQL and the shared query builder. Do not
  delete it.

  ## Cascade is declared here, not in application code (AC-43.1.9)

  `corpora -> document_chunks -> document_chunk_embeddings` cascade on delete, so
  one `DELETE` on the corpus row leaves no orphans regardless of which path issued
  it. `corpora.project_id` is ON DELETE SET NULL instead: deleting a project must
  not silently destroy an entire corpus — that is `corpus_delete`'s job and it is
  the `:user`-gated verb.

  ## RLS is ENABLE, not FORCE

  In production the table owner is `schema_admin` WITHOUT BYPASSRLS, so ENABLE
  alone enforces isolation for non-owner roles while allowing the owner to write.
  `RlsHelpers.enable_rls/1`'s own docstring claims it runs FORCE; the code does not
  — trust the code.

  ## Autovacuum (AC-43.1.12)

  The two chunk tables get the same tuning the existing embedding tables carry
  (migration `20260804230000`). It matters MORE here: a corpus re-index rewrites
  whole documents at once, so dead tuples arrive in bursts, and pgvector's HNSW
  scan SKIPS dead index entries — making a live row UNREACHABLE rather than merely
  slow. An untuned table therefore degrades recall silently rather than visibly.
  """

  # `analyze` halved from the 0.1 default; `vacuum_insert` at 0.1 so an append-heavy
  # table is still vacuumed for the visibility map. Identical to 20260804230000.
  @autovacuum_opts "autovacuum_analyze_scale_factor = 0.05, autovacuum_vacuum_insert_scale_factor = 0.1"

  @append_heavy ~w(document_chunks document_chunk_embeddings)

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS corpora (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
      project_id uuid REFERENCES projects(id) ON DELETE SET NULL,
      slug text NOT NULL,
      name text NOT NULL,
      description text,
      mode text NOT NULL,
      embedding_model text NOT NULL,
      dim integer NOT NULL,
      allow_snippets boolean NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT corpora_dim_positive CHECK (dim > 0),
      CONSTRAINT corpora_mode_valid
        CHECK (mode IN ('server_embedded', 'client_embedded'))
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS document_chunks (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
      corpus_id uuid NOT NULL REFERENCES corpora(id) ON DELETE CASCADE,
      source_ref text NOT NULL,
      locator jsonb NOT NULL DEFAULT '{}'::jsonb,
      text text,
      snippet text,
      content_hash text NOT NULL,
      ordinal integer,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS document_chunk_embeddings (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
      document_chunk_id uuid NOT NULL REFERENCES document_chunks(id) ON DELETE CASCADE,
      dim integer NOT NULL,
      embedding vector NOT NULL,
      live_denorm boolean NOT NULL DEFAULT true,
      embedding_content_hash text,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      CONSTRAINT document_chunk_embeddings_dim_positive CHECK (dim > 0),
      CONSTRAINT document_chunk_embeddings_dim_matches_vector
        CHECK (vector_dims(embedding) = dim)
    )
    """)

    create_if_not_exists(
      unique_index(:corpora, [:tenant_id, :slug], name: :corpora_tenant_id_slug_index)
    )

    # The idempotency key for `corpus_index` (US-43.2). See the moduledoc for why
    # `content_hash` is NOT a member and why `locator` is NOT NULL.
    create_if_not_exists(
      unique_index(:document_chunks, [:corpus_id, :source_ref, :locator],
        name: :document_chunks_corpus_source_locator_index
      )
    )

    create_if_not_exists(
      unique_index(:document_chunk_embeddings, [:tenant_id, :document_chunk_id, :dim],
        name: :document_chunk_embeddings_tenant_chunk_dim_index
      )
    )

    enable_rls(:corpora)
    enable_rls(:document_chunks)
    enable_rls(:document_chunk_embeddings)

    for table <- @append_heavy do
      execute("ALTER TABLE #{table} SET (#{@autovacuum_opts})")
    end
  end

  def down do
    reset = "autovacuum_analyze_scale_factor, autovacuum_vacuum_insert_scale_factor"

    for table <- @append_heavy do
      execute("ALTER TABLE #{table} RESET (#{reset})")
    end

    execute("DROP TABLE IF EXISTS document_chunk_embeddings")
    execute("DROP TABLE IF EXISTS document_chunks")
    execute("DROP TABLE IF EXISTS corpora")
  end
end
