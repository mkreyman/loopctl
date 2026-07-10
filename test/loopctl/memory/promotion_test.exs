defmodule Loopctl.Memory.PromotionTest do
  use Loopctl.DataCase, async: true

  import Ecto.Query
  import Mox

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema

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
  end

  # ---------------------------------------------------------------------------
  # TC-29.2.10 — TTL-vs-promotion safety invariant
  # ---------------------------------------------------------------------------

  describe "TTL invariant (AC-29.2.10)" do
    test "the sweep window is strictly shorter than the session-memory TTL" do
      assert Memory.promotion_sweep_window_seconds() < Memory.session_memory_ttl_seconds()
      assert :ok = Memory.assert_promotion_ttl_invariant!()
    end
  end
end
