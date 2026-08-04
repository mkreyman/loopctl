defmodule Loopctl.Knowledge.ConflictPartialIndexesTest do
  @moduledoc """
  #576 / #577 — the two partial indexes on `article_links` for the conflict reads.

  These assert the index DEFINITION, not query results, because the defect they prevent is
  invisible to a correctness test: the queries return the right rows with or without an
  index. What changes is whether the plan is an index scan or a walk of all 1,417,624
  entries, and test data is far too small for the planner to reveal that.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo

  defp indexdef(name) do
    %{rows: rows} =
      AdminRepo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [name])

    case rows do
      [[def]] -> def
      [] -> nil
    end
  end

  test "#577: the contradicts partial index exists and is scoped to that relationship" do
    # `contradicts` is 0 rows in production, so this index costs 8 kB and turns a 313 ms walk
    # of the whole composite index into 0.131 ms.
    def_sql = indexdef("article_links_contradicts_idx")

    assert def_sql, "article_links_contradicts_idx is missing — see the #577 migration"
    # The predicate renders with the enum cast to text, hence the regex rather than a literal.
    assert def_sql =~ ~r/WHERE \(\(relationship_type\)::text = 'contradicts'/
    assert def_sql =~ "tenant_id"
  end

  test "#576: the potential-conflict partial index orders the score DESC" do
    # THE gotcha this pins. `list_potential_conflicts/2` orders by
    # `similarity_score DESC, id ASC`; Ecto's `desc:` emits bare `DESC` (= DESC NULLS FIRST),
    # and a PostgreSQL index column declared `DESC` also defaults to NULLS FIRST — so they
    # match. Rebuild this index without the `DESC`, or with `NULLS LAST`, and the planner
    # SILENTLY stops using it for the ordering and sorts the whole filtered set instead. The
    # rows returned are identical either way, which is why only the definition can catch it.
    def_sql = indexdef("article_links_potential_conflict_idx")

    assert def_sql, "article_links_potential_conflict_idx is missing — see the #576 migration"

    assert def_sql =~ ~r/similarity_score.*DESC/,
           "the score column must be DESC to serve the query's ORDER BY: #{def_sql}"

    refute def_sql =~ "NULLS LAST",
           "NULLS LAST will not satisfy the query's DESC (NULLS FIRST) ordering"

    assert def_sql =~ ~r/WHERE \(\(\(relationship_type\)::text = 'potential_conflict'/,
           "the index must stay partial — a full index over 1.4M rows is the thing being avoided"

    assert def_sql =~ "auto_generated",
           "the partial predicate must include the auto_generated filter the query applies"
  end
end
