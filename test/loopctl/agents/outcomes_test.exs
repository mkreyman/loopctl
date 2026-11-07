defmodule Loopctl.Agents.OutcomesTest do
  @moduledoc """
  US-48.12: the run-outcome ledger — one `agent_run_outcomes` row per dispatch, keyed by its
  spec `{id, version}`, with downstream signals appended by the events that prove them.

  - TC-48.12.1: an implement run's row fills in through merge, each signal from its event.
  - TC-48.12.2: a human's resolution of a triage escalation is recorded as `human_override`.
  - TC-48.12.3: a redelivered session end leaves the row unchanged.
  - TC-48.12.4: one tenant's outcomes never appear in another's summary.

  Every write goes through the existing writer it rides — `RunnerStages.end_session/4`,
  `Stages`, `Progress.record_review/4`, `TriageVerdict.apply/4`, `AgentResult.apply/4`,
  `Escalations.resolve/3` — never through `Outcomes` directly, so each test also proves the
  hook is wired. AdminRepo shares this sandbox connection in test (US-46.2).
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.Agents.AgentResult
  alias Loopctl.Agents.Outcomes
  alias Loopctl.Agents.RunOutcome
  alias Loopctl.Delivery.Escalations
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Delivery.TriageVerdict
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @epoch 4
  @head String.duplicate("a", 40)
  @merge String.duplicate("b", 40)

  defp as_tenant(tenant_id, fun) do
    {:ok, result} = Repo.with_tenant(tenant_id, fun)
    result
  end

  defp outcome(record) do
    as_tenant(record.tenant_id, fn ->
      Repo.one(
        from o in RunOutcome,
          where: o.tenant_id == ^record.tenant_id and o.dispatch_id == ^record.dispatch_id
      )
    end)
  end

  defp outcome_count(tenant_id) do
    as_tenant(tenant_id, fn ->
      Repo.aggregate(from(o in RunOutcome, where: o.tenant_id == ^tenant_id), :count)
    end)
  end

  # An implement story at `stage` under a claim at `@epoch`, with an ACCEPTED implement
  # dispatch, the story reported done by an agent so a review can be recorded against it.
  defp implement_session(stage) do
    story = fixture(:stage_story, %{claim_epoch: @epoch})
    runner = fixture(:stage_runner, %{tenant_id: story.tenant_id})
    agent = fixture(:stage_agent, %{tenant_id: story.tenant_id})

    as_tenant(story.tenant_id, fn ->
      {1, _} =
        from(s in Story, where: s.id == ^story.id)
        |> Repo.update_all(set: [agent_status: :reported_done, assigned_agent_id: agent.id])
    end)

    row =
      fixture(:story_stage, %{
        tenant_id: story.tenant_id,
        story_id: story.id,
        stage: stage,
        claim_epoch: @epoch,
        pr_number: 12,
        head_sha: @head
      })

    record =
      fixture(:accepted_dispatch, %{
        tenant_id: story.tenant_id,
        runner: runner,
        story_id: story.id,
        claim_epoch: @epoch,
        kind: "implement"
      })

    %{story: story, runner: runner, row: row, record: record, agent: agent}
  end

  defp end_session(ctx, reason) do
    RunnerStages.end_session(
      ctx.story.tenant_id,
      ctx.runner.id,
      %{dispatch_id: ctx.record.dispatch_id, claim_epoch: @epoch, reason: reason},
      actor_id: ctx.runner.api_key_id
    )
  end

  defp human_resolve(story, to) do
    Escalations.resolve(story.tenant_id, story.id,
      to: to,
      actor_label: "test:operator",
      actor_role: :user,
      actor_lineage: []
    )
  end

  describe "TC-48.12.1: an implement run's row fills in through merge" do
    test "session end, gate allow, review and merge each land once, from its own event" do
      ctx = implement_session(:ci)
      t = ctx.story.tenant_id

      assert {:ok, _} = end_session(ctx, "completed")

      assert {:ok, _} =
               Stages.record_effect(t, ctx.story.id, :merge_gate_allowed_sha, @head,
                 claim_epoch: @epoch,
                 actor_label: "control:merge_precondition"
               )

      assert {:ok, review} =
               Progress.record_review(
                 t,
                 ctx.story.id,
                 %{
                   "review_type" => "enhanced",
                   "findings_count" => 3,
                   "fixes_count" => 2,
                   "disproved_count" => 1,
                   "completed_at" => DateTime.utc_now()
                 },
                 reviewer_agent_id: nil,
                 reviewer_lineage: []
               )

      assert {:ok, %StoryStage{stage: :merged}} =
               Stages.advance(t, ctx.story.id, {:ci, :merged, :forward},
                 claim_epoch: @epoch,
                 actor_label: "runner:test",
                 actor_lineage: [],
                 effects: [merge_sha: @merge]
               )

      row = outcome(ctx.record)

      # AC-48.12.1: the core columns, from the ledger and the registry.
      assert row.spec_id == "implement"
      assert row.spec_version == 1
      assert row.archetype == "build"
      assert {row.prompt_template_id, row.prompt_template_version} == {"implement", 1}
      assert row.kind == "implement"
      assert row.story_id == ctx.story.id
      assert row.project_id == ctx.story.project_id
      assert row.runner_id == ctx.runner.id
      assert row.started_at == ctx.record.replied_at
      assert %DateTime{} = row.ended_at
      assert is_integer(row.elapsed_s) and row.elapsed_s >= 0
      assert row.end_reason == "completed"
      # No runner message reports either.
      assert row.turns == nil
      assert row.cost_millicents == nil

      # AC-48.12.2: every signal, each naming the event that proved it.
      assert %{"value" => "allow", "source" => "effect:merge_gate_allowed_sha"} =
               row.signals["merge_gate"]

      assert %{
               "value" => %{
                 "findings" => 3,
                 "fixes" => 2,
                 "disproved" => 1,
                 "review_record_id" => review_id
               },
               "source" => "review_record:" <> source_id
             } = row.signals["review_findings"]

      assert review_id == review.id
      assert source_id == review.id

      assert %{"value" => true, "source" => "stage:ci->merged:forward"} = row.signals["merged"]

      assert %{"value" => "green", "source" => "stage:ci->merged:forward"} =
               row.signals["ci_result"]

      for {_name, entry} <- row.signals,
          do: assert({:ok, _, _} = DateTime.from_iso8601(entry["at"]))

      assert outcome_count(t) == 1
    end

    test "a red CI is recorded, and a later merge from ci does not replace it" do
      ctx = implement_session(:ci)
      t = ctx.story.tenant_id

      assert {:ok, _} =
               Stages.advance(t, ctx.story.id, {:ci, :implementing, :ci_red},
                 claim_epoch: @epoch,
                 actor_label: "runner:test"
               )

      assert %{"value" => "red", "source" => "stage:ci->implementing:ci_red"} =
               outcome(ctx.record).signals["ci_result"]

      # Back at ci (set directly: the walk there is not under test), then merged.
      as_tenant(t, fn ->
        {1, _} =
          from(s in StoryStage, where: s.id == ^ctx.row.id)
          |> Repo.update_all(set: [stage: :ci])
      end)

      assert {:ok, %StoryStage{stage: :merged}} =
               Stages.advance(t, ctx.story.id, {:ci, :merged, :forward},
                 claim_epoch: @epoch,
                 actor_label: "runner:test",
                 actor_lineage: [],
                 effects: [merge_sha: @merge]
               )

      signals = outcome(ctx.record).signals
      assert signals["ci_result"]["value"] == "red"
      assert signals["merged"]["value"] == true
    end

    test "a merge-gate refusal is recorded before the session has ended" do
      ctx = implement_session(:ci)
      t = ctx.story.tenant_id

      assert {:ok, _} =
               Stages.advance(t, ctx.story.id, {:ci, :escalated, :merge_gate},
                 claim_epoch: @epoch,
                 actor_label: "control:merge_precondition",
                 actor_lineage: [],
                 reason: "merge_gate: test"
               )

      signals = outcome(ctx.record).signals

      assert %{"value" => "refuse", "source" => "stage:ci->escalated:merge_gate"} =
               signals["merge_gate"]

      refute Map.has_key?(signals, "merged")
      # The row exists from the first signal; the session has not ended.
      assert outcome(ctx.record).ended_at == nil
    end

    test "a budget kill, then a human re-queue, records the requeue on the killed run" do
      ctx = implement_session(:implementing)
      t = ctx.story.tenant_id

      # `runner_id` on the row is what marks an implementer's escalation as the build's.
      as_tenant(t, fn ->
        {1, _} =
          from(s in StoryStage, where: s.id == ^ctx.row.id)
          |> Repo.update_all(set: [runner_id: ctx.runner.id])
      end)

      assert {:ok, %{row: %StoryStage{stage: :escalated}}} =
               end_session(ctx, "wall_clock_exceeded")

      assert {:ok, %StoryStage{stage: :queued}} = human_resolve(ctx.story, :queued)

      row = outcome(ctx.record)
      assert row.end_reason == "wall_clock_exceeded"

      assert %{"value" => true, "source" => "stage:escalated->queued:human_resolution"} =
               row.signals["requeued_after_budget_kill"]

      # A build run carries no human_override: that is the judge's signal.
      refute Map.has_key?(row.signals, "human_override")
    end
  end

  # ── triage ───────────────────────────────────────────────────────────────────────────────

  defp triage_session do
    story = fixture(:stage_story, %{claim_epoch: 0})
    runner = fixture(:stage_runner, %{tenant_id: story.tenant_id})

    fixture(:intake_record, %{
      tenant_id: story.tenant_id,
      project_id: story.project_id,
      repo_full_name: "acme/widgets"
    })

    fixture(:story_stage, %{
      tenant_id: story.tenant_id,
      story_id: story.id,
      stage: :detected,
      claim_epoch: 0
    })

    record =
      fixture(:accepted_dispatch, %{
        tenant_id: story.tenant_id,
        runner: runner,
        story_id: story.id,
        claim_epoch: 0,
        kind: "triage"
      })

    %{story: story, runner: runner, record: record}
  end

  defp verdict(ctx, outcome) do
    TriageVerdict.apply(ctx.story.tenant_id, ctx.runner.id, %{
      dispatch_id: ctx.record.dispatch_id,
      claim_epoch: ctx.record.claim_epoch,
      verdict: %{outcome: outcome, confidence: "high"}
    })
  end

  describe "TC-48.12.2: a human override of a triage verdict" do
    test "triage routes to escalate, a human resolves to queued: human_override true" do
      ctx = triage_session()

      assert {:ok, %{replayed?: false}} = verdict(ctx, "escalate")
      assert Stages.get(ctx.story.tenant_id, ctx.story.id).stage == :escalated

      row = outcome(ctx.record)
      assert row.spec_id == "triage"
      assert row.archetype == "judge"
      assert row.end_reason == "triage_verdict"

      assert %{
               "value" => %{"outcome" => "escalate", "destination" => "escalated"},
               "source" => "triage_verdict"
             } = row.signals["verdict"]

      refute Map.has_key?(row.signals, "human_override")

      assert {:ok, %StoryStage{stage: :queued}} = human_resolve(ctx.story, :queued)

      assert %{"value" => true, "source" => "stage:escalated->queued:human_resolution"} =
               outcome(ctx.record).signals["human_override"]
    end

    test "a re-triage is an override whatever the verdict" do
      ctx = triage_session()

      assert {:ok, _} = verdict(ctx, "escalate")
      assert {:ok, %StoryStage{stage: :detected}} = human_resolve(ctx.story, :detected)

      assert outcome(ctx.record).signals["human_override"]["value"] == true
    end

    test "a resolution to where the verdict itself sent the story is NOT an override" do
      ctx = triage_session()

      assert {:ok, _} =
               TriageVerdict.apply(ctx.story.tenant_id, ctx.runner.id, %{
                 dispatch_id: ctx.record.dispatch_id,
                 claim_epoch: ctx.record.claim_epoch,
                 verdict: %{
                   outcome: "story",
                   confidence: "high",
                   story: %{
                     title: "Screened",
                     description: "D",
                     acceptance_criteria: ["It works"]
                   }
                 }
               })

      t = ctx.story.tenant_id

      # A `story` verdict routes to `queued`; a screen that escalated it instead, and a human
      # who then queued it, agreed with the verdict. Driven at the hook, with the pre-image a
      # screen-escalated row would have.
      %StoryStage{} = current = Stages.get(t, ctx.story.id)
      previous = %{current | stage: :escalated, triage_dispatch_id: ctx.record.dispatch_id}

      as_tenant(t, fn ->
        :ok =
          Outcomes.observe_transition(
            Repo,
            previous,
            previous,
            {:escalated, :queued, :human_resolution}
          )
      end)

      assert outcome(ctx.record).signals["human_override"]["value"] == false
    end

    test "a resent verdict does not record a second outcome" do
      ctx = triage_session()

      assert {:ok, %{replayed?: false}} = verdict(ctx, "reject")
      first = outcome(ctx.record)

      assert {:ok, %{replayed?: true}} = verdict(ctx, "reject")
      assert outcome(ctx.record) == first
      assert first.signals["verdict"]["value"]["destination"] == "failed"
    end
  end

  describe "TC-48.12.3: redelivery does not double count" do
    test "the same session end delivered twice leaves one row, unchanged" do
      ctx = implement_session(:pr_open)

      assert {:ok, %{replayed?: false}} = end_session(ctx, "completed")
      first = outcome(ctx.record)

      assert {:ok, %{replayed?: true}} = end_session(ctx, "completed")

      assert outcome(ctx.record) == first
      assert outcome_count(ctx.story.tenant_id) == 1
    end

    test "a repeated gate event leaves the signal as first written" do
      ctx = implement_session(:ci)
      t = ctx.story.tenant_id

      opts = [claim_epoch: @epoch, actor_label: "control:merge_precondition"]

      assert {:ok, _} =
               Stages.record_effect(t, ctx.story.id, :merge_gate_allowed_sha, @head, opts)

      first = outcome(ctx.record)

      assert {:ok, _} =
               Stages.record_effect(t, ctx.story.id, :merge_gate_allowed_sha, @head, opts)

      assert outcome(ctx.record) == first
    end
  end

  describe "a :draft run" do
    test "its result ends the run, and the stored draft's status is the signal" do
      tenant = fixture(:tenant, %{})
      story = fixture(:set_aside_story, %{tenant_id: tenant.id})
      runner = fixture(:stage_runner, %{tenant_id: tenant.id})

      record =
        fixture(:accepted_dispatch, %{
          tenant_id: tenant.id,
          runner: runner,
          story_id: story.id,
          claim_epoch: story.claim_epoch,
          kind: "reply_draft"
        })

      message = %{
        dispatch_id: record.dispatch_id,
        claim_epoch: record.claim_epoch,
        spec: %{id: "reply_draft", version: 1},
        result: %{"body" => "Thanks for the report; a fix ships this week."}
      }

      assert {:ok, %{replayed?: false}} = AgentResult.apply(tenant.id, runner.id, message)

      row = outcome(record)
      assert {row.spec_id, row.spec_version, row.archetype} == {"reply_draft", 1, "draft"}
      assert row.end_reason == "agent_result"
      assert %{"value" => "drafted", "source" => "agent_result"} = row.signals["draft_screen"]

      assert {:ok, %{replayed?: true}} = AgentResult.apply(tenant.id, runner.id, message)
      assert outcome(record) == row
    end
  end

  # ── summary ──────────────────────────────────────────────────────────────────────────────

  describe "summary/3" do
    test "per-version counts, rates and medians over the window" do
      tenant = fixture(:stage_tenant, %{})
      t = tenant.id
      now = ~U[2026-11-07 12:00:00.000000Z]
      at = fn days -> DateTime.add(now, -days * 86_400, :second) end
      merged = %{"merged" => %{"value" => true}}

      fixture(:agent_run_outcome, %{
        tenant_id: t,
        signals: merged,
        elapsed_s: 100,
        turns: 10,
        inserted_at: at.(1)
      })

      fixture(:agent_run_outcome, %{tenant_id: t, elapsed_s: 300, turns: 30, inserted_at: at.(2)})

      fixture(:agent_run_outcome, %{
        tenant_id: t,
        end_reason: "max_turns_exceeded",
        elapsed_s: 200,
        inserted_at: at.(3)
      })

      fixture(:agent_run_outcome, %{
        tenant_id: t,
        spec_version: 2,
        signals: merged,
        inserted_at: at.(1)
      })

      # Outside the default window, and another spec: neither is counted.
      fixture(:agent_run_outcome, %{tenant_id: t, signals: merged, inserted_at: at.(31)})

      fixture(:agent_run_outcome, %{
        tenant_id: t,
        spec_id: "triage",
        archetype: "judge",
        inserted_at: at.(1)
      })

      assert {:ok, summary} = Outcomes.summary(t, "implement", now: now)
      assert summary.window_days == 30
      assert summary.until == now
      assert summary.since == at.(30)

      assert [v2, v1] = summary.versions
      assert %{spec_version: 2, runs: 1, successes: 1, success_rate: 1.0} = v2

      assert %{
               spec_version: 1,
               runs: 3,
               ended: 3,
               successes: 1,
               human_overrides: 0,
               budget_exhausted: 1,
               median_elapsed_s: 200.0,
               median_turns: 20.0
             } = v1

      assert v1.success_rate == 0.3333
      assert v1.budget_exhausted_rate == 0.3333
      assert v1.human_override_rate == 0.0

      assert {:ok, %{versions: [%{spec_version: 2}, %{spec_version: 1, runs: 1}]}} =
               Outcomes.summary(t, "implement", now: now, window_days: 1)
    end

    test "a judge's success is a verdict no human overrode" do
      t = fixture(:stage_tenant, %{}).id
      judge = %{tenant_id: t, spec_id: "triage", archetype: "judge", end_reason: "triage_verdict"}

      fixture(:agent_run_outcome, judge)

      fixture(
        :agent_run_outcome,
        Map.put(judge, :signals, %{"human_override" => %{"value" => true}})
      )

      fixture(:agent_run_outcome, Map.put(judge, :end_reason, "triage_incomplete"))

      assert {:ok, %{versions: [line]}} = Outcomes.summary(t, "triage")
      assert %{runs: 3, successes: 1, human_overrides: 1} = line
    end

    test "a spec with no rows answers no versions, and a window outside bounds is refused" do
      t = fixture(:stage_tenant, %{}).id

      assert {:ok, %{versions: []}} = Outcomes.summary(t, "implement")
      assert {:error, :invalid_window} = Outcomes.summary(t, "implement", window_days: 0)
      assert {:error, :invalid_window} = Outcomes.summary(t, "implement", window_days: 366)
    end
  end

  describe "TC-48.12.4 / AC-48.12.5: tenant isolation" do
    test "one tenant's outcomes never appear in another's summary" do
      a = fixture(:stage_tenant, %{}).id
      b = fixture(:stage_tenant, %{}).id

      fixture(:agent_run_outcome, %{tenant_id: a, signals: %{"merged" => %{"value" => true}}})
      fixture(:agent_run_outcome, %{tenant_id: b})
      fixture(:agent_run_outcome, %{tenant_id: b})

      assert {:ok, %{versions: [%{runs: 1, successes: 1}]}} = Outcomes.summary(a, "implement")
      assert {:ok, %{versions: [%{runs: 2, successes: 0}]}} = Outcomes.summary(b, "implement")
    end

    test "a story-level signal is credited only to its own tenant's dispatch" do
      ctx = implement_session(:ci)
      other = implement_session(:ci)

      assert {:ok, _} =
               Stages.record_effect(
                 ctx.story.tenant_id,
                 ctx.story.id,
                 :merge_gate_allowed_sha,
                 @head,
                 claim_epoch: @epoch,
                 actor_label: "control:merge_precondition"
               )

      assert outcome(ctx.record).signals["merge_gate"]["value"] == "allow"
      assert outcome(other.record) == nil
      assert outcome_count(other.story.tenant_id) == 0
    end
  end
end
