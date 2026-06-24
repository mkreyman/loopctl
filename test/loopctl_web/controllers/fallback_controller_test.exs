defmodule LoopctlWeb.FallbackControllerTest do
  use LoopctlWeb.ConnCase, async: true

  setup :verify_on_exit!

  alias LoopctlWeb.FallbackController

  defp call_fallback(conn, error) do
    conn
    |> Plug.Conn.put_private(:phoenix_format, "json")
    |> FallbackController.call(error)
  end

  describe "error atom handling" do
    test "renders 404 for :not_found", %{conn: conn} do
      conn = call_fallback(conn, {:error, :not_found})

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 404
      assert body["error"]["message"] == "Not found"
    end

    test "renders 401 for :unauthorized", %{conn: conn} do
      conn = call_fallback(conn, {:error, :unauthorized})

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 401
      assert body["error"]["message"] == "Unauthorized"
    end

    test "renders 403 for :forbidden", %{conn: conn} do
      conn = call_fallback(conn, {:error, :forbidden})

      assert conn.status == 403
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 403
      assert body["error"]["message"] == "Forbidden"
    end

    test "renders 409 for :conflict", %{conn: conn} do
      conn = call_fallback(conn, {:error, :conflict})

      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 409
      assert body["error"]["message"] == "Conflict"
    end

    test "renders 429 for :rate_limited with default retry hint", %{conn: conn} do
      conn = call_fallback(conn, {:error, :rate_limited})

      assert conn.status == 429
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 429
      assert body["error"]["message"] =~ "Retry after 60 seconds"
      assert body["error"]["retry_after_seconds"] == 60
    end

    test "renders 429 with retry_after_seconds from response header", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> call_fallback({:error, :rate_limited})

      assert conn.status == 429
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 429
      assert body["error"]["message"] =~ "Retry after 30 seconds"
      assert body["error"]["retry_after_seconds"] == 30
    end
  end

  describe "changeset error handling" do
    test "renders 422 with changeset errors", %{conn: conn} do
      changeset =
        {%{}, %{name: :string, email: :string}}
        |> Ecto.Changeset.cast(%{}, [:name, :email])
        |> Ecto.Changeset.validate_required([:name, :email])

      conn = call_fallback(conn, {:error, changeset})

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 422
      assert body["error"]["message"] == "Validation failed"
      assert "can't be blank" in body["error"]["details"]["name"]
      assert "can't be blank" in body["error"]["details"]["email"]
    end
  end

  describe "custom message handling" do
    test "renders 422 with custom message for 3-tuple", %{conn: conn} do
      conn =
        call_fallback(
          conn,
          {:error, :unprocessable_entity, "Cycle detected in dependency graph"}
        )

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 422
      assert body["error"]["message"] == "Cycle detected in dependency graph"
    end
  end

  # --- Issue 4: contract_mismatch error with counts ---

  describe "contract_mismatch handling" do
    test "renders 422 with expected and provided ac_count", %{conn: conn} do
      conn =
        call_fallback(
          conn,
          {:error, {:contract_mismatch, %{expected_ac_count: 5, provided_ac_count: 3}}}
        )

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 422
      assert body["error"]["message"] =~ "expected ac_count 5"
      assert body["error"]["message"] =~ "got 3"
      assert body["error"]["context"]["expected_ac_count"] == 5
      assert body["error"]["context"]["provided_ac_count"] == 3
    end
  end

  # --- Issue 8: descriptive invalid_transition errors ---

  describe "invalid_transition context handling" do
    test "renders 409 with current state and attempted action", %{conn: conn} do
      conn =
        call_fallback(
          conn,
          {:error,
           {:invalid_transition,
            %{
              current_agent_status: :pending,
              current_verified_status: :unverified,
              attempted_action: "claim"
            }}}
        )

      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 409
      assert body["error"]["message"] =~ "Cannot claim"
      assert body["error"]["message"] =~ "pending"
      assert body["error"]["context"]["current_agent_status"] == "pending"
      assert body["error"]["context"]["attempted_action"] == "claim"
    end

    test "renders 409 with hint when present", %{conn: conn} do
      conn =
        call_fallback(
          conn,
          {:error,
           {:invalid_transition,
            %{
              current_agent_status: :pending,
              current_verified_status: :unverified,
              attempted_action: "verify",
              hint: "Story must be in 'reported_done' agent_status before it can be verified"
            }}}
        )

      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "reported_done"
    end
  end

  describe "ErrorJSON" do
    test "renders 500 without leaking internal details" do
      # Finding #1 (US-27.3): the 500 clause now carries a `code` (generic
      # internal_server_error with no DB reason) — still a safe, generic body.
      body = LoopctlWeb.ErrorJSON.render("500.json", %{})

      assert body == %{
               error: %{
                 status: 500,
                 code: "internal_server_error",
                 message: "Internal server error"
               }
             }
    end

    test "renders 404 with consistent format" do
      body = LoopctlWeb.ErrorJSON.render("404.json", %{})
      assert body == %{error: %{status: 404, message: "Not found"}}
    end
  end

  describe "Ecto.CastError handling" do
    test "Ecto.CastError maps to 404 via Plug.Exception" do
      exception = %Ecto.CastError{message: "invalid UUID"}
      assert Plug.Exception.status(exception) == 404
    end

    test "Ecto.Query.CastError maps to 404 via Plug.Exception" do
      exception = %Ecto.Query.CastError{message: "invalid UUID"}
      assert Plug.Exception.status(exception) == 404
    end
  end

  # --- US-27.3: structured DB-error surfacing (map SQLSTATE → safe, logged) ---

  # Build a Postgrex.Error the way Postgrex does, so .postgres has both the
  # atom code and the numeric pg_code string. `query:` is set to a value that
  # WOULD leak (raw SQL + a vector literal) if anything ever called
  # Exception.message/1 — the no-leak assertions below prove we don't.
  defp pg_error(code, pg_code) do
    %Postgrex.Error{
      postgres: %{
        code: code,
        pg_code: pg_code,
        severity: "ERROR",
        message: "canceling statement due to statement timeout"
      },
      query:
        "SELECT id FROM articles ORDER BY embedding <=> '[0.123,0.456,0.789]'::vector LIMIT 5"
    }
  end

  # A Postgrex.Error whose postgres.message carries a specific value — used by
  # the Finding #3 pg_message-allowlist tests to prove a constraint value is only
  # logged for the value-free allowlisted classes and omitted for the catch-all.
  defp constraint_error(code, pg_code, message) do
    %Postgrex.Error{
      postgres: %{code: code, pg_code: pg_code, severity: "ERROR", message: message},
      query: "SELECT id FROM articles ORDER BY embedding <=> '[0.1]'::vector LIMIT 5"
    }
  end

  describe "Postgrex.Error SQLSTATE mapping (AC-27.3.1 / .2 / .4)" do
    test "57014 query_canceled -> 504 db_statement_timeout", %{conn: conn} do
      conn = call_fallback(conn, {:error, pg_error(:query_canceled, "57014")})

      assert conn.status == 504
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 504
      assert body["error"]["code"] == "db_statement_timeout"
      assert is_binary(body["error"]["message"])
      # No Retry-After on a timeout (504).
      assert Plug.Conn.get_resp_header(conn, "retry-after") == []
    end

    test "40001 serialization_failure -> 503 with Retry-After", %{conn: conn} do
      conn = call_fallback(conn, {:error, pg_error(:serialization_failure, "40001")})

      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 503
      assert body["error"]["code"] == "db_serialization_failure"
      assert Plug.Conn.get_resp_header(conn, "retry-after") != []
    end

    test "40P01 deadlock_detected -> 503 with Retry-After", %{conn: conn} do
      conn = call_fallback(conn, {:error, pg_error(:deadlock_detected, "40P01")})

      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 503
      assert body["error"]["code"] == "db_deadlock"
      assert Plug.Conn.get_resp_header(conn, "retry-after") != []
    end

    test "any other Postgrex.Error -> 500 db_error (generic)", %{conn: conn} do
      conn = call_fallback(conn, {:error, pg_error(:undefined_table, "42P01")})

      assert conn.status == 500
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 500
      assert body["error"]["code"] == "db_error"
    end

    # Finding #2 (US-27.3): 22021 character_not_in_repertoire (invalid UTF-8 in
    # input) maps to 400 on the rescue path too — matching the uncaught
    # Plug.Exception path — instead of falling into the generic 500 catch-all.
    test "22021 character_not_in_repertoire -> 400 db_invalid_input", %{conn: conn} do
      conn = call_fallback(conn, {:error, pg_error(:character_not_in_repertoire, "22021")})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 400
      assert body["error"]["code"] == "db_invalid_input"
      # No Retry-After on a client input error (400).
      assert Plug.Conn.get_resp_header(conn, "retry-after") == []
    end

    test "DBConnection.ConnectionError -> 503 db_unavailable with Retry-After", %{conn: conn} do
      conn = call_fallback(conn, {:error, %DBConnection.ConnectionError{message: "tcp closed"}})

      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 503
      assert body["error"]["code"] == "db_unavailable"
      assert Plug.Conn.get_resp_header(conn, "retry-after") != []
    end
  end

  describe "DB-error body never leaks SQL/params/vectors/stack (AC-27.3.2 / .8)" do
    test "client body contains only status/code/message — no SQL, vector, or stack", %{
      conn: conn
    } do
      conn = call_fallback(conn, {:error, pg_error(:query_canceled, "57014")})

      body = Jason.decode!(conn.resp_body)

      # Exactly the safe envelope.
      assert Map.keys(body) == ["error"]
      assert Enum.sort(Map.keys(body["error"])) == ["code", "message", "status"]

      raw = conn.resp_body
      # No raw SQL fragment, no vector literal, no stack-trace markers.
      refute raw =~ "SELECT"
      refute raw =~ "embedding <=>"
      refute raw =~ "::vector"
      refute raw =~ "0.123"
      refute raw =~ "stacktrace"
      refute raw =~ ".ex:"
    end
  end

  describe "structured DB-error log (AC-27.3.3 / .8)" do
    import ExUnit.CaptureLog

    test "logs sqlstate + mapped_code at error level, no SQL/vector leak", %{conn: conn} do
      log =
        capture_log(fn ->
          call_fallback(conn, {:error, pg_error(:query_canceled, "57014")})
        end)

      assert log =~ "sqlstate=57014"
      assert log =~ "mapped_code=db_statement_timeout"
      # The raw SQL / vector literal must NOT appear in the log.
      refute log =~ "embedding <=>"
      refute log =~ "0.123"
      refute log =~ "::vector"
    end

    # Finding #3 (US-27.3, AC-27.3.8 disclosure control): for the allowlisted
    # timeout/serialization/deadlock classes the bare PG message is value-free
    # and IS logged.
    test "pg_message IS logged for the allowlisted serialization class", %{conn: conn} do
      error = constraint_error(:serialization_failure, "40001", "could not serialize access")

      log = capture_log(fn -> call_fallback(conn, {:error, error}) end)

      assert log =~ "sqlstate=40001"
      assert log =~ "could not serialize access"
    end

    # Finding #3: the catch-all db_error class also matches constraint-violation
    # errors whose postgres.message embeds a user/row value — that value must NOT
    # land in the structured pg_message log field, while sqlstate/mapped_code are
    # still logged for diagnosability.
    test "pg_message is OMITTED for the catch-all db_error class (no constraint value leak)", %{
      conn: conn
    } do
      error =
        constraint_error(
          :unique_violation,
          "23505",
          "Key (slug)=(secret-tenant-slug) already exists"
        )

      log = capture_log(fn -> call_fallback(conn, {:error, error}) end)

      # Diagnostics still present.
      assert log =~ "sqlstate=23505"
      assert log =~ "mapped_code=db_error"
      # The embedded constraint value must NOT appear in any log field.
      refute log =~ "secret-tenant-slug"
      refute log =~ "already exists"
    end

    test "pg_message is OMITTED for db_invalid_input (22021) class", %{conn: conn} do
      error =
        constraint_error(
          :character_not_in_repertoire,
          "22021",
          "invalid byte sequence 0xDEADBEEF"
        )

      log = capture_log(fn -> call_fallback(conn, {:error, error}) end)

      assert log =~ "sqlstate=22021"
      assert log =~ "mapped_code=db_invalid_input"
      refute log =~ "0xDEADBEEF"
    end
  end

  describe "Plug.Exception safety net for raised DB errors (AC-27.3.1)" do
    test "Postgrex.Error 57014 maps to 504 via Plug.Exception" do
      assert Plug.Exception.status(pg_error(:query_canceled, "57014")) == 504
    end

    test "Postgrex.Error 40001 maps to 503 via Plug.Exception" do
      assert Plug.Exception.status(pg_error(:serialization_failure, "40001")) == 503
    end

    test "unmapped Postgrex.Error maps to 500 via Plug.Exception" do
      assert Plug.Exception.status(pg_error(:undefined_table, "42P01")) == 500
    end

    # Finding #2 (US-27.3): the uncaught Plug.Exception path and the rescue path
    # AGREE on 400 for 22021 (invalid UTF-8 in input), preserving phoenix_ecto's
    # prior special case rather than diverging (uncaught 400 vs rescued 500).
    test "Postgrex.Error 22021 character_not_in_repertoire maps to 400 via Plug.Exception" do
      assert Plug.Exception.status(pg_error(:character_not_in_repertoire, "22021")) == 400
    end

    test "rescue path and Plug.Exception path agree on status for 22021", %{conn: conn} do
      error = pg_error(:character_not_in_repertoire, "22021")
      rescued = call_fallback(conn, {:error, error})
      assert rescued.status == Plug.Exception.status(error)
    end

    test "DBConnection.ConnectionError maps to 503 via Plug.Exception" do
      assert Plug.Exception.status(%DBConnection.ConnectionError{message: "closed"}) == 503
    end

    test "ErrorJSON renders safe, labelled 504/503 bodies" do
      assert %{error: %{status: 504, code: "db_statement_timeout", message: msg}} =
               LoopctlWeb.ErrorJSON.render("504.json", %{})

      assert is_binary(msg)
      refute msg =~ "SELECT"

      assert %{error: %{status: 503, code: "db_unavailable"}} =
               LoopctlWeb.ErrorJSON.render("503.json", %{})
    end
  end

  describe "DBError unit mapping" do
    alias LoopctlWeb.DBError

    test "db_error?/1 recognizes the two DB structs only" do
      assert DBError.db_error?(pg_error(:query_canceled, "57014"))
      assert DBError.db_error?(%DBConnection.ConnectionError{message: "x"})
      refute DBError.db_error?(%RuntimeError{message: "x"})
      refute DBError.db_error?(:not_found)
    end

    test "map/1 returns :unmapped for non-DB errors" do
      assert DBError.map(%RuntimeError{message: "boom"}) == :unmapped
      assert DBError.map(:not_found) == :unmapped
    end

    test "sqlstate/1 surfaces the numeric pg_code, never nil for Postgrex" do
      assert DBError.sqlstate(pg_error(:query_canceled, "57014")) == "57014"
      assert DBError.sqlstate(%DBConnection.ConnectionError{message: "x"}) == nil
    end
  end
end
