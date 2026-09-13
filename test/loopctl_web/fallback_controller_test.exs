defmodule LoopctlWeb.FallbackControllerTest do
  @moduledoc """
  The last clause of `LoopctlWeb.FallbackController` (#824 round 1, finding 1).

  Every other clause is covered where its endpoint is, which is the right place: a mapping
  matters as the status a real request gets. The CATCH-ALL cannot be tested that way by
  construction — it only fires for an atom no clause names, so any endpoint test that reached
  it would be a test of the missing clause instead. It is called directly here.

  What it exists for: before it, an `{:error, atom}` with no clause raised
  `FunctionClauseError` inside the controller. That reached the client as a 500
  indistinguishable from a crash and reached the operator as a stack trace naming this module
  rather than the atom. #824 shipped four reachable atoms with no clause and nothing failed
  until a request hit one.
  """

  use LoopctlWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias LoopctlWeb.FallbackController

  setup :verify_on_exit!

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
