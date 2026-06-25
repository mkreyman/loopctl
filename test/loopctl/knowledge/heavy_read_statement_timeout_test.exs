defmodule Loopctl.Knowledge.HeavyReadStatementTimeoutTest do
  @moduledoc """
  US-27.4 (AC-27.4.1/.2): a per-endpoint SERVER-SIDE statement_timeout override on a
  heavy read fast-fails a pathological query with Postgres 57014, which US-27.3's
  `LoopctlWeb.DBError` maps to the structured `db_statement_timeout` (504) — proving
  the timeout path produces the documented structured error and releases the connection
  (no 30s hang).
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.Article
  alias LoopctlWeb.DBError

  import Ecto.Query

  test "an explicit :statement_timeout override still returns correct scoped rows" do
    tenant = fixture(:tenant)
    art = fixture(:article, %{tenant_id: tenant.id})

    query = from(a in Article, where: a.tenant_id == ^tenant.id, select: a.id)

    assert HeavyRead.all(tenant.id, query, statement_timeout: 5_000) == [art.id]
  end

  test "a tight :statement_timeout override fast-fails a slow heavy read with 57014 → db_statement_timeout" do
    tenant = fixture(:tenant)
    _art = fixture(:article, %{tenant_id: tenant.id})

    # Scoped (guard passes) but deliberately slow: pg_sleep runs while scanning the row.
    slow =
      from(a in Article,
        where: a.tenant_id == ^tenant.id,
        where: fragment("pg_sleep(1) IS NULL")
      )

    err =
      assert_raise Postgrex.Error, fn ->
        HeavyRead.all(tenant.id, slow, statement_timeout: 50)
      end

    assert err.postgres.code == :query_canceled

    # US-27.3 mapping: surfaces as the structured 504 db_statement_timeout, not a 500.
    assert {:ok, %{status: 504, code: "db_statement_timeout"}} = DBError.map(err)
  end
end
