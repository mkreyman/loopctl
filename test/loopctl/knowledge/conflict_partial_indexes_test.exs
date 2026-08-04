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

  # `pg_indexes` renders an indexdef for an INVALID index too, so validity has to be read
  # separately: an interrupted CONCURRENTLY build leaves a definition the planner ignores.
  defp indexdef(name) do
    sql = """
    SELECT pg_get_indexdef(c.oid), x.indisvalid FROM pg_class c
      JOIN pg_index x ON x.indexrelid = c.oid
     WHERE c.relname = $1 AND c.relkind = 'i'
    """

    case AdminRepo.query!(sql, [name]).rows do
      [[def, valid]] -> {def, valid}
      [] -> {nil, false}
    end
  end

  test "#577: the contradicts partial index exists and is scoped to that relationship" do
    # `contradicts` is 0 rows in production, so this index costs 8 kB and turns a 313 ms walk
    # of the whole composite index into 0.131 ms.
    {def_sql, valid} = indexdef("article_links_contradicts_idx")

    assert def_sql, "article_links_contradicts_idx is missing — see the #577 migration"
    assert valid, "article_links_contradicts_idx is INVALID — the planner will ignore it"
    # The predicate renders with the enum cast to text, hence the regex rather than a literal.
    assert def_sql =~ ~r/WHERE \(\(relationship_type\)::text = 'contradicts'/

    # The FULL ordered key list, not just "tenant_id somewhere" — `find_contradiction_clusters/2`
    # joins on source_article_id/target_article_id, so a subset or permutation stops covering it.
    assert def_sql =~ "USING btree (tenant_id, source_article_id, target_article_id)",
           "the index must keep its exact key order to cover the clusters join: #{def_sql}"
  end

  test "#576: the potential-conflict partial index orders the score DESC" do
    # THE gotcha this pins. `list_potential_conflicts/2` orders by
    # `similarity_score DESC, id ASC`; Ecto's `desc:` emits bare `DESC` (= DESC NULLS FIRST),
    # and a PostgreSQL index column declared `DESC` also defaults to NULLS FIRST — so they
    # match. Rebuild it any other way and the planner SILENTLY sorts the whole filtered set
    # instead, returning identical rows — which is why only the definition can catch it.
    {def_sql, valid} = indexdef("article_links_potential_conflict_idx")

    assert def_sql, "article_links_potential_conflict_idx is missing — see the #576 migration"
    assert valid, "article_links_potential_conflict_idx is INVALID — the planner will ignore it"

    # The whole key list as ONE literal, pinning DESC to the score EXPRESSION plus the
    # tenant_id-first / id-last order. A loose `similarity_score.*DESC` regex also matches
    # `(tenant_id, (…score…), id DESC)`; `NULLS LAST` would render inside this literal too.
    assert def_sql =~
             "USING btree (tenant_id, (((metadata ->> 'similarity_score'::text))::double precision) DESC, id)",
           "the score column must be DESC (NULLS FIRST) with tenant_id first and id last: #{def_sql}"

    assert def_sql =~ ~r/WHERE \(\(\(relationship_type\)::text = 'potential_conflict'/,
           "the index must stay partial — a full index over 1.4M rows is the thing being avoided"

    assert def_sql =~ "auto_generated",
           "the partial predicate must include the auto_generated filter the query applies"
  end
end
