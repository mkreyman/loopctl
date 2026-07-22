defmodule Loopctl.Repo.HnswDimensionIndexDriftTest do
  @moduledoc """
  US-41.1 (review, finding 6) — the FAST, every-PR mechanical guard that every
  dimension the instance PUBLISHES (config `:supported_embedding_dimensions`, which
  `.well-known` advertises and `Embeddings.supported_dimensions/0` delegates to) has
  its per-dimension HNSW index present on BOTH embedding side tables.

  The compile-time supported-set guard in `VectorSearch` only proves the cast/where
  clauses can be GENERATED for a dimension — not that its index was ever BUILT. Adding
  a dimension to config and recompiling WITHOUT running the index migration would
  advertise it and emit an unindexable `(embedding::vector(N))` cast that
  sequential-scans the corpus (#170/#172). This asserts the config/index invariant
  against the migrated test DB, so the mismatch fails on the PR, not in production.

  Distinct from the `:scale`-tagged plan gate (which needs a seeded, committed corpus
  and runs only in the scale/nightly matrix): this is a cheap `pg_class` existence
  check with no seeding, so it runs in the ordinary `mix test`. `pg_class` is a global
  catalog, visible from any connection, so the sandboxed `Loopctl.Repo` sees the
  migrated indexes fine.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.Repo
  alias Loopctl.Repo.HnswIndex

  test "every published supported dimension has its per-dimension HNSW index on both side tables" do
    missing = HnswIndex.missing_dimension_indexes(Repo)

    assert missing == [],
           "these published dimensions have NO per-dimension HNSW index (config advertises a " <>
             "dimension whose migration has not run — reads at it would seq-scan the corpus, " <>
             "#170/#172): #{inspect(missing)}"
  end
end
