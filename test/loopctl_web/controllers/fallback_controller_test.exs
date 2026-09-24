defmodule LoopctlWeb.FallbackControllerTest do
  @moduledoc """
  Every clause of `LoopctlWeb.FallbackController`.

  **One module, and it has to be one.** #824 added a second file,
  `test/loopctl_web/fallback_controller_test.exs`, defining this same module name — which
  this file has held since #289. Its tests are the two catch-all describes at the bottom of
  this file now, and the stray file is gone; `test/loopctl_web/controllers/` is where a
  controller test goes here.

  **What that duplicate actually did, because it is worth recognising again.** Elixir's
  parallel compiler has two outcomes for one module name in two files, and WHICH ONE you
  get is a race decided by how the test files interleave across compile workers:

  - both in flight at once — `cannot define module ... because it is currently being
    defined`, a hard CompileError. Deterministic when those are the only two files loaded
    (measured 8/8 locally, and still 8/8 under `ELIXIR_ERL_OPTIONS="+S 1"`).
  - one finishing before the other starts — `warning: redefining module ... (current
    version defined in memory)`, and the suite goes GREEN having run only one of the two
    files' tests.

  So the green branch is the dangerous one: master's CI run for #824 emitted exactly that
  warning and reported 9936 tests, 0 failures, while the same tree could not compile its
  test suite locally. A duplicate module name does not reliably fail — it reliably makes
  the suite lie about what it ran. `mix test --warnings-as-errors` is what turns that
  warning into a failure.
  """

  use LoopctlWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  setup :verify_on_exit!

  alias LoopctlWeb.FallbackController

  defp call_fallback(conn, error) do
    conn
    |> Plug.Conn.put_private(:phoenix_format, "json")
    |> FallbackController.call(error)
  end

  # DBErrorLogger emits a single structured line per error, embedding the conn's
  # request_id (both as Logger metadata and inline). capture_log/1 captures the
  # GLOBAL, process-wide Logger — including DB-error/vector/slow-query lines from
  # OTHER async tests running concurrently — so a bare `refute log =~ "embedding
  # <=>"` (or "0.123", "::vector", "already exists") could be tripped by a
  # sibling's log. Stamp a per-call unique x-request-id and return ONLY this
  # call's own line, so every assert/refute inspects our line and no other.
  defp capture_db_error_log(conn, error) do
    req_id = "flbk-req-#{System.unique_integer([:positive])}"
    conn = Plug.Conn.put_resp_header(conn, "x-request-id", req_id)

    log = ExUnit.CaptureLog.capture_log(fn -> call_fallback(conn, error) end)

    log
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, req_id))
    |> Enum.join("\n")
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

    # #879: a renewal of a driver-placed claim whose cap has passed — a conflict with the
    # claim's state, never a 200 carrying a lease already in the past.
    test "renders 409 lease_cap_reached for :lease_cap_reached", %{conn: conn} do
      conn = call_fallback(conn, {:error, :lease_cap_reached})

      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "lease_cap_reached"
      assert body["error"]["message"] =~ "claim_lease_cap"
      # The 409 releases nothing — the reclaim sweep does, once the lease has ended at the cap.
      assert body["error"]["message"] =~ "this refusal releases nothing"
      assert body["error"]["message"] =~ "the reclaim sweep releases the story"
    end

    # A rolled-back mutation (its audit insert failed) must surface as a 5xx, never a
    # masking 404 — the write did not happen, so the caller must retry rather than
    # believe a leaked secret was removed. The message is CALLER-NEUTRAL: this clause
    # serves the US-39.7 redact path AND every corpus-tier mutation (US-43.2), and a
    # corpus index request has no post to still exist.
    test "renders 500 for :audit_write_failed (never masked as a 404)", %{conn: conn} do
      conn = call_fallback(conn, {:error, :audit_write_failed})

      assert conn.status == 500
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 500
      assert body["error"]["code"] == "audit_write_failed"
      assert body["error"]["message"] =~ "rolled back"
      assert body["error"]["message"] =~ "did NOT happen"
      assert body["error"]["message"] =~ "Retry"
      refute body["error"]["message"] =~ "post"
    end

    # ONE code, ONE status. The same condition already had a rendering — the
    # `HeavyReadOverloadHandler` `Plug.Exception` impl raising through to
    # `ErrorJSON.render("429.json", ...)` — which answers 429 under this exact code. The
    # code exists so a client can tell per-tenant heavy-read backpressure apart from a
    # generic rate-limit 429; two statuses for one code would put it back to guessing,
    # decided only by whether the endpoint asked for `on_overload: :raise` or `:tag`,
    # which is not observable to it.
    test "renders :heavy_read_overloaded as 429 — the status its other rendering uses",
         %{conn: conn} do
      conn = call_fallback(conn, {:error, :heavy_read_overloaded})

      assert conn.status == 429
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["status"] == 429
      assert body["error"]["code"] == "heavy_read_overloaded"
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["1"]

      # Bound to the OTHER rendering rather than to a literal, so the two cannot drift.
      assert body["error"]["code"] ==
               LoopctlWeb.ErrorJSON.render("429.json", %{})[:error][:code]
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
    test "logs sqlstate + mapped_code at error level, no SQL/vector leak", %{conn: conn} do
      log = capture_db_error_log(conn, {:error, pg_error(:query_canceled, "57014")})

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

      log = capture_db_error_log(conn, {:error, error})

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

      log = capture_db_error_log(conn, {:error, error})

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

      log = capture_db_error_log(conn, {:error, error})

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

  # The last clause of `LoopctlWeb.FallbackController` (#824 round 1, finding 1).
  #
  # Every other clause is covered where its endpoint is, which is the right place: a mapping
  # matters as the status a real request gets. The CATCH-ALL cannot be tested that way by
  # construction — it only fires for an atom no clause names, so any endpoint test that
  # reached it would be a test of the missing clause instead. It is called DIRECTLY here,
  # which is why these two describes do not go through `call_fallback/2`.
  #
  # What it exists for: before it, an `{:error, atom}` with no clause raised
  # `FunctionClauseError` inside the controller. That reached the client as a 500
  # indistinguishable from a crash and reached the operator as a stack trace naming this
  # module rather than the atom. #824 shipped four reachable atoms with no clause and
  # nothing failed until a request hit one.
  describe "the catch-all" do
    test "answers 500 for an atom no clause names, and logs the atom", %{conn: conn} do
      log =
        capture_log(fn ->
          conn = FallbackController.call(conn, {:error, :a_reason_no_clause_names})

          assert %{"error" => error} = json_response(conn, 500)
          assert error["code"] == "internal_error"

          # The atom is a context's INTERNAL vocabulary, not a public error code: it goes to
          # the log so an operator can add a clause, and never to the client, who cannot act
          # on it and should not learn it.
          refute error["message"] =~ "a_reason_no_clause_names"
          refute error["code"] =~ "a_reason_no_clause_names"
        end)

      assert log =~ "no clause for :a_reason_no_clause_names"
      assert log =~ "[error]"
    end

    test "does not swallow the shapes that have their own rendering", %{conn: conn} do
      # It matches an ATOM only. A changeset, an `{:error, reason, message}` triple and the
      # named atoms all keep their own status — which is what stops the catch-all from
      # absorbing a new refusal shape that should have failed loudly.
      changeset =
        %Loopctl.WorkBreakdown.Story{}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:title, "is required")

      assert json_response(FallbackController.call(conn, {:error, changeset}), 422)

      assert json_response(
               FallbackController.call(build_conn(), {:error, :bad_request, "say why"}),
               400
             )

      assert json_response(FallbackController.call(build_conn(), {:error, :not_found}), 404)
      assert json_response(FallbackController.call(build_conn(), {:error, :forbidden}), 403)
    end
  end

  describe "the delivery stage machine's vocabulary (#803)" do
    test "the request faults render 422 with their own code" do
      for {fault, status} <- [
            {:reason_required, 422},
            {:invalid_reason, 422},
            {:invalid_event_data, 422},
            {:invalid_effect, 422},
            {:missing_required_effect, 422},
            {:wrong_stage, 422},
            {:effect_conflict, 422},
            {:human_required, 422}
          ] do
        body = json_response(FallbackController.call(build_conn(), {:error, fault}), status)
        assert body["error"]["code"] == Atom.to_string(fault)
        assert body["error"]["message"] != ""
      end
    end

    test "a bare invalid_transition is 409, distinct from the lifecycle's tagged one" do
      bare =
        json_response(FallbackController.call(build_conn(), {:error, :invalid_transition}), 409)

      assert bare["error"]["code"] == "invalid_transition"

      # The story lifecycle's carries the statuses it would have moved between; the stage
      # machine's is bare because its table is a fixed triple. Both are 409 and they are
      # different clauses — a regression that collapsed one into the other would lose the
      # context the tagged one carries, which is the whole reason it has a shape of its own.
      tagged =
        json_response(
          FallbackController.call(
            build_conn(),
            {:error,
             {:invalid_transition,
              %{
                current_agent_status: :pending,
                current_verified_status: :unverified,
                attempted_action: "verify"
              }}}
          ),
          409
        )

      assert tagged["error"]["message"] =~ "pending"
      refute tagged == bare
    end

    test "audit_chain_append_failed is a 500, because nobody can retry their way out of it" do
      body =
        json_response(
          FallbackController.call(build_conn(), {:error, :audit_chain_append_failed}),
          500
        )

      assert body["error"]["code"] == "audit_chain_append_failed"
    end
  end
end
