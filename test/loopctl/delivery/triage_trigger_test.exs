defmodule Loopctl.Delivery.TriageTriggerTest do
  @moduledoc """
  Issue #803 §2/§4: a reported issue becomes a story the delivery loop can see.

  `async: false`, and COMMITTED rather than sandboxed, for the same reason
  `Loopctl.Delivery.PlacementTest` is — a fact about the code under test, not a convenience.
  `promote/1` straddles BOTH repos: it reads the source and creates the story through
  `AdminRepo` (`Loopctl.WorkBreakdown.Stories.create_story/3` is an `AdminRepo` transaction),
  then `Loopctl.Delivery.Stages.open/3` reads that story on the RLS `Loopctl.Repo` inside
  `in_tenant/2`. The two sandbox connections cannot see each other's uncommitted work, so a
  sandboxed story is invisible to the stage open and its `FOR SHARE` share-lock fails.

  Everything promotion touches is therefore committed via `fixture(:committed_tenant)` and
  `fixture(:committed_intake)`, and `sweep_committed_runner_tenants/0` removes it at both
  boundaries.
  """

  use Loopctl.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageTrigger

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  setup do
    %{tenant: fixture(:committed_tenant, %{})}
  end

  describe "promote/1" do
    test "creates the story linked to the record, in the source's epic, at `detected`", %{
      tenant: tenant
    } do
      {source, record} =
        fixture(:committed_intake, %{tenant_id: tenant.id, issue_number: 412})

      assert {:ok, story} = unboxed(fn -> TriageTrigger.promote(record) end)

      # All three bindings, because each is a different half of "the loop can see it": the
      # link is how triage finds its record back, the epic is where a human looks for it, and
      # the stage row is the only thing `Loopctl.Delivery.Placement` selects on.
      assert story.intake_record_id == record.id
      assert story.epic_id == source.target_epic_id

      row = unboxed(fn -> Stages.get(tenant.id, story.id) end)
      assert row.stage == :detected
    end

    test "the stub title carries NO reporter text", %{tenant: tenant} do
      canary = "CANARY-REPORTER-TITLE-9f3a"

      {_source, record} =
        fixture(:committed_intake, %{
          tenant_id: tenant.id,
          issue_number: 412,
          repo_full_name: "mkreyman/home_care_billing",
          untrusted_title: canary
        })

      assert {:ok, story} = unboxed(fn -> TriageTrigger.promote(record) end)

      # Design §10: the implementer never sees the reporter's words, and a stub created BEFORE
      # triage has no trio behind it — so anything it borrowed from the report would be
      # reporter text wearing a story's clothes. `stories.title` is read by every later reader,
      # the implementer prompt included, which is why the canary is asserted against the title
      # rather than against a shape.
      refute story.title =~ canary

      # And the positive half, or the test passes on a title that says nothing: what IS there
      # is loopctl's own facts.
      assert story.title =~ "mkreyman/home_care_billing"
      assert story.title =~ "412"
    end

    test "promoting twice returns the same story and leaves exactly one of everything", %{
      tenant: tenant
    } do
      {_source, record} =
        fixture(:committed_intake, %{tenant_id: tenant.id, issue_number: 412})

      assert {:ok, first} = unboxed(fn -> TriageTrigger.promote(record) end)
      assert {:ok, second} = unboxed(fn -> TriageTrigger.promote(record) end)

      # Triage creates stories over a network, so its create is at-least-once: a response lost
      # in flight makes it retry, and a retry that produced a SECOND story would give one
      # reported issue two backlog entries and two implementers.
      assert second.id == first.id
      assert unboxed(fn -> stories_for_record(record.id) end) == 1
      assert unboxed(fn -> stage_rows_for_story(first.id) end) == 1
    end

    test "a source naming no target epic escalates rather than guessing", %{tenant: tenant} do
      {_source, record} =
        fixture(:committed_intake, %{
          tenant_id: tenant.id,
          issue_number: 412,
          target_epic_id: nil
        })

      # The alternatives were for this worker to find-or-create an epic — making a webhook's
      # arrival a writer of work-breakdown structure — or to pick one by a rule nobody
      # declared. Both put the story somewhere; the refusal is what sends the question to the
      # operator who can answer it.
      assert {:error, :no_target_epic} = unboxed(fn -> TriageTrigger.promote(record) end)
      assert unboxed(fn -> stories_for_record(record.id) end) == 0
    end

    # Found by the FULL SUITE after passing in isolation: build(:epic) uses a raw unique
    # integer, small alone and six digits in a whole run. That exposed a real disagreement
    # between two schemas rather than a fixture quirk — epics.number is validated only
    # greater_than: 0 while a story number's parts must be under 10_000, so an epic numbered
    # at or above that is legal and every story in it is unnumberable. Every hand-authored
    # story has silently assumed otherwise; this is the first caller to construct one.
    test "an epic numbered past the story-number ceiling is refused, not worked around", %{
      tenant: tenant
    } do
      {_source, record} =
        fixture(:committed_intake, %{tenant_id: tenant.id, epic_number: 10_000})

      assert {:error, :epic_number_unnumberable} =
               unboxed(fn -> TriageTrigger.promote(record) end)

      assert unboxed(fn -> stories_for_record(record.id) end) == 0
    end

    test "a revoked source is not promoted", %{tenant: tenant} do
      {_source, record} =
        fixture(:committed_intake, %{
          tenant_id: tenant.id,
          issue_number: 412,
          revoked_at: DateTime.utc_now()
        })

      # The webhook binding is gone, so nothing can close the reporter's issue afterwards and
      # a story nobody can answer is worse than a record sitting still.
      assert {:error, :source_revoked} = unboxed(fn -> TriageTrigger.promote(record) end)
      assert unboxed(fn -> stories_for_record(record.id) end) == 0
    end

    test "two repositories reporting one issue number get different story numbers", %{
      tenant: tenant
    } do
      {first_source, first_record} =
        fixture(:committed_intake, %{
          tenant_id: tenant.id,
          issue_number: 412,
          repo_full_name: "mkreyman/home_care_billing"
        })

      # SAME project, so both stories land in one `stories_tenant_id_project_id_number_index`
      # space; different repository, because that is the only way two records can carry one
      # issue number. Without the disambiguation branch the second create collides on the
      # number and the second reported issue silently never becomes a story.
      {_second_source, second_record} =
        fixture(:committed_intake, %{
          tenant_id: tenant.id,
          project_id: first_source.project_id,
          issue_number: 412,
          repo_full_name: "mkreyman/cron_books"
        })

      assert {:ok, first} = unboxed(fn -> TriageTrigger.promote(first_record) end)
      assert {:ok, second} = unboxed(fn -> TriageTrigger.promote(second_record) end)

      assert first.number != second.number
    end
  end

  defp unboxed(fun) do
    Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Loopctl.Repo, fun) end)
  end

  defp stories_for_record(record_id) do
    AdminRepo.aggregate(
      from(s in "stories", where: s.intake_record_id == type(^record_id, :binary_id)),
      :count
    )
  end

  defp stage_rows_for_story(story_id) do
    AdminRepo.aggregate(
      from(r in "story_stages", where: r.story_id == type(^story_id, :binary_id)),
      :count
    )
  end
end
