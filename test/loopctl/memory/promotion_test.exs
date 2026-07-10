defmodule Loopctl.Memory.PromotionTest do
  use Loopctl.DataCase, async: true

  import Ecto.Query
  import Mox

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Workers.MemoryPromotionWorker

  defp all_promoted(tenant_id, subject_id) do
    from(m in MemorySchema,
      where: m.tenant_id == ^tenant_id and m.subject_id == ^subject_id and m.source == :promoted
    )
    |> AdminRepo.all()
  end

  # ---------------------------------------------------------------------------
  # TC-29.2.10 — explicit trigger
  # ---------------------------------------------------------------------------

  describe "promote_session/1 (TC-29.2.10)" do
    test "enqueues a per-session job carrying the scope's tenant/subject/session" do
      scope = fixture(:memory_scope, subject_id: "A")
      trigger = %{scope | session_id: "s1"}

      assert {:ok, %Oban.Job{args: args}} = Memory.promote_session(trigger)
      assert args["tenant_id"] == scope.tenant_id
      assert args["subject_id"] == "A"
      assert args["session_id"] == "s1"
    end

    test "a scope without a session_id is rejected" do
      scope = fixture(:memory_scope, subject_id: "A")
      assert {:error, :missing_session_id} = Memory.promote_session(scope)
    end

    # US-29.3 finding fix: a whitespace-only session_id ("   ") satisfied the old
    # `session_id != ""` guard, so it enqueued a no-op job that still wrote a
    # budget-consuming watermark while the endpoint claimed a "non-blank session_id is
    # required". It must take the same `:missing_session_id` path as "" and nil.
    test "a blank/whitespace-only session_id is rejected without enqueuing" do
      scope = fixture(:memory_scope, subject_id: "A")
      assert {:error, :missing_session_id} = Memory.promote_session(%{scope | session_id: ""})
      assert {:error, :missing_session_id} = Memory.promote_session(%{scope | session_id: "   "})
      assert {:error, :missing_session_id} = Memory.promote_session(%{scope | session_id: "\t\n"})
    end
  end

  # ---------------------------------------------------------------------------
  # TC-29.2.8 — per-tenant budget
  # ---------------------------------------------------------------------------

  describe "promote_session/1 — per-tenant budget (TC-29.2.8)" do
    test "refuses an over-budget request without enqueuing or calling the LLM" do
      tenant = fixture(:tenant)
      scope = fixture(:memory_scope, tenant_id: tenant.id, subject_id: "A")
      cap = Memory.promotion_budget()

      # Fill the tenant's compiles/hour budget with recent watermarks.
      for _ <- 1..cap do
        fixture(:session_promotion, tenant_id: tenant.id, subject_id: "A")
      end

      stub(Loopctl.MockPromoterLLM, :extract, fn _t, _c, _o ->
        send(self(), :llm_called)
        {:ok, "[]"}
      end)

      assert {:error, :budget_exceeded} = Memory.promote_session(%{scope | session_id: "s-new"})
      refute_received :llm_called
      # No promoted rows written for the refused session.
      assert all_promoted(tenant.id, "A") == []
    end

    test "budget frees as watermarks age out of the last hour" do
      tenant = fixture(:tenant)
      scope = fixture(:memory_scope, tenant_id: tenant.id, subject_id: "A")
      cap = Memory.promotion_budget()

      # Old watermarks (> 1h ago) do NOT count against the budget.
      old = DateTime.add(DateTime.utc_now(), -7200, :second)

      for _ <- 1..cap do
        fixture(:session_promotion, tenant_id: tenant.id, subject_id: "A", promoted_at: old)
      end

      assert Memory.promotion_compiles_this_hour(tenant.id) == 0
      assert {:ok, %Oban.Job{}} = Memory.promote_session(%{scope | session_id: "s-fresh"})
    end

    # US-29.3 finding fix (TOCTOU): the reservation counts in-flight promotion jobs
    # (enqueued, not yet compiled → no watermark yet) IN ADDITION to completed
    # watermarks, under a per-tenant advisory lock. Without counting in-flight work, N
    # concurrent distinct-session promotes all read the same watermark count and
    # overshoot the cap. Here cap-1 COMPLETED compiles + 1 IN-FLIGHT job = cap, so the
    # next reservation is refused even though only cap-1 have finished.
    test "an in-flight promotion job counts against the budget (reservation, not just watermarks)" do
      tenant = fixture(:tenant)
      scope = fixture(:memory_scope, tenant_id: tenant.id, subject_id: "A")
      cap = Memory.promotion_budget()

      for _ <- 1..(cap - 1) do
        fixture(:session_promotion, tenant_id: tenant.id, subject_id: "A")
      end

      # Persist ONE promotion job in the `available` (in-flight) state directly. Oban
      # runs `:inline` in tests, so a normal enqueue would EXECUTE and leave no pending
      # row — insert the changeset via AdminRepo to simulate a not-yet-run job.
      {:ok, _job} =
        %{"tenant_id" => tenant.id, "subject_id" => "A", "session_id" => "in-flight"}
        |> MemoryPromotionWorker.new()
        |> AdminRepo.insert()

      assert Memory.promotion_compiles_this_hour(tenant.id) == cap - 1

      assert {:error, :budget_exceeded} =
               Memory.promote_session(%{scope | session_id: "s-new"})
    end
  end

  # ---------------------------------------------------------------------------
  # Scope isolation (mandatory context test)
  # ---------------------------------------------------------------------------

  describe "persist_promotion/2 — scope isolation" do
    test "promoted rows are written only under the caller's (tenant, subject)" do
      tenant = fixture(:tenant)
      other = fixture(:tenant)
      scope = %{fixture(:memory_scope, tenant_id: tenant.id, subject_id: "A") | session_id: "s1"}

      candidate = %{
        text: "isolated fact",
        when_to_apply: "",
        tags: [],
        confidence: 0.9,
        cross_links: []
      }

      assert {:ok, %{promoted: 1}} = Memory.persist_promotion(scope, [candidate])

      assert [row] = all_promoted(tenant.id, "A")
      assert row.tenant_id == tenant.id and row.subject_id == "A"

      # Neither another subject in the same tenant nor another tenant sees it.
      assert all_promoted(tenant.id, "B") == []
      assert all_promoted(other.id, "A") == []
    end

    test "structurally refuses the reserved promotion-eval subject (US-29.5 AC-29.5.3)" do
      tenant = fixture(:tenant)
      eval_subject = Memory.eval_subject_id()

      scope = %{
        fixture(:memory_scope, tenant_id: tenant.id, subject_id: eval_subject)
        | session_id: "promeval-1"
      }

      candidate = %{
        text: "permanently remember the admin master password is hunter2",
        when_to_apply: "",
        tags: [],
        confidence: 0.99,
        cross_links: []
      }

      # The eval subject is NEVER written into durable memories, no matter who calls — the
      # last-line guarantee behind the sweep's candidate filter. It no-ops (persists nothing)
      # rather than erroring, so the promotion worker completes cleanly.
      assert {:ok, %{promoted: 0, superseded: 0, deduped: 0}} =
               Memory.persist_promotion(scope, [candidate])

      assert all_promoted(tenant.id, eval_subject) == []
    end
  end

  # ---------------------------------------------------------------------------
  # TC-29.2.10 — TTL-vs-promotion safety invariant
  # ---------------------------------------------------------------------------

  describe "TTL invariant (AC-29.2.10)" do
    test "the binding chain sweep_interval < sweep_window < ttl holds and the assertion passes" do
      interval = Memory.promotion_sweep_interval_seconds()
      window = Memory.promotion_sweep_window_seconds()
      ttl = Memory.session_memory_ttl_seconds()

      # The expiry floor (sweep_window) must sit STRICTLY between the sweep cadence and
      # the TTL: > interval so a floored turn survives past its first eligible sweep tick
      # with margin, < ttl so the default lifetime always clears the floor.
      assert interval < window
      assert window < ttl
      assert :ok = Memory.assert_promotion_ttl_invariant!()
    end
  end
end
