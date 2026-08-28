defmodule Loopctl.CorpusIsolationGuardTest do
  @moduledoc """
  US-43.1 AC-43.1.8 / AC-43.1.11 — two code-anchored static guards.

  The epic's central claim is that verbatim document chunks are excluded from the
  article corpus BY CONSTRUCTION rather than by policy: `/api/v1/recall`,
  `knowledge_heat_index`, novelty scoring and the consolidation pass all query
  `Loopctl.Knowledge.Article`, and a separate table is simply not reachable from
  them. That is a property of the CODE, so it is asserted against the code —
  every module those paths are built from is scanned for any reference to the new
  schemas, the new table names, or the new context.

  The second guard holds the other structural decision: the corpus's dimension is
  read from the corpus row and from nowhere else. Neither
  `Loopctl.Embeddings`' per-tenant resolver nor its write-resolving sibling may
  appear anywhere on the corpus path — one returns the tenant's ARTICLE dimension
  (1536 for a 768 corpus) and the other WRITES the tenant pin as a side effect, so
  a single corpus write by a tenant that had not yet embedded an article would pin
  that tenant's article corpus to the local document model.

  ## Why each guard asserts its own matched set is non-empty

  A static scan that classifies files by substring can police an EMPTY set and pass
  forever — a module rename, a moved file, a typo'd path, and the guard silently
  stops guarding anything. Both scans therefore assert that they actually read the
  files they claim to, and the exclusion scan additionally asserts every named path
  EXISTS, so a rename fails here loudly instead of going quiet.

  Both were verified by MUTATION, not by reading: a `Loopctl.Corpus.DocumentChunk`
  reference added to `lib/loopctl_web/controllers/recall_json.ex` turned the first
  test red, and naming the per-tenant resolver in `lib/loopctl/corpus.ex` turned the
  second red. Both mutations were then reversed in place.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Corpus.DocumentChunkEmbedding
  alias Loopctl.Repo.HnswIndex

  @repo_root Path.expand("../..", __DIR__)

  # The modules the article-corpus read paths are built from. Anchored by PATH so a
  # module rename shows up as a missing file (asserted below) rather than as a scan
  # that quietly matches nothing.
  @article_path_modules [
    # recall + heat_index + novelty scoring
    "lib/loopctl/knowledge.ex",
    # the novelty gate
    "lib/loopctl/knowledge/proposal_gate.ex",
    # the nightly consolidation pass
    "lib/loopctl/knowledge/consolidation.ex",
    # the shared kNN query builder every article/memory vector read goes through
    "lib/loopctl/knowledge/vector_search.ex",
    # the merged memory-union-knowledge recall
    "lib/loopctl/memory.ex",
    # POST /api/v1/recall and its renderer
    "lib/loopctl_web/controllers/memory_controller.ex",
    "lib/loopctl_web/controllers/recall_json.ex"
  ]

  # Every spelling a reference could take: the schema modules (which also covers
  # `DocumentChunkEmbedding`), the raw table names a fragment or raw SQL would use,
  # and the context module — including the `alias` form, which would otherwise let
  # `Corpus.upsert_chunks(...)` evade a scan for the fully-qualified name.
  @corpus_references [
    "DocumentChunk",
    "document_chunks",
    "document_chunk_embeddings",
    "Loopctl.Corpus",
    "corpora"
  ]

  # The corpus path. `lib/loopctl/corpus.ex` plus every schema under it.
  defp corpus_module_paths do
    ([Path.join(@repo_root, "lib/loopctl/corpus.ex")] ++
       Path.wildcard(Path.join(@repo_root, "lib/loopctl/corpus/**/*.ex")))
    |> Enum.filter(&File.exists?/1)
  end

  # AC-43.1.8
  test "no article-corpus read path references the corpus tier" do
    scanned = Enum.map(@article_path_modules, &Path.join(@repo_root, &1))

    missing =
      scanned |> Enum.reject(&File.exists?/1) |> Enum.map(&Path.relative_to(&1, @repo_root))

    assert missing == [],
           "These modules are named as article-corpus read paths but do not exist — the " <>
             "guard would have scanned nothing. Update the list to the new names: " <>
             inspect(missing)

    assert scanned != [],
           "The article-path scan matched no files at all — it would pass forever."

    offenders =
      for path <- scanned,
          reference <- @corpus_references,
          hit <- matching_lines(path, reference),
          do: {Path.relative_to(path, @repo_root), reference, hit}

    assert offenders == [],
           "The article-corpus read paths (recall, heat index, novelty, consolidation) " <>
             "reference the corpus tier. Document chunks are excluded from those paths BY " <>
             "CONSTRUCTION — they live in their own tables and nothing in the article path " <>
             "may reach them: " <> inspect(offenders)
  end

  # AC-43.1.11
  test "the corpus path never names either per-tenant dimension resolver" do
    paths = corpus_module_paths()

    assert length(paths) >= 4,
           "The corpus-path scan found #{length(paths)} files — it must cover the context " <>
             "module and its three schemas, or it is guarding nothing: " <> inspect(paths)

    offenders =
      for path <- paths,
          resolver <- ["active_dimension", "resolve_write_dimension"],
          hit <- matching_lines(path, resolver),
          do: {Path.relative_to(path, @repo_root), resolver, hit}

    assert offenders == [],
           "The corpus path names a per-tenant dimension resolver. A corpus's dimension is " <>
             "read from its OWN row and from nowhere else: the per-tenant resolver would " <>
             "return the tenant's ARTICLE dimension, and the write-resolving one PINS " <>
             "tenants.tenant_embedding_dimension as a side effect. The names are refused in " <>
             "prose too, deliberately — a doc that names them is the confusion this guard " <>
             "exists to prevent, and the prohibition is documented here and in the epic " <>
             "README instead: " <> inspect(offenders)
  end

  test "the corpus schemas keep the four column names the shared query builder needs" do
    fields = DocumentChunkEmbedding.__schema__(:fields)

    for column <- [:tenant_id, :dim, :embedding, :live_denorm] do
      assert column in fields,
             "document_chunk_embeddings.#{column} is what lets " <>
               "Loopctl.Knowledge.VectorSearch.index_safe_dimension_knn_base/6 and " <>
               "Loopctl.Repo.HnswIndex.create_dimension_index_sql/2 be reused unchanged."
    end
  end

  test "document_chunk_embeddings is covered by the per-dimension index drift guard" do
    tables =
      HnswIndex.required_dimension_indexes()
      |> Enum.map(fn {table, _dim, _name} -> table end)
      |> Enum.uniq()

    assert "document_chunk_embeddings" in tables,
           "The corpus embedding table must be in HnswIndex's side-table list, or a " <>
             "dimension published in config without its index built would make every " <>
             "corpus read at that dimension seq-scan: " <> inspect(tables)
  end

  # Non-comment lines of `path` containing `needle`. Comment-only lines are skipped so
  # a note ABOUT the exclusion does not read as a violation of it.
  defp matching_lines(path, needle) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(&1 |> String.trim_leading() |> String.starts_with?("#")))
    |> Enum.filter(&String.contains?(&1, needle))
  end
end
