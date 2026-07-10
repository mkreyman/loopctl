defmodule Loopctl.Workers.MemoryPromotionSweepWorkerTest do
  use Loopctl.DataCase, async: true

  import Ecto.Query
  import Mox

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Memory.SessionPromotion
  alias Loopctl.Workers.MemoryPromotionSweepWorker

  defp seed_turns(tenant_id, subject_id, session_id, contents) do
    Enum.each(contents, fn content ->
      fixture(:session_memory,
        tenant_id: tenant_id,
        subject_id: subject_id,
        session_id: session_id,
        role: :user,
        content: content
      )
    end)
  end

  defp stub_llm(text) do
    json =
      JSON.encode!([
        %{
          "text" => text,
          "when_to_apply" => "when relevant",
          "tags" => ["t"],
          "confidence" => 0.9,
          "cross_links" => []
        }
      ])

    stub(Loopctl.MockPromoterLLM, :extract, fn _t, _c, _o -> {:ok, json} end)
  end

  defp promoted_for(tenant_id, subject_id) do
    from(m in MemorySchema,
      where: m.tenant_id == ^tenant_id and m.subject_id == ^subject_id and m.source == :promoted
    )
    |> AdminRepo.all()
  end

  defp watermark_count do
    AdminRepo.aggregate(SessionPromotion, :count, :id)
  end

  defp attach_swept do
    handler = "test-#{inspect(make_ref())}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:loopctl, :memory_promotion, :swept],
      fn _name, meas, meta, _ -> send(test_pid, {:swept, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "perform/1 — cross-tenant attribution (TC-29.2.7)" do
    test "attributes each session to its OWN (tenant, subject) and never mis-pairs" do
      stub_llm("swept durable fact")
      attach_swept()

      tenant_t = fixture(:tenant)
      tenant_u = fixture(:tenant)

      seed_turns(tenant_t.id, "A", "sA", ["ta1", "ta2"])
      seed_turns(tenant_t.id, "B", "sB", ["tb1", "tb2"])
      seed_turns(tenant_u.id, "C", "sC", ["tc1", "tc2"])

      assert :ok = MemoryPromotionSweepWorker.perform(%Oban.Job{args: %{}})

      # Each subject got its own promoted row; none crossed scope.
      assert [a] = promoted_for(tenant_t.id, "A")
      assert a.subject_id == "A" and a.tenant_id == tenant_t.id
      assert a.source_session_id == "sA"

      assert [b] = promoted_for(tenant_t.id, "B")
      assert b.source_session_id == "sB"

      assert [c] = promoted_for(tenant_u.id, "C")
      assert c.tenant_id == tenant_u.id
      assert c.source_session_id == "sC"

      # No cross-tenant leakage.
      assert promoted_for(tenant_t.id, "C") == []
      assert promoted_for(tenant_u.id, "A") == []

      assert_received {:swept, %{sessions: _, enqueued: _}, %{tenant_id: _}}
    end
  end

  describe "perform/1 — per-tick cap (TC-29.2.7)" do
    test "enqueues at most the configured sessions-per-tick" do
      stub_llm("capped fact")
      cap = Application.get_env(:loopctl, :memory_promotion_sweep_max_per_tick)

      # cap + 1 distinct sessions across distinct tenants (so per-tenant budget never
      # binds first) — only `cap` may be enqueued this tick.
      for i <- 1..(cap + 1) do
        tenant = fixture(:tenant)
        seed_turns(tenant.id, "S#{i}", "sess#{i}", ["one", "two"])
      end

      assert :ok = MemoryPromotionSweepWorker.perform(%Oban.Job{args: %{}})

      # Each enqueued (inline) job upserts exactly one watermark → count == cap.
      assert watermark_count() == cap
    end
  end

  describe "perform/1 — watermark pre-filter (TC-29.2.7)" do
    test "an unchanged session (watermark last_turn matches) is not re-enqueued" do
      stub_llm("wm fact")
      tenant = fixture(:tenant)
      seed_turns(tenant.id, "A", "s1", ["one", "two"])

      # First sweep promotes + watermarks the session.
      assert :ok = MemoryPromotionSweepWorker.perform(%Oban.Job{args: %{}})
      assert length(promoted_for(tenant.id, "A")) == 1
      count_after_first = watermark_count()

      # Second sweep with no new turns: pre-filter skips, nothing re-enqueued.
      assert :ok = MemoryPromotionSweepWorker.perform(%Oban.Job{args: %{}})
      assert watermark_count() == count_after_first
      assert length(promoted_for(tenant.id, "A")) == 1
    end
  end
end
