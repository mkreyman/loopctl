defmodule LoopctlWeb.ErrorJSONTest do
  use LoopctlWeb.ConnCase, async: true

  alias LoopctlWeb.SanitizedDBError
  alias Phoenix.Endpoint.RenderErrors

  setup :verify_on_exit!

  test "renders 404" do
    assert LoopctlWeb.ErrorJSON.render("404.json", %{}) ==
             %{error: %{status: 404, message: "Not found"}}
  end

  test "renders 500 (no DB reason → generic internal_server_error code)" do
    assert LoopctlWeb.ErrorJSON.render("500.json", %{}) ==
             %{
               error: %{
                 status: 500,
                 code: "internal_server_error",
                 message: "Internal server error"
               }
             }
  end

  # Finding #1 (US-27.3): an uncaught catch-all DB error (DBError.map/1 → 500,
  # mapped_code "db_error") re-raised as a SanitizedDBError must surface
  # code: "db_error" on the 500 body, matching the FallbackController rescue path
  # (mapping.code) — the 500 clause was previously hard-coded and dropped `code`.
  test "renders 500 with db_error code from a SanitizedDBError reason (Finding #1)" do
    assigns = %{
      reason: %SanitizedDBError{status: 500, mapped_code: "db_error", sqlstate: "42P01"}
    }

    assert LoopctlWeb.ErrorJSON.render("500.json", assigns) ==
             %{error: %{status: 500, code: "db_error", message: "Internal server error"}}
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

  # Finding #4 (US-27.3): db_code/2's precise reason-match branch
  # — db_code(%{reason: %SanitizedDBError{mapped_code: code}}, _) — was previously
  # untested (only the empty-assigns default fallback was exercised). Assert that
  # an escaped serialization failure / deadlock surfaces its PRECISE class rather
  # than the coarse default, so the uncaught 503 body isn't coarser than the
  # rescue path.
  test "renders 504 carrying the precise mapped_code from a SanitizedDBError reason" do
    assigns = %{
      reason: %SanitizedDBError{
        status: 504,
        mapped_code: "db_statement_timeout",
        sqlstate: "57014"
      }
    }

    body = LoopctlWeb.ErrorJSON.render("504.json", assigns)
    assert body.error.status == 504
    assert body.error.code == "db_statement_timeout"
  end

  test "renders 503 carrying the precise mapped_code (db_serialization_failure) from a reason" do
    assigns = %{
      reason: %SanitizedDBError{
        status: 503,
        mapped_code: "db_serialization_failure",
        sqlstate: "40001"
      }
    }

    body = LoopctlWeb.ErrorJSON.render("503.json", assigns)
    assert body.error.status == 503
    # NOT coarsened to the db_unavailable default.
    assert body.error.code == "db_serialization_failure"
  end

  test "renders 503 carrying db_deadlock from a reason" do
    assigns = %{
      reason: %SanitizedDBError{status: 503, mapped_code: "db_deadlock", sqlstate: "40P01"}
    }

    body = LoopctlWeb.ErrorJSON.render("503.json", assigns)
    assert body.error.code == "db_deadlock"
  end

  # Finding #4 (US-27.3): drive an UNCAUGHT SanitizedDBError through the real
  # RenderErrors machinery (the glue that builds the assigns and renders the
  # template) so the actual rendered HTTP body for the uncaught path — including
  # `code` and the precise mapped_code propagation — is verified end-to-end, not
  # just via direct render/2 calls with hand-built assigns. config/test.exs sets
  # server: false, so we invoke the render path directly rather than over a
  # socket; __catch__/5 renders + sends the conn before re-raising, so we capture
  # the sent body and prove the assembly + mapped_code propagation.
  describe "uncaught path: real RenderErrors body assembly (Finding #4)" do
    setup do
      render_errors_opts = LoopctlWeb.Endpoint.config(:render_errors)
      {:ok, opts: render_errors_opts}
    end

    test "504 timeout: body carries status, db_statement_timeout code, safe message", %{
      conn: conn,
      opts: opts
    } do
      conn = sent_conn_for(conn, opts, sanitized(504, "db_statement_timeout", "57014"))

      assert conn.status == 504
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 504
      assert body["error"]["code"] == "db_statement_timeout"
      assert is_binary(body["error"]["message"])
      refute conn.resp_body =~ "SELECT"
      refute conn.resp_body =~ "::vector"
    end

    test "503 serialization: body carries the precise db_serialization_failure code", %{
      conn: conn,
      opts: opts
    } do
      conn = sent_conn_for(conn, opts, sanitized(503, "db_serialization_failure", "40001"))

      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 503
      # NOT coarsened to db_unavailable on the uncaught path.
      assert body["error"]["code"] == "db_serialization_failure"
    end

    test "500 catch-all: body carries db_error code (Finding #1, end-to-end)", %{
      conn: conn,
      opts: opts
    } do
      conn = sent_conn_for(conn, opts, sanitized(500, "db_error", "42P01"))

      assert conn.status == 500
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 500
      assert body["error"]["code"] == "db_error"
    end

    defp sanitized(status, mapped_code, sqlstate) do
      %SanitizedDBError{status: status, mapped_code: mapped_code, sqlstate: sqlstate}
    end

    # Run the real RenderErrors.__catch__/5 for an uncaught SanitizedDBError. It
    # renders + sends the conn, then re-raises the same error (maybe_raise), so we
    # rescue the re-raise and read the already-sent response via Plug.Test (the
    # adapter ref is shared with the conn we passed in).
    defp sent_conn_for(conn, opts, %SanitizedDBError{} = error) do
      conn = Plug.Conn.put_private(conn, :phoenix_format, "json")

      try do
        RenderErrors.__catch__(conn, :error, error, [], opts)
      rescue
        SanitizedDBError -> nil
      end

      {status, _headers, body} = Plug.Test.sent_resp(conn)
      %{conn | status: status, resp_body: body, state: :sent}
    end
  end
end
