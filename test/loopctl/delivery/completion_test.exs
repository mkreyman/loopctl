defmodule Loopctl.Delivery.CompletionTest do
  @moduledoc """
  The loop's last transition, `verified -> done` (#803 §3).

  Nothing in `lib/` wrote this edge, so a story that passed every gate stopped one stage from
  the end of the line for ever — `verified` is not a runner source stage, carries no
  `:session_escalated`, and `:human_resolution` LEAVES `escalated` rather than reaching it, so
  not even an operator could move it. The same defect as `triaged -> queued` (#847), at the
  other end of the line.

  `async: false` and COMMITTED, for the reason `Loopctl.Delivery.PostDeployVerificationTest`
  records and this module shares: the sweep's candidate read is a FLEET-WIDE query on
  `Loopctl.AdminRepo` that resolves the tenant from the row rather than assuming one, while
  the stage write goes through the RLS `Loopctl.Repo`. Two sandbox connections cannot see each
  other's uncommitted rows, so a sandboxed version of this file would assert a selection that
  never sees its own fixtures. `sweep_committed_runner_tenants/0` removes them.

  Every test binds a fact the sweep reads. The two that matter most are the SETTLEMENT rule's
  halves: a story whose reporter is still owed a comment must WAIT, and a story that owes
  nobody anything must not wait for ever.
  """

  use Loopctl.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Completion
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @epoch 2

  setup do
    sweep_committed_runner_tenants()
    %{tenant: fixture(:committed_tenant, %{trust_tier: :human_anchored})}
  end

  defp unboxed(fun) do
    Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Loopctl.Repo, fun) end)
  end

  # A story at `verified`: the stage the loop leaves it in once the deploy has been checked.
  defp verified_story(ctx) do
    story = fixture(:committed_story, %{tenant_id: ctx.tenant.id})

    unboxed(fn ->
      # The STORY's epoch is what `advance/4` fences on — the stage row's is what the sweep
      # READS and passes back. They agree on every story the loop actually produces; the
      # epoch test below is the one that drives them apart on purpose.
      {1, _} =
        AdminRepo.update_all(
          from(s in Loopctl.WorkBreakdown.Story, where: s.id == ^story.id),
          set: [claim_epoch: @epoch]
        )

      fixture(:story_stage, %{
        repo: AdminRepo,
        tenant_id: ctx.tenant.id,
        story_id: story.id,
        stage: :verified,
        claim_epoch: @epoch
      })
    end)

    story
  end

  # The row's CHECK ties each terminal status to its own evidence column
  # (`intake_issue_closures_terminal_shape`), so a fixture that set only the status would be
  # writing a shape the table refuses — and a test built on it would prove nothing about the
  # rows the drainer actually produces.
  defp closure(ctx, story, status) do
    extra =
      case status do
        :closed -> %{closed_at: DateTime.utc_now()}
        :abandoned -> %{abandoned_reason: "retries_exhausted"}
        :pending -> %{}
      end

    unboxed(fn ->
      fixture(
        :issue_closure,
        Map.merge(
          %{repo: AdminRepo, tenant_id: ctx.tenant.id, story_id: story.id, status: status},
          extra
        )
      )
    end)
  end

  defp candidate_ids(limit \\ 50),
    do: unboxed(fn -> Enum.map(Completion.candidates(limit), & &1.story_id) end)

  defp stage_of(story), do: unboxed(fn -> Stages.get(story.tenant_id, story.id) end).stage

  defp complete(story, opts \\ []) do
    unboxed(fn ->
      Completion.complete(story.tenant_id, story.id,
        claim_epoch: Keyword.get(opts, :claim_epoch, @epoch)
      )
    end)
  end

  describe "candidates/1 — the settlement rule" do
    test "a story that owes the reporter NOTHING is a candidate", ctx do
      # THE CLASS A NAIVE RULE STRANDS. A story from no intake record has no closure row, so a
      # rule keyed on the row being terminal would never complete it — every backfill and every
      # API-created story would sit at `verified` for ever while the sweep reported a clean
      # run. That is this module's own defect, reintroduced one layer down.
      story = verified_story(ctx)
      assert story.id in candidate_ids()
    end

    test "a story whose closure is still PENDING is NOT a candidate", ctx do
      story = verified_story(ctx)
      closure(ctx, story, :pending)

      # The reporter has been promised something and nothing has been said to them yet. The
      # drainer is working or backing off; `done` would be a false statement about the story.
      refute story.id in candidate_ids()
    end

    test "a CLOSED closure settles the obligation", ctx do
      story = verified_story(ctx)
      closure(ctx, story, :closed)
      assert story.id in candidate_ids()
    end

    test "an ABANDONED closure settles it too, deliberately", ctx do
      story = verified_story(ctx)
      closure(ctx, story, :abandoned)

      # The drainer gave up and LEFT THE ROW for a person to read. Treating that as unsettled
      # would hold the story at `verified` for ever over an outward act that is never going to
      # happen — the same absorbing state, entered through the error path instead.
      assert story.id in candidate_ids()
    end

    test "a story at any OTHER stage is nobody's business here", ctx do
      story = fixture(:committed_story, %{tenant_id: ctx.tenant.id})

      unboxed(fn ->
        fixture(:story_stage, %{
          repo: AdminRepo,
          tenant_id: ctx.tenant.id,
          story_id: story.id,
          stage: :deployed,
          claim_epoch: @epoch
        })
      end)

      refute story.id in candidate_ids()
    end
  end

  describe "complete/3" do
    test "takes verified -> done, and the story is finished with", ctx do
      story = verified_story(ctx)

      assert {:ok, row} = complete(story)
      assert row.stage == :done
      assert stage_of(story) == :done
    end

    test "a PENDING closure written after the candidate read still waits", ctx do
      # The re-check inside `complete/3`, which is NOT redundant with the query: the candidate
      # set and the write happen at different instants, and completing a story whose reporter
      # is still owed a comment is the one outcome the settlement rule exists to prevent.
      story = verified_story(ctx)
      closure(ctx, story, :pending)

      assert {:waiting, :closure_pending} = complete(story)
      assert stage_of(story) == :verified
    end

    test "a second pass over a completed story is stale_stage, not a second transition", ctx do
      story = verified_story(ctx)

      assert {:ok, _} = complete(story)
      assert {:error, :stale_stage} = complete(story)

      # Two nodes sweeping one batch resolve this way, and it is the design working rather
      # than a fault — which is why the worker counts it apart from an error.
      assert stage_of(story) == :done
    end

    test "an epoch that is not the story's writes nothing", ctx do
      story = verified_story(ctx)

      assert {:error, :stale_claim_epoch} = complete(story, claim_epoch: @epoch + 1)
      assert stage_of(story) == :verified
    end
  end

  describe "the transition is the machine's, not this module's" do
    test "it names an edge the stage machine actually declares" do
      # Asserted through the machine rather than by restating the tuple: a module writing a
      # transition the machine does not have would be refused at runtime, and a test that
      # hardcoded the tuple would agree with the module while both disagreed with the machine.
      {from, to, edge} = Completion.transition()

      assert {from, to, edge} in StageMachine.transitions()
      assert from == :verified
      assert to == :done
    end

    test "this is the only edge out of verified that anything WRITES" do
      # The assertion that would have caught the original defect, and it has to say "writes"
      # rather than "declares" because `verified` declares two.
      #
      # `{:verified, :failed, :budget_exceeded}` is one of the twelve `:budget_exceeded` edges
      # the machine declares from every live stage, and NOTHING IN `lib/` PASSES THAT EDGE —
      # no call site, no worker, no route. It is reserved, not broken: budget exhaustion is
      # already handled without it, because the runner stops at `wall_clock_seconds`,
      # `Capacity.heal/3` releases the reservation and the claim reclaimer requeues the story
      # over `:runner_lost`. Routing it to `:failed` instead would TERMINATE stories that
      # should be retried, which is a policy nobody has chosen.
      #
      # So a reader counting declared edges out of `verified` finds two and concludes it was
      # never absorbing. It was: one of the two has no writer, and this test is where that is
      # written down.
      out = Enum.filter(StageMachine.transitions(), fn {from, _, _} -> from == :verified end)

      assert Enum.sort(out) ==
               Enum.sort([{:verified, :done, :forward}, {:verified, :failed, :budget_exceeded}]),
             "verified's declared edges changed; found #{inspect(out)}"

      writable = Enum.reject(out, fn {_, _, edge} -> edge == :budget_exceeded end)

      assert [Completion.transition()] == writable,
             "the only WRITABLE edge out of verified must be the one this module writes"
    end
  end
end
