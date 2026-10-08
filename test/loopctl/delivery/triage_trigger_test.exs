defmodule Loopctl.Delivery.TriageTriggerTest do
  @moduledoc """
  Issue #803 §2/§4: a reported issue becomes a story the delivery loop can see.

  `promote/1` straddles BOTH repos: it reads the source and creates the story through
  `AdminRepo` (`Loopctl.WorkBreakdown.Stories.create_story/3` is an `AdminRepo` transaction),
  then `Loopctl.Delivery.Stages.open/3` reads that story on the RLS `Loopctl.Repo` inside
  `in_tenant/2`. AdminRepo runs on Repo's sandbox connection in test
  (`Loopctl.AdminRepo.Route`), so the stage open sees the story the create just wrote and
  nothing here commits. The one test whose subject is a lock ANOTHER session holds on the
  story is `Loopctl.Delivery.TriageTriggerLockTest`.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageTrigger

  setup :verify_on_exit!

  setup do
    %{tenant: fixture(:tenant, %{trust_tier: :agent_rooted})}
  end

  describe "promote/1" do
    test "creates the story linked to the record, in the source's epic, at `detected`", %{
      tenant: tenant
    } do
      {source, record} =
        fixture(:intake_pair, %{tenant_id: tenant.id, issue_number: 412})

      assert {:ok, story} = TriageTrigger.promote(record)

      # All three bindings, because each is a different half of "the loop can see it": the
      # link is how triage finds its record back, the epic is where a human looks for it, and
      # the stage row is the only thing `Loopctl.Delivery.Placement` selects on.
      assert story.intake_record_id == record.id
      assert story.epic_id == source.target_epic_id

      row = Stages.get(tenant.id, story.id)
      assert row.stage == :detected
    end

    test "the stub title carries NO reporter text", %{tenant: tenant} do
      canary = "CANARY-REPORTER-TITLE-9f3a"

      {_source, record} =
        fixture(:intake_pair, %{
          tenant_id: tenant.id,
          issue_number: 412,
          repo_full_name: "mkreyman/home_care_billing",
          untrusted_title: canary
        })

      assert {:ok, story} = TriageTrigger.promote(record)

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
        fixture(:intake_pair, %{tenant_id: tenant.id, issue_number: 412})

      assert {:ok, first} = TriageTrigger.promote(record)
      assert {:ok, second} = TriageTrigger.promote(record)

      # Triage creates stories over a network, so its create is at-least-once: a response lost
      # in flight makes it retry, and a retry that produced a SECOND story would give one
      # reported issue two backlog entries and two implementers.
      assert second.id == first.id
      assert stories_for_record(record.id) == 1
      assert stage_rows_for_story(first.id) == 1
    end

    test "a source naming no target epic escalates rather than guessing", %{tenant: tenant} do
      {_source, record} =
        fixture(:intake_pair, %{
          tenant_id: tenant.id,
          issue_number: 412,
          target_epic_id: nil
        })

      # The alternatives were for this worker to find-or-create an epic — making a webhook's
      # arrival a writer of work-breakdown structure — or to pick one by a rule nobody
      # declared. Both put the story somewhere; the refusal is what sends the question to the
      # operator who can answer it.
      assert {:error, :no_target_epic} = TriageTrigger.promote(record)
      assert stories_for_record(record.id) == 0
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
        fixture(:intake_pair, %{tenant_id: tenant.id, epic_number: 10_000})

      assert {:error, :epic_number_unnumberable} =
               TriageTrigger.promote(record)

      assert stories_for_record(record.id) == 0
    end

    test "a revoked source is not promoted", %{tenant: tenant} do
      {_source, record} =
        fixture(:intake_pair, %{
          tenant_id: tenant.id,
          issue_number: 412,
          revoked_at: DateTime.utc_now()
        })

      # The webhook binding is gone, so nothing can close the reporter's issue afterwards and
      # a story nobody can answer is worse than a record sitting still.
      assert {:error, :source_revoked} = TriageTrigger.promote(record)
      assert stories_for_record(record.id) == 0
    end

    test "two repositories reporting one issue number get different story numbers", %{
      tenant: tenant
    } do
      {first_source, first_record} =
        fixture(:intake_pair, %{
          tenant_id: tenant.id,
          issue_number: 412,
          repo_full_name: "mkreyman/home_care_billing"
        })

      # SAME project, so both stories land in one `stories_tenant_id_project_id_number_index`
      # space; different repository, because that is the only way two records can carry one
      # issue number. Without the disambiguation branch the second create collides on the
      # number and the second reported issue silently never becomes a story.
      {_second_source, second_record} =
        fixture(:intake_pair, %{
          tenant_id: tenant.id,
          project_id: first_source.project_id,
          issue_number: 412,
          repo_full_name: "mkreyman/cron_books"
        })

      assert {:ok, first} = TriageTrigger.promote(first_record)
      assert {:ok, second} = TriageTrigger.promote(second_record)

      assert first.number != second.number
    end

    test "a story number is chosen across the PROJECT, not within the epic", %{tenant: tenant} do
      {first_source, first_record} =
        fixture(:intake_pair, %{
          tenant_id: tenant.id,
          epic_number: 43,
          repo_full_name: "mkreyman/home_care_billing"
        })

      assert {:ok, first} = TriageTrigger.promote(first_record)
      assert first.number == "43.1"

      # The operator's remedy for `:epic_number_unnumberable` is to RENUMBER the epic, and
      # that leaves its existing stories numbered under the OLD major — nothing ties a
      # story's MAJOR to its epic, and nothing renumbers stories. So a later epic legitimately
      # takes the number 43 while story "43.1" is still in the project.
      renumber_epic(first_source.target_epic_id, 44)

      {_second_source, second_record} =
        fixture(:intake_pair, %{
          tenant_id: tenant.id,
          project_id: first_source.project_id,
          epic_number: 43,
          repo_full_name: "mkreyman/cron_books"
        })

      # An EPIC-scoped scan sees no story under this brand-new epic, picks "43.1" again, and
      # collides on `stories_tenant_id_project_id_number_index` — which is PROJECT-wide. The
      # collision is not self-healing either: every retry recomputes the same number, so the
      # record stalls in `pending_triage` for ever, which is exactly what the moduledoc's
      # "the next run reads a sequence that is now free" promises does not happen.
      assert {:ok, second} = TriageTrigger.promote(second_record)
      assert second.number == "43.2"
    end

    # WHY THERE IS NO TEST FOR :target_epic_missing, and why the branch stays anyway.
    #
    # There was one. It built a source in one tenant pointing at another tenant's epic, which
    # was insertable while the reference was a single column onto `epics(id)`. Round 2 made it
    # composite — `(tenant_id, target_epic_id) REFERENCES epics (tenant_id, id)` — for exactly
    # the reason that fixture demonstrated, so the row the test needs is now refused by the
    # database and the test raised out of its own setup.
    #
    # The branch is NOT deleted with the test. Both routes to it are now closed — a
    # cross-tenant target by the composite FK, a deleted epic by `ON DELETE NO ACTION` plus
    # `Epics.delete_epic/3`'s named constraint — so it is unreachable through every supported
    # path, which is a statement about today's schema rather than a proof. It costs one clause
    # and it fails CLOSED: the alternative to returning `:target_epic_missing` is
    # `Ecto.NoResultsError` out of a function whose contract is ok-or-error, taking the worker
    # down over one misconfigured source. A guard that cannot currently fire is worth keeping
    # when the thing it replaces is a crash.
    #
    # What would make it testable again is a legitimate way to reach it. If one appears, the
    # test comes back with it.
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

  defp renumber_epic(epic_id, number) do
    {1, _} =
      AdminRepo.update_all(
        from(e in "epics", where: e.id == type(^epic_id, :binary_id)),
        set: [number: number]
      )
  end
end
