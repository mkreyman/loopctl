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
  alias Loopctl.WorkBreakdown.Stories

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

    test "a story number is chosen across the PROJECT, not within the epic", %{tenant: tenant} do
      {first_source, first_record} =
        fixture(:committed_intake, %{
          tenant_id: tenant.id,
          epic_number: 43,
          repo_full_name: "mkreyman/home_care_billing"
        })

      assert {:ok, first} = unboxed(fn -> TriageTrigger.promote(first_record) end)
      assert first.number == "43.1"

      # The operator's remedy for `:epic_number_unnumberable` is to RENUMBER the epic, and
      # that leaves its existing stories numbered under the OLD major — nothing ties a
      # story's MAJOR to its epic, and nothing renumbers stories. So a later epic legitimately
      # takes the number 43 while story "43.1" is still in the project.
      unboxed(fn -> renumber_epic(first_source.target_epic_id, 44) end)

      {_second_source, second_record} =
        fixture(:committed_intake, %{
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
      assert {:ok, second} = unboxed(fn -> TriageTrigger.promote(second_record) end)
      assert second.number == "43.2"
    end

    test "a target epic that resolves to no epic of this tenant is refused, not raised", %{
      tenant: tenant
    } do
      other_tenant = fixture(:committed_tenant, %{})
      {other_source, _other_record} = fixture(:committed_intake, %{tenant_id: other_tenant.id})

      {_source, record} =
        fixture(:committed_intake, %{
          tenant_id: tenant.id,
          target_epic_id: other_source.target_epic_id
        })

      # The epic read is tenant-scoped, so another tenant's epic resolves to nothing here
      # exactly as a deleted one would. Through `get_by!` that is an `Ecto.NoResultsError`
      # out of a function whose whole contract is `{:ok, _} | {:error, _}` — one misconfigured
      # source taking the worker down instead of escalating its own record.
      assert {:error, :target_epic_missing} = unboxed(fn -> TriageTrigger.promote(record) end)
      assert unboxed(fn -> stories_for_record(record.id) end) == 0
    end

    test "a stage that could not be opened is an error, not a story the loop cannot see", %{
      tenant: tenant
    } do
      {source, record} =
        fixture(:committed_intake, %{tenant_id: tenant.id, epic_number: 43})

      # The story exists and is LINKED to the record but has no stage row — the state a
      # promote whose open failed leaves behind. Created here rather than by a first promote
      # so that the open under test is the FIRST one, and its failure therefore leaves the
      # story genuinely invisible rather than merely re-failing on a row that already exists.
      assert {:ok, story} =
               unboxed(fn ->
                 Stories.create_story(
                   tenant.id,
                   %{
                     epic_id: source.target_epic_id,
                     number: "43.1",
                     title: "Triage pending: already created"
                   },
                   intake_record_id: record.id
                 )
               end)

      # `Stages.open/3` takes the story `FOR SHARE` before it touches the stage row, so a
      # session holding that row `FOR UPDATE` parks the open until the 2s `lock_timeout`
      # `Stages` sets locally fires — the `{:error, :busy}` its moduledoc calls ordinary and
      # retryable. A LOCK, not a sleep: nothing here depends on timing.
      blocker = lock_story(story.id)

      try do
        # The first version of `opened/2` matched `{_row, _}`, which `{:error, :busy}`
        # satisfies as well as `{:ok, row}`: promote answered `{:ok, story}`, the caller
        # marked the record promoted, and the story sat for ever with nothing to advance it
        # and nothing to retry it.
        assert {:error, {:stage_not_opened, :busy}} =
                 unboxed(fn -> TriageTrigger.promote(record) end)
      after
        release(blocker)
      end

      # The half that makes the error true: `Loopctl.Delivery.Placement` selects on the stage
      # row and nothing else, so with no row the loop cannot see this story at all.
      assert unboxed(fn -> Stages.get(tenant.id, story.id) end) == nil
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

  defp renumber_epic(epic_id, number) do
    {1, _} =
      AdminRepo.update_all(
        from(e in "epics", where: e.id == type(^epic_id, :binary_id)),
        set: [number: number]
      )
  end

  # A SEPARATE database session holding one story row `FOR UPDATE`, on its own raw connection
  # rather than a sandbox one: the sandbox owner's connection is the one this test process
  # already runs on, and a lock cannot be held against yourself. Linked to the test process,
  # so it dies with the test even if `release/1` is never reached.
  defp lock_story(story_id), do: lock_story(story_id, 5)

  defp lock_story(story_id, attempts_left) do
    config = Application.get_env(:loopctl, AdminRepo)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: config[:hostname] || "127.0.0.1",
        port: config[:port] || 5432,
        username: config[:username],
        password: config[:password],
        database: config[:database],
        pool_size: 1
      )

    try do
      Postgrex.query!(conn, "BEGIN", [], timeout: 10_000)

      # `num_rows`, asserted: a lock on nothing blocks nothing, and the promote would then
      # succeed for the ordinary reason and this test would prove nothing at all.
      %Postgrex.Result{num_rows: 1} =
        Postgrex.query!(conn, "SELECT id FROM stories WHERE id = $1 FOR UPDATE", [
          Ecto.UUID.dump!(story_id)
        ])

      conn
    rescue
      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        # RETRIED for the reason `release_test.exs` states about its own raw connection: this
        # asks the server for one more at the moment the suite holds the most — three repos'
        # pools plus Oban's notifier, and on this box a second project's suite besides.
        # `too_many_clients` here is a property of WHEN the test runs, not of what it asserts,
        # and a flake of that shape names a change that did not cause it. The failed
        # connection is stopped first: retrying while HOLDING one is the opposite of waiting
        # for room.
        GenServer.stop(conn)

        if attempts_left > 1 do
          Process.sleep(1_000)
          lock_story(story_id, attempts_left - 1)
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  defp release(conn) do
    Postgrex.query!(conn, "ROLLBACK", [])
    GenServer.stop(conn)
  end
end
