defmodule LoopctlWeb.KnowledgeSuggestLinksExitGuardTest do
  use LoopctlWeb.ConnCase, async: true

  # #559: the `catch :exit` guard in `KnowledgeSuggestLinksController.suggest_links_guarded/3`
  # decides RETRYABILITY, and shipped with no assertion on either branch — the repo's own
  # recorded lesson being that a guard asserted only through its classifier goes inert. The
  # article need not exist: the DI'd `:knowledge_suggest_links` seam IS the whole path here.
  setup :verify_on_exit!

  defp authed(conn) do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  defp request(conn),
    do: get(conn, ~p"/api/v1/knowledge/articles/#{Ecto.UUID.generate()}/suggested_links")

  test "a POOL-shaped exit -> pinned 503 db_unavailable + Retry-After", %{conn: conn} do
    conn = authed(conn)

    # The production shape (a call tuple naming a pool module), not a bare atom.
    expect(Loopctl.MockSuggestLinks, :suggest_links_with_meta, fn _t, _a, _o ->
      exit({:noproc, {DBConnection, :execute, []}})
    end)

    resp = request(conn)

    assert resp.status == 503
    assert json_response(resp, 503)["error"]["code"] == "db_unavailable"
    assert get_resp_header(resp, "retry-after") != []
  end

  test "a NON-DB GenServer timeout is not dressed up as a database outage", %{conn: conn} do
    conn = authed(conn)

    # Same REASON atom as a wedged pool (`:timeout`), different SOURCE — which is why the
    # guard asks `ExitClass.pool_exit?/1` and not the reason-keyed `classify/2`.
    expect(Loopctl.MockSuggestLinks, :suggest_links_with_meta, fn _t, _a, _o ->
      exit({:timeout, {GenServer, :call, [SomeForeignServer, :ping, 5000]}})
    end)

    assert catch_exit(request(conn)) == {:suggest_links_unclassified_exit, "exit:timeout"}
  end

  test "a benign unplaceable exit still crashes, and carries no raw reason", %{conn: conn} do
    conn = authed(conn)

    # `exit(:normal)` re-exited verbatim ends the request process with NO crash report and NO
    # status line; the wrapper keeps it a crash. The re-exited term is the bounded class, so
    # the query text and vector literals a pool reason carries can never reach the crash log.
    expect(Loopctl.MockSuggestLinks, :suggest_links_with_meta, fn _t, _a, _o -> exit(:normal) end)

    reason = catch_exit(request(conn))

    assert {:suggest_links_unclassified_exit, "exit:other"} = reason
  end

  test "a THROW is left alone — the let-it-crash contract the guard narrows", %{conn: conn} do
    conn = authed(conn)

    expect(Loopctl.MockSuggestLinks, :suggest_links_with_meta, fn _t, _a, _o -> throw(:boom) end)

    assert catch_throw(request(conn)) == :boom
  end
end
