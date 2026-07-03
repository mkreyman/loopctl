defmodule Loopctl.Repo.ReconcileHnswIndexMigrationTest do
  @moduledoc """
  US-27.14 / TC-27.14.1 — behaviour test for the HNSW index-name reconcile.

  Exercises the capability-based (`amname = 'hnsw'`) detection / create / drop /
  reconcile SQL that the two HNSW migrations run — `AddEmbeddingHnswIndex`
  (`up`/`down`) and `ReconcileHnswIndexName` (`up`) — proving:

    * the drop-step drops WHICHEVER hnsw index is present (by `amname='hnsw'`,
      not a hard-coded name), and drops ALL of them (never `LIMIT 1`), so a
      rollback against a DB where the index lives under a non-migration name
      leaves none orphaned;
    * the create-step is capability-guarded — with any hnsw index already
      present it does NOT create a second, redundant one;
    * the reconcile step is idempotent and renames any non-canonical hnsw index
      up to the canonical `<table>_embedding_hnsw_idx`; and
    * the tightened idempotency guard matches only an hnsw index of the
      canonical NAME, so an unrelated relation squatting that name cannot
      short-circuit reconciliation — the RENAME instead surfaces the conflict.

  ## Isolation — no shared global state

  This SQL is the single source of truth in `Loopctl.Repo.HnswIndex`,
  parameterized by table name. The production migrations call it with
  `"articles"` (targeting the live, shared `articles_embedding_hnsw_idx`); this
  test calls it against a PER-TEST, UNIQUELY-NAMED THROWAWAY table it creates in
  its own sandbox transaction. Index DDL — unlike row data — is NOT isolated by
  the Ecto SQL sandbox at the object level, so a test that dropped / renamed the
  shared `articles_embedding_hnsw_idx` would be mutating global state that every
  other embedding test depends on. Operating on a throwaway table removes that
  coupling entirely: the CREATE/DROP/RENAME here only ever touch this test's own
  object, so the test is `async: true` and can never race the async embedding
  tests over the canonical index. (An empty throwaway table also builds its
  hnsw index instantly, so there is no multi-second index-build timing race.)

  The two migration modules are thin `execute(Loopctl.Repo.HnswIndex.<...>)`
  wrappers over the exact SQL exercised here; their production path against
  `public.articles` is smoke-covered every run by `mix ecto.reset` (which runs
  the real migrations) and by `Loopctl.KnowledgeEmbeddingTest`, which asserts the
  canonical index exists on `articles`.
  """
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Repo.HnswIndex

  setup do
    pid = Sandbox.start_owner!(AdminRepo, shared: false)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # A per-test, uniquely-named throwaway table with a pgvector embedding
    # column. Created inside this test's sandbox transaction, so it is invisible
    # to every other test and rolled back on exit — nothing to drop explicitly.
    table = "hnsw_reconcile_test_#{System.unique_integer([:positive])}"

    AdminRepo.query!("CREATE TABLE #{table} (id bigserial PRIMARY KEY, embedding vector(1536))")

    %{
      table: table,
      migration: HnswIndex.migration_index_name(table),
      canonical: HnswIndex.canonical_index_name(table)
    }
  end

  # Names of all hnsw-access-method indexes on `table`, schema-qualified to public.
  defp hnsw_index_names(table) do
    AdminRepo.query!("""
    SELECT i.relname
    FROM pg_index x
    JOIN pg_class i ON i.oid = x.indexrelid
    JOIN pg_class t ON t.oid = x.indrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    JOIN pg_am    am ON am.oid = i.relam
    WHERE t.relname = '#{table}' AND n.nspname = 'public' AND am.amname = 'hnsw'
    """).rows
    |> List.flatten()
  end

  defp create_hnsw_index(table, name) do
    AdminRepo.query!("CREATE INDEX #{name} ON #{table} USING hnsw (embedding vector_cosine_ops)")
  end

  test "drop-step drops the actually-present HNSW index (non-migration name)", ctx do
    %{table: table, migration: migration, canonical: canonical} = ctx

    # An hnsw index present under an out-of-band name — exactly prod's situation
    # (the live index was created outside the migration's name).
    out_of_band = "#{table}_out_of_band_idx"
    create_hnsw_index(table, out_of_band)
    assert hnsw_index_names(table) == [out_of_band]

    # The amname-based drop must drop it, not no-op against a hard-coded name.
    AdminRepo.query!(HnswIndex.drop_all_sql(table))

    assert hnsw_index_names(table) == [],
           "drop-step must drop the present hnsw index, not no-op against a foreign name"

    # The create-step recreates it (under the old migration's name), which the
    # reconcile step then renames to the canonical name.
    AdminRepo.query!(HnswIndex.create_if_absent_sql(table))
    assert hnsw_index_names(table) == [migration]

    AdminRepo.query!(HnswIndex.reconcile_sql(table))
    assert hnsw_index_names(table) == [canonical]
  end

  test "create-step does not create a duplicate hnsw index from the drift state (AC-27.14.2)",
       ctx do
    %{table: table, canonical: canonical} = ctx

    # Drift state: the single hnsw index lives under the out-of-band canonical
    # name, NOT the migration's `<table>_embedding_idx`.
    create_hnsw_index(table, canonical)
    assert hnsw_index_names(table) == [canonical]

    # The amname-aware create-guard must see the existing hnsw index and SKIP,
    # so no second redundant hnsw index is created.
    AdminRepo.query!(HnswIndex.create_if_absent_sql(table))

    assert hnsw_index_names(table) == [canonical],
           "create-step must not create a duplicate hnsw index when one already exists under a different name"
  end

  test "drop-step drops ALL hnsw indexes, leaving none orphaned (AC-27.14.2)", ctx do
    %{table: table, migration: migration, canonical: canonical} = ctx

    # Force the (normally unreachable) two-index state to prove the drop-step
    # iterates over every hnsw index rather than dropping only one (LIMIT 1).
    create_hnsw_index(table, canonical)
    create_hnsw_index(table, migration)
    assert Enum.sort(hnsw_index_names(table)) == Enum.sort([canonical, migration])

    AdminRepo.query!(HnswIndex.drop_all_sql(table))

    assert hnsw_index_names(table) == [],
           "drop-step must drop every hnsw index, leaving none orphaned"
  end

  test "reconcile renames a non-canonical hnsw index to the canonical name", ctx do
    %{table: table, migration: migration, canonical: canonical} = ctx

    # Fresh-DB shape: only the old migration's name is present.
    create_hnsw_index(table, migration)
    assert hnsw_index_names(table) == [migration]

    AdminRepo.query!(HnswIndex.reconcile_sql(table))
    assert hnsw_index_names(table) == [canonical]
  end

  test "reconcile is idempotent — re-running it is a no-op", ctx do
    %{table: table, canonical: canonical} = ctx

    create_hnsw_index(table, canonical)
    assert hnsw_index_names(table) == [canonical]

    # Already canonical: first run is a no-op...
    AdminRepo.query!(HnswIndex.reconcile_sql(table))
    assert hnsw_index_names(table) == [canonical]

    # ...and a second run is also a no-op (the guard short-circuits).
    AdminRepo.query!(HnswIndex.reconcile_sql(table))
    assert hnsw_index_names(table) == [canonical]
  end

  test "guard does not treat a non-hnsw object squatting the canonical name as reconciled",
       ctx do
    %{table: table, migration: migration, canonical: canonical} = ctx

    # The real hnsw index lives under the non-canonical name, and an UNRELATED
    # table squats the canonical name. Postgres puts tables and indexes in the
    # same relation namespace, so the RENAME target is occupied and
    # reconciliation legitimately cannot complete. The CORRECT behaviour is to
    # surface that conflict by RAISING — not to short-circuit at the guard and
    # report a false success (which a bare `relname` guard would have done).
    create_hnsw_index(table, migration)
    AdminRepo.query!("CREATE TABLE #{canonical} (id int)")

    assert hnsw_index_names(table) == [migration]

    assert_raise Postgrex.Error, fn ->
      AdminRepo.query!(HnswIndex.reconcile_sql(table))
    end
  end
end
