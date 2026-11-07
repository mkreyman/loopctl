defmodule Loopctl.Agents.ReplyDraftCandidatesTest do
  @moduledoc """
  US-48.9 (AC-48.9.1): `reply_draft@1`'s candidate read — a story TRIAGE set aside (rejected or
  escalated over triage's own edge), whose intake record carries a support `ticket_id`, with no
  `reply_drafts` row and no live reply_draft dispatch — and the three predicates it added to
  the closed set: `:triage_set_aside`, `:ticket_required`, `:no_reply_draft`.

  Every story is put where it is by the real stage machine (`fixture(:set_aside_story)` and
  `Stages.advance/4`), so the predicate is judged against the events `Stages` actually writes.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Candidates
  alias Loopctl.Agents.Specs.ReplyDraftV1
  alias Loopctl.Delivery.Escalations
  alias Loopctl.Delivery.Stages
  alias Loopctl.ReplyDrafts

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    other = fixture(:tenant, %{trust_tier: :human_anchored})
    %{tenant: tenant, other: other}
  end

  defp run(opts \\ []),
    do: ReplyDraftV1.spec() |> Candidates.query([limit: 50] ++ opts) |> AdminRepo.all()

  defp ids(rows), do: rows |> Enum.map(& &1.story_id) |> Enum.sort()

  describe "who is a candidate" do
    test "a ticket triage rejected and one triage escalated are; nothing else is", ctx do
      t = ctx.tenant.id
      rejected = fixture(:set_aside_story, %{tenant_id: t, to: :failed})
      escalated = fixture(:set_aside_story, %{tenant_id: t, to: :escalated})

      # Not set aside by triage: still detected, and accepted to queued.
      _detected = fixture(:detected_story, %{tenant_id: t})
      accepted = fixture(:detected_story, %{tenant_id: t})
      advance(t, accepted.id, {:detected, :triaged, :forward})
      advance(t, accepted.id, {:triaged, :queued, :forward})

      # Set aside by triage, but no ticket on the record.
      _no_ticket = fixture(:set_aside_story, %{tenant_id: t, ticket_id: nil})

      # Set aside, and a draft row already stands — drafted or refused.
      drafted = fixture(:set_aside_story, %{tenant_id: t})
      :ok = ReplyDrafts.refuse(t, drafted.id, :payload_too_large)

      assert ids(run()) == Enum.sort([rejected.id, escalated.id])
    end

    test "a story at failed that a PERSON put there is not set aside by triage", ctx do
      t = ctx.tenant.id

      # Escalated by triage, then closed by a person over `:human_resolution`: its stage is
      # `failed`, the stage a triage reject reaches, but its LATEST transition is the person's,
      # so the stage alone would have admitted it.
      closed = fixture(:set_aside_story, %{tenant_id: t, to: :escalated})

      {:ok, row} =
        Escalations.resolve(t, closed.id,
          to: :failed,
          actor_label: "user:test",
          actor_role: :user,
          actor_lineage: [],
          reason: "not going to happen"
        )

      assert row.stage == :failed
      assert ids(run()) == []
    end

    test "a live reply_draft dispatch excludes the story; a released one does not", ctx do
      t = ctx.tenant.id
      {_raw, runner} = fixture(:runner, %{tenant_id: t, name: "minis", max_sessions: 9})
      live = fixture(:set_aside_story, %{tenant_id: t})
      released = fixture(:set_aside_story, %{tenant_id: t})

      ledger_row(t, runner.id, live.id, nil)
      ledger_row(t, runner.id, released.id, DateTime.utc_now())

      assert ids(run()) == [released.id]
    end
  end

  describe "tenant isolation (TC-48.9.4)" do
    test "a tenant-scoped read returns only that tenant's story", ctx do
      mine = fixture(:set_aside_story, %{tenant_id: ctx.tenant.id})
      theirs = fixture(:set_aside_story, %{tenant_id: ctx.other.id})

      assert ids(run(tenant_id: ctx.tenant.id)) == [mine.id]
      assert ids(run(tenant_id: ctx.other.id)) == [theirs.id]
      assert ids(run()) == Enum.sort([mine.id, theirs.id])
    end

    test "another tenant's draft row does not exclude my story", ctx do
      mine = fixture(:set_aside_story, %{tenant_id: ctx.tenant.id})
      theirs = fixture(:set_aside_story, %{tenant_id: ctx.other.id})
      :ok = ReplyDrafts.refuse(ctx.other.id, theirs.id, :payload_too_large)

      assert ids(run()) == [mine.id]
    end
  end

  describe "validate/1 over the new predicates" do
    test "reply_draft@1's list is valid" do
      assert Candidates.validate(ReplyDraftV1.spec().candidates) == :ok
    end

    for {predicates, expected} <- [
          {[:triage_set_aside, {:stage, :failed}], "exactly one"},
          {[:triage_set_aside, :ticket_required], ":ticket_required needs"},
          {[:triage_set_aside, :no_reply_draft, :no_reply_draft], "names a predicate twice"}
        ] do
      test "#{inspect(predicates)} is refused" do
        assert {:error, message} =
                 Candidates.validate(%{
                   predicates: unquote(Macro.escape(predicates)),
                   order: :round_robin
                 })

        assert message =~ unquote(expected)
      end
    end

    test "set_aside_transitions/0 is the stage machine's two triage edges out of triaged" do
      assert Enum.sort(Candidates.set_aside_transitions()) ==
               [{:escalated, :triage_escalate}, {:failed, :triage_reject}]
    end
  end

  defp advance(tenant_id, story_id, transition) do
    row = Stages.get(tenant_id, story_id)

    {:ok, _} =
      Stages.advance(tenant_id, story_id, transition,
        claim_epoch: row.claim_epoch,
        actor_label: "worker:triage_dispatcher",
        actor_role: :agent,
        actor_lineage: []
      )
  end

  defp ledger_row(tenant_id, runner_id, story_id, released_at) do
    now = DateTime.utc_now()

    {1, _} =
      AdminRepo.insert_all(Loopctl.Runners.DispatchRecord, [
        %{
          tenant_id: tenant_id,
          runner_id: runner_id,
          dispatch_id: Ecto.UUID.generate(),
          story_id: story_id,
          claim_epoch: 0,
          kind: "reply_draft",
          status: "sent",
          released_at: released_at,
          wall_clock_seconds: 900,
          reserved_at: now,
          slot_generation: 1,
          trace_acked_seq: -1,
          inserted_at: now,
          updated_at: now
        }
      ])

    :ok
  end
end
