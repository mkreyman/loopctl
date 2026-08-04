defmodule Loopctl.Knowledge.ConflictPartialIndexesTest do
  @moduledoc """
  #576 / #577 — the two partial indexes on `article_links` for the conflict reads.

  These assert the index DEFINITION, not query results, because the defect they prevent is
  invisible to a correctness test: the queries return the right rows with or without an
  index. What changes is whether the plan is an index scan or a walk of the whole composite
  index (the migration carries the measured figures), and test data is far too small for the
  planner to reveal that.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo

  # `pg_indexes` renders an indexdef for an INVALID index too, so validity has to be read
  # separately: an interrupted CONCURRENTLY build leaves a definition the planner ignores.
  defp indexdef(name) do
    # Schema-qualified to `public` (the reconcile migration's canonical detection SQL): a
    # same-named index in another visible schema would otherwise return two rows.
    sql = """
    SELECT pg_get_indexdef(c.oid), x.indisvalid FROM pg_class c
      JOIN pg_index x ON x.indexrelid = c.oid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relname = $1 AND c.relkind = 'i' AND n.nspname = 'public'
    """

    case AdminRepo.query!(sql, [name]).rows do
      [[def, valid]] -> {def, valid}
      [] -> {nil, false}
    end
  end

  test "#577: the contradicts partial index exists and is scoped to that relationship" do
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

    # The ordered key list, pinning DESC to the score EXPRESSION plus tenant_id-first /
    # id-last. Not one verbatim catalog string: `pg_get_indexdef`'s parenthesisation and cast
    # spelling are the deparser's, and vary by PostgreSQL major. Still exact where it counts —
    # a bare `similarity_score.*DESC` would also match `(tenant_id, (…score…), id DESC)`, and
    # `DESC NULLS LAST` does not match `DESC, id)`.
    assert def_sql =~ ~r/USING btree \(tenant_id, .*similarity_score.*DESC, id\)/,
           "the score column must be DESC (NULLS FIRST) with tenant_id first and id last: #{def_sql}"

    assert def_sql =~ ~r/WHERE \(\(\(relationship_type\)::text = 'potential_conflict'/,
           "the index must stay partial — a full index over 1.4M rows is the thing being avoided"

    assert def_sql =~ "auto_generated",
           "the partial predicate must include the auto_generated filter the query applies"
  end
end
