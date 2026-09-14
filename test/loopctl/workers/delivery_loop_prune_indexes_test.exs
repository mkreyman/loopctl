defmodule Loopctl.Workers.DeliveryLoopPruneIndexesTest do
  @moduledoc """
  #803 §11 — the two indexes the retention pass reads.

  These assert the index DEFINITION, not query results, for the reason
  `Loopctl.Knowledge.ConflictPartialIndexesTest` gives: the prune returns the right rows with
  or without them, and test data is far too small for the planner to reveal the difference.
  What changes in production is a sequential scan of the highest-volume table in the system,
  once per batch.

  VALIDITY is asserted separately from existence and it is the half that matters here. Both
  are built `CONCURRENTLY`, an interrupted build leaves an INVALID index that occupies the
  name, and `CREATE INDEX ... IF NOT EXISTS` then quietly declines to replace it — so the
  scan silently degrades while every surface says the index is there. The migration's
  `stale?/2` guard exists to drop that; this test is what notices if the guard stops working.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo

  defp indexdef(name) do
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

  test "the trace retention scan's index exists, is VALID, and keeps its key order" do
    {def_sql, valid} = indexdef("runner_trace_events_tenant_inserted_at_idx")

    assert def_sql,
           "runner_trace_events_tenant_inserted_at_idx is missing — see the #803 migration"

    assert valid,
           "runner_trace_events_tenant_inserted_at_idx is INVALID — the planner ignores it, " <>
             "and the retention scan silently becomes a sequential scan of the largest table here"

    # tenant_id equality first, then the `ORDER BY inserted_at` the candidate query takes.
    # A permutation stops covering the ordering step, which is the whole point of the index.
    assert def_sql =~ "USING btree (tenant_id, inserted_at)",
           "the index must keep its exact key order to cover the oldest-first scan: #{def_sql}"
  end

  test "the still-cited guard's index exists, is VALID, and covers the whole lookup" do
    {def_sql, valid} = indexdef("intake_records_tenant_source_last_delivery_idx")

    assert def_sql,
           "intake_records_tenant_source_last_delivery_idx is missing — see the #803 migration"

    assert valid,
           "intake_records_tenant_source_last_delivery_idx is INVALID — without it the " <>
             "still-cited NOT EXISTS walks every record of the source, per candidate delivery"

    # All three keys: the NOT EXISTS matches on tenant_id, source_id AND last_delivery_id, so
    # a prefix leaves the last one as a heap filter over the whole source.
    assert def_sql =~ "USING btree (tenant_id, source_id, last_delivery_id)",
           "the index must carry all three keys of the still-cited lookup: #{def_sql}"
  end
end
