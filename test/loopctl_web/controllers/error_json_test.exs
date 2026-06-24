defmodule LoopctlWeb.ErrorJSONTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  test "renders 404" do
    assert LoopctlWeb.ErrorJSON.render("404.json", %{}) ==
             %{error: %{status: 404, message: "Not found"}}
  end

  test "renders 500" do
    assert LoopctlWeb.ErrorJSON.render("500.json", %{}) ==
             %{error: %{status: 500, message: "Internal server error"}}
  end

  test "renders arbitrary status code via the catch-all reason phrase" do
    # 502 has no explicit clause, so it exercises the catch-all reason_phrase/1.
    # (503/504 now have explicit US-27.3 clauses asserted in fallback tests.)
    body = LoopctlWeb.ErrorJSON.render("502.json", %{})
    assert body.error.status == 502
    assert body.error.message == "Bad Gateway"
  end

  test "renders 504 with a safe, labelled db_statement_timeout body (US-27.3)" do
    body = LoopctlWeb.ErrorJSON.render("504.json", %{})
    assert body.error.status == 504
    assert body.error.code == "db_statement_timeout"
    assert is_binary(body.error.message)
    refute body.error.message =~ "SELECT"
  end

  test "renders 503 with a safe, labelled db_unavailable body (US-27.3)" do
    body = LoopctlWeb.ErrorJSON.render("503.json", %{})
    assert body.error.status == 503
    assert body.error.code == "db_unavailable"
  end
end
