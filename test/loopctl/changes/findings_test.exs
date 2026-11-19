defmodule Loopctl.Changes.FindingsTest do
  @moduledoc """
  US-51.1: the chg feedback loop's nightly sweep (`Loopctl.Changes.Findings`), its filer
  (`Loopctl.Changes.FindingFiler`) and its drainer (`Loopctl.Workers.ChgFindingActionWorker`),
  against the mocked forge.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Cursor
  alias Loopctl.Changes.Finding
  alias Loopctl.Changes.FindingAction
  alias Loopctl.Changes.FindingFiler
  alias Loopctl.Changes.Findings
  alias Loopctl.Changes.LedgerRow
  alias Loopctl.Delivery.ForgeRepo
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Source
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ChgFindingActionWorker

  setup :verify_on_exit!

  @now ~U[2026-11-19 04:10:00.000000Z]
  @chg_repo "mkreyman/chg"
  @sha String.duplicate("a", 40)

  setup do
    %{source: hcb} = fixture(:chg_source, %{repo_full_name: "mkreyman/home_care_billing"})
    tenant_id = hcb.tenant_id
    %{source: chg} = fixture(:chg_source, %{tenant_id: tenant_id, repo_full_name: @chg_repo})
    %{tenant_id: tenant_id, hcb: hcb, chg: chg}
  end

  defp opts(extra \\ []), do: Keyword.merge([chg_repo: @chg_repo, daily_cap: 5], extra)

  defp ledger!(source, kind, attrs) do
    raw = Map.merge(%{"v" => 1, "kind" => kind}, Map.get(attrs, :raw, %{}))

    AdminRepo.insert!(%LedgerRow{
      tenant_id: source.tenant_id,
      source_id: source.id,
      repo: Map.get(attrs, :repo, "home_care_billing"),
      host: "minis",
      kind: kind,
      sha: Map.get(attrs, :sha),
      verdict: Map.get(attrs, :verdict),
      at: Map.get(attrs, :at, DateTime.add(@now, -3600, :second)),
      raw: raw,
      row_hash: Ecto.UUID.generate()
    })
  end

  defp selection_miss!(source, attrs \\ %{}) do
    sha = Map.get(attrs, :sha, @sha)
    at = Map.get(attrs, :at, DateTime.add(@now, -3600, :second))
    mode = Map.get(attrs, :mode, "affected")

    ledger!(source, "chg", %{sha: sha, verdict: "pass", at: at, raw: %{"mode" => mode}})
    ledger!(source, "gate", %{sha: sha, verdict: Map.get(attrs, :gate, "fail"), at: at})
  end

  defp flaky!(source, test, attrs \\ %{}) do
    ledger!(source, "flaky", %{
      at: Map.get(attrs, :at, DateTime.add(@now, -3600, :second)),
      raw: Map.merge(%{"test" => test}, Map.get(attrs, :raw, %{}))
    })
  end

  defp cursor!(source, attention_at) do
    AdminRepo.insert!(%Cursor{
      tenant_id: source.tenant_id,
      source_id: source.id,
      repo: "home_care_billing",
      change_id: "01J" <> Integer.to_string(System.unique_integer([:positive])),
      applied_seq: 3,
      last_event_at: attention_at,
      attention: "gap",
      attention_at: attention_at
    })
  end

  defp findings(tenant_id), do: Findings.list(tenant_id)

  defp actions(tenant_id) do
    AdminRepo.all(from a in FindingAction, where: a.tenant_id == ^tenant_id)
  end

  describe "derive/3" do
    test "a selecting chg pass whose gate failed is a selection miss filed on chg", ctx do
      selection_miss!(ctx.hcb)

      assert [s] = Findings.derive(ctx.tenant_id, @now, opts())
      assert s.kind == "selection_miss"
      assert s.repo_full_name == @chg_repo
      assert s.fingerprint == "home_care_billing@#{@sha}"
      assert s.evidence["gate_row"]["kind"] == "gate"
    end

    test "the gate's failures are part of a miss's fingerprint", ctx do
      sha = String.duplicate("d", 40)
      ledger!(ctx.hcb, "chg", %{sha: sha, verdict: "pass", raw: %{"mode" => "affected"}})

      ledger!(ctx.hcb, "gate", %{
        sha: sha,
        verdict: "fail",
        raw: %{
          "failures" => [
            "test/b_test.exs:2",
            %{"id" => "test/a_test.exs:1"},
            7,
            "test/b_test.exs:2"
          ]
        }
      })

      assert [s] = Findings.derive(ctx.tenant_id, @now, opts())
      assert s.fingerprint =~ ~r/\Ahome_care_billing@#{sha}:[0-9a-f]{12}\z/

      # US-51.5: the failed tests by name, what a fix's replay must cover.
      assert s.evidence["failures"] == ["test/a_test.exs:1", "test/b_test.exs:2"]
    end

    test "a full run, a passing gate, or a row outside the window is not a miss", ctx do
      selection_miss!(ctx.hcb, %{mode: "all"})
      selection_miss!(ctx.hcb, %{sha: String.duplicate("b", 40), gate: "pass"})

      selection_miss!(ctx.hcb, %{
        sha: String.duplicate("c", 40),
        at: DateTime.add(@now, -Findings.window_hours() * 3600 - 60, :second)
      })

      assert Findings.derive(ctx.tenant_id, @now, opts()) == []
    end

    test "an unquarantined flaky test is a finding on its source's repository", ctx do
      flaky!(ctx.hcb, "test/a_test.exs:12")
      flaky!(ctx.hcb, "test/b_test.exs:3", %{raw: %{"quarantine" => "#99"}})

      assert [s] = Findings.derive(ctx.tenant_id, @now, opts())
      assert s.kind == "flaky_test"
      assert s.repo_full_name == "mkreyman/home_care_billing"
      assert s.fingerprint == "home_care_billing:test/a_test.exs:12"
    end

    test "a cursor flagged for longer than the threshold is a stuck change", ctx do
      old = DateTime.add(@now, -(Findings.stuck_after_hours() + 1) * 3600, :second)
      cursor!(ctx.hcb, old)
      cursor!(ctx.hcb, DateTime.add(@now, -600, :second))

      assert [s] = Findings.derive(ctx.tenant_id, @now, opts())
      assert s.kind == "stuck_change"
      assert s.evidence["attention"] == "gap"
    end

    test "a row of a revoked source is skipped: nowhere to file", ctx do
      flaky!(ctx.hcb, "test/a_test.exs:12")
      AdminRepo.update_all(from(s in Source, where: s.id == ^ctx.hcb.id), set: [revoked_at: @now])

      assert Findings.derive(ctx.tenant_id, @now, opts()) == []
    end

    test "evidence carries only bounded scalar fields of the row", ctx do
      ledger!(ctx.hcb, "flaky", %{
        raw: %{"test" => "t", "nested" => %{"x" => 1}, "long" => String.duplicate("z", 500)}
      })

      assert [s] = Findings.derive(ctx.tenant_id, @now, opts())
      refute Map.has_key?(s.evidence["row"], "nested")
      assert String.length(s.evidence["row"]["long"]) == 200
    end
  end

  describe "record_sightings/3" do
    test "a rerun over the same rows counts nothing twice; a newer row adds", ctx do
      flaky!(ctx.hcb, "t1")
      Findings.sweep_tenant(ctx.tenant_id, @now, opts(daily_cap: 0))
      Findings.sweep_tenant(ctx.tenant_id, @now, opts(daily_cap: 0))

      assert [%Finding{occurrences: 1}] = findings(ctx.tenant_id)

      flaky!(ctx.hcb, "t1", %{at: DateTime.add(@now, -60, :second)})
      Findings.sweep_tenant(ctx.tenant_id, @now, opts(daily_cap: 0))

      assert [%Finding{occurrences: 2, state: :queued}] = findings(ctx.tenant_id)
    end
  end

  describe "plan_filing/3" do
    test "files one open action per finding, once", ctx do
      flaky!(ctx.hcb, "t1")
      assert %{filed: 1} = Findings.sweep_tenant(ctx.tenant_id, @now, opts())
      assert %{filed: 0} = Findings.sweep_tenant(ctx.tenant_id, @now, opts())

      assert [%Finding{state: :filed, filed_at: %DateTime{}} = f] = findings(ctx.tenant_id)
      assert [%FindingAction{action: :open, status: :pending} = a] = actions(ctx.tenant_id)
      assert a.finding_id == f.id
      assert a.repo_full_name == "mkreyman/home_care_billing"
      assert a.title =~ Findings.title_token(a.id)
      assert a.body =~ Findings.marker(a.id)
      assert a.body =~ "UNTRUSTED DATA field=chg_finding_evidence"
    end

    test "caps new issues per repository per day, most-seen first", ctx do
      flaky!(ctx.hcb, "t1")
      flaky!(ctx.hcb, "t2")
      flaky!(ctx.hcb, "t2", %{at: DateTime.add(@now, -120, :second)})
      flaky!(ctx.hcb, "t3")

      assert %{filed: 1} = Findings.sweep_tenant(ctx.tenant_id, @now, opts(daily_cap: 1))

      filed = Enum.filter(findings(ctx.tenant_id), &(&1.state == :filed))
      assert [%Finding{fingerprint: "home_care_billing:t2"}] = filed

      # The same day: the cap is spent. The next day: one more.
      assert %{filed: 0} = Findings.sweep_tenant(ctx.tenant_id, @now, opts(daily_cap: 1))
      tomorrow = DateTime.add(@now, 86_400, :second)

      assert Findings.plan_filing(ctx.tenant_id, tomorrow, opts(daily_cap: 1)) == 1
    end

    test "a finding whose repository has no live source stays queued", ctx do
      selection_miss!(ctx.hcb)
      AdminRepo.update_all(from(s in Source, where: s.id == ^ctx.chg.id), set: [revoked_at: @now])

      assert %{filed: 0} = Findings.sweep_tenant(ctx.tenant_id, @now, opts())
      assert [%Finding{state: :queued, kind: "selection_miss"}] = findings(ctx.tenant_id)
      assert actions(ctx.tenant_id) == []
    end
  end

  describe "loop depth" do
    test "a sighting on the merge of a loop-made story escalates at the max depth", ctx do
      # An earlier finding at depth 1 whose issue the loop made a story from, merged as @sha.
      record =
        fixture(:intake_record, %{
          tenant_id: ctx.tenant_id,
          repo: AdminRepo,
          repo_full_name: @chg_repo,
          issue_number: 41
        })

      story = fixture(:story, %{tenant_id: ctx.tenant_id})

      AdminRepo.update_all(from(s in Story, where: s.id == ^story.id),
        set: [intake_record_id: record.id]
      )

      fixture(:story_stage, %{
        tenant_id: ctx.tenant_id,
        story_id: story.id,
        repo: AdminRepo,
        merge_sha: @sha
      })

      AdminRepo.insert!(%Finding{
        tenant_id: ctx.tenant_id,
        kind: "selection_miss",
        fingerprint: "earlier",
        # Differs from the source's only by case: repositories compare case-folded.
        repo_full_name: String.upcase(@chg_repo),
        state: :fixed,
        first_seen_at: @now,
        last_seen_at: @now,
        loop_depth: Findings.max_loop_depth() - 1,
        issue_number: 41
      })

      selection_miss!(ctx.hcb)
      Findings.sweep_tenant(ctx.tenant_id, @now, opts())

      new =
        Findings.get_by_fingerprint(ctx.tenant_id, "selection_miss", "home_care_billing@#{@sha}")

      assert %Finding{state: :escalated, loop_depth: depth} = new
      assert depth == Findings.max_loop_depth()
      assert new.escalated_reason == "loop_depth_#{depth}"
      assert actions(ctx.tenant_id) == []
    end
  end

  describe "FindingFiler.perform/1" do
    setup ctx do
      flaky!(ctx.hcb, "t1")
      Findings.sweep_tenant(ctx.tenant_id, @now, opts())
      [action] = actions(ctx.tenant_id)
      stub(Loopctl.MockPullRequestSource, :label_issue, fn _r, _n, "chg-loop" -> :ok end)
      %{action: action}
    end

    test "the first attempt creates, labels and records the issue", ctx do
      expect(Loopctl.MockPullRequestSource, :find_issue, 0, fn _r, _s -> {:ok, nil} end)

      expect(Loopctl.MockPullRequestSource, :create_issue, fn %ForgeRepo{}, title, _body ->
        assert title == ctx.action.title
        {:ok, 314}
      end)

      expect(Loopctl.MockPullRequestSource, :label_issue, fn _r, 314, "chg-loop" -> :ok end)

      assert {:done, nil} = FindingFiler.perform(ctx.action)
      assert [%FindingAction{status: :done, issue_number: 314}] = actions(ctx.tenant_id)
      assert [%Finding{issue_number: 314, state: :filed}] = findings(ctx.tenant_id)
    end

    test "a retry finds the issue an earlier attempt opened instead of opening another", ctx do
      expect(Loopctl.MockPullRequestSource, :create_issue, fn _r, _t, _b ->
        {:error, {:github_api_error, 502}}
      end)

      assert {:deferred, _} = FindingFiler.perform(ctx.action)

      AdminRepo.update_all(from(a in FindingAction, where: a.id == ^ctx.action.id),
        set: [next_attempt_at: nil]
      )

      search = Findings.issue_search(ctx.action)
      expect(Loopctl.MockPullRequestSource, :find_issue, fn _r, ^search -> {:ok, 77} end)
      expect(Loopctl.MockPullRequestSource, :create_issue, 0, fn _r, _t, _b -> {:ok, 1} end)

      [pending] = actions(ctx.tenant_id)
      assert {:done, nil} = FindingFiler.perform(pending)
      assert [%Finding{issue_number: 77}] = findings(ctx.tenant_id)
    end

    test "an issue created before the label step failed for good stays on the finding", ctx do
      expect(Loopctl.MockPullRequestSource, :create_issue, fn _r, _t, _b -> {:ok, 40} end)

      expect(Loopctl.MockPullRequestSource, :label_issue, fn _r, 40, "chg-loop" ->
        {:error, {:github_api_error, 422}}
      end)

      assert {:abandoned, _} = FindingFiler.perform(ctx.action)
      assert [%FindingAction{status: :abandoned, issue_number: 40}] = actions(ctx.tenant_id)
      assert [%Finding{issue_number: 40, state: :filed}] = findings(ctx.tenant_id)
    end

    test "a revoked source abandons without a forge call", ctx do
      AdminRepo.update_all(from(s in Source, where: s.id == ^ctx.hcb.id), set: [revoked_at: @now])
      expect(Loopctl.MockPullRequestSource, :create_issue, 0, fn _r, _t, _b -> {:ok, 1} end)

      assert {:abandoned, _} = FindingFiler.perform(ctx.action)

      assert [%FindingAction{status: :abandoned, abandoned_reason: "source_revoked"}] =
               actions(ctx.tenant_id)
    end

    test "two drainers act once: the second finds the row claimed", ctx do
      expect(Loopctl.MockPullRequestSource, :create_issue, 1, fn _r, _t, _b -> {:ok, 5} end)

      assert {:done, nil} = FindingFiler.perform(ctx.action)
      assert {:skipped, nil} = FindingFiler.perform(ctx.action)
    end

    test "the drainer performs a due action", ctx do
      expect(Loopctl.MockPullRequestSource, :create_issue, fn _r, _t, _b -> {:ok, 9} end)

      deadline = System.monotonic_time(:millisecond) + 60_000
      assert [{_row, :done}] = ChgFindingActionWorker.sweep([ctx.action], deadline)
    end
  end

  # US-51.2: a filed flaky_test finding with issue `issue`, whose loop story merged as `sha`.
  defp fixed_flaky!(ctx, issue, sha) do
    flaky!(ctx.hcb, "t1", %{at: DateTime.add(@now, -2 * 86_400, :second)})
    Findings.sweep_tenant(ctx.tenant_id, DateTime.add(@now, -2 * 86_400, :second), opts())

    [finding] = findings(ctx.tenant_id)

    AdminRepo.update_all(from(f in Finding, where: f.id == ^finding.id),
      set: [issue_number: issue]
    )

    AdminRepo.update_all(from(a in FindingAction, where: a.finding_id == ^finding.id),
      set: [status: :done, done_at: @now, issue_number: issue]
    )

    record =
      fixture(:intake_record, %{
        tenant_id: ctx.tenant_id,
        repo: AdminRepo,
        repo_full_name: "mkreyman/home_care_billing",
        issue_number: issue
      })

    story = fixture(:story, %{tenant_id: ctx.tenant_id})

    AdminRepo.update_all(from(s in Story, where: s.id == ^story.id),
      set: [intake_record_id: record.id]
    )

    fixture(:story_stage, %{
      tenant_id: ctx.tenant_id,
      story_id: story.id,
      repo: AdminRepo,
      merge_sha: sha
    })

    finding.id
  end

  defp action_of(tenant_id, kind) do
    Enum.find(actions(tenant_id), &(&1.action == kind))
  end

  describe "the fix lifecycle (US-51.2)" do
    test "a merged loop story moves its finding to fixed", ctx do
      id = fixed_flaky!(ctx, 51, @sha)

      assert %{fixed: 1} = Findings.sweep_tenant(ctx.tenant_id, @now, opts())

      assert %Finding{state: :fixed, fix_merge_sha: @sha, fixed_at: @now} =
               AdminRepo.get(Finding, id)
    end

    test "a finding whose repository differs from its source's only by case is fixed too", ctx do
      id = fixed_flaky!(ctx, 56, @sha)

      AdminRepo.update_all(from(f in Finding, where: f.id == ^id),
        set: [repo_full_name: "MKreyman/Home_Care_Billing"]
      )

      assert %{fixed: 1} = Findings.sweep_tenant(ctx.tenant_id, @now, opts())
      assert %Finding{state: :fixed, fix_merge_sha: @sha} = AdminRepo.get(Finding, id)
    end

    test "a fixed finding quiet for the period closes, with a comment", ctx do
      id = fixed_flaky!(ctx, 52, @sha)
      Findings.sweep_tenant(ctx.tenant_id, @now, opts())

      early = DateTime.add(@now, (Findings.quiet_days() - 1) * 86_400, :second)
      assert %{closed: 0} = Findings.sweep_tenant(ctx.tenant_id, early, opts())

      later = DateTime.add(@now, Findings.quiet_days() * 86_400, :second)
      assert %{closed: 1} = Findings.sweep_tenant(ctx.tenant_id, later, opts())
      assert %Finding{state: :closed} = AdminRepo.get(Finding, id)

      close = action_of(ctx.tenant_id, :close)
      assert close.issue_number == 52
      assert close.body =~ "#{Findings.quiet_days()} days"

      expect(Loopctl.MockPullRequestSource, :comment_issue, fn _r, 52, _b -> :ok end)
      expect(Loopctl.MockPullRequestSource, :close_issue, fn _r, 52, :completed -> :ok end)
      assert {:done, nil} = FindingFiler.perform(close)
    end

    test "a sighting after the fix reopens; a second escalates", ctx do
      id = fixed_flaky!(ctx, 53, @sha)
      Findings.sweep_tenant(ctx.tenant_id, @now, opts())

      day2 = DateTime.add(@now, 86_400, :second)
      flaky!(ctx.hcb, "t1", %{at: DateTime.add(day2, -60, :second)})
      Findings.sweep_tenant(ctx.tenant_id, day2, opts())

      assert %Finding{state: :filed, fix_attempts: 1} = AdminRepo.get(Finding, id)
      reopen = action_of(ctx.tenant_id, :reopen)
      assert %FindingAction{issue_number: 53, generation: 1} = reopen
      assert reopen.body =~ "did not hold"

      expect(Loopctl.MockPullRequestSource, :reopen_issue, fn _r, 53 -> :ok end)
      expect(Loopctl.MockPullRequestSource, :comment_issue, fn _r, 53, _b -> :ok end)
      assert {:done, nil} = FindingFiler.perform(reopen)

      # The second fix merges and is seen; the signal comes back again.
      AdminRepo.update_all(from(f in Finding, where: f.id == ^id),
        set: [state: :fixed, fixed_at: day2]
      )

      day3 = DateTime.add(day2, 86_400, :second)
      flaky!(ctx.hcb, "t1", %{at: DateTime.add(day3, -60, :second)})
      Findings.sweep_tenant(ctx.tenant_id, day3, opts())

      assert %Finding{state: :escalated, fix_attempts: 2, escalated_reason: "fix_attempts_2"} =
               AdminRepo.get(Finding, id)

      escalate = action_of(ctx.tenant_id, :escalate)

      expect(Loopctl.MockPullRequestSource, :comment_issue, fn _r, 53, _b -> :ok end)

      expect(Loopctl.MockPullRequestSource, :label_issue, fn _r, 53, "chg-loop-escalated" ->
        :ok
      end)

      assert {:done, nil} = FindingFiler.perform(escalate)
    end

    test "a reopened finding is not re-credited to the fix that failed; a new merge is", ctx do
      id = fixed_flaky!(ctx, 55, @sha)
      Findings.sweep_tenant(ctx.tenant_id, @now, opts())

      day2 = DateTime.add(@now, 86_400, :second)
      flaky!(ctx.hcb, "t1", %{at: DateTime.add(day2, -60, :second)})
      Findings.sweep_tenant(ctx.tenant_id, day2, opts())
      assert %Finding{state: :filed, fix_attempts: 1} = AdminRepo.get(Finding, id)

      # The next night: the old story's merge is still there, and it is the failed fix.
      day3 = DateTime.add(day2, 86_400, :second)
      assert %{fixed: 0} = Findings.sweep_tenant(ctx.tenant_id, day3, opts())
      assert %Finding{state: :filed, fix_merge_sha: @sha} = AdminRepo.get(Finding, id)

      # The issue's one story is worked again and merges on another sha.
      new_sha = String.duplicate("b", 40)
      [record] = AdminRepo.all(from(r in Record, where: r.issue_number == 55))

      AdminRepo.update_all(
        from(st in StoryStage,
          join: s in Story,
          on: s.id == st.story_id,
          where: s.intake_record_id == ^record.id
        ),
        set: [merge_sha: new_sha]
      )

      assert %{fixed: 1} = Findings.sweep_tenant(ctx.tenant_id, day3, opts())
      assert %Finding{state: :fixed, fix_merge_sha: ^new_sha} = AdminRepo.get(Finding, id)
    end

    test "a sighting before the fix merged does not count against the fix", ctx do
      id = fixed_flaky!(ctx, 54, @sha)
      Findings.sweep_tenant(ctx.tenant_id, @now, opts())

      # A row stamped before fixed_at, arriving late.
      flaky!(ctx.hcb, "t1", %{at: DateTime.add(@now, -60, :second)})
      Findings.sweep_tenant(ctx.tenant_id, DateTime.add(@now, 3600, :second), opts())

      assert %Finding{state: :fixed, fix_attempts: 0} = AdminRepo.get(Finding, id)
      refute action_of(ctx.tenant_id, :reopen)
    end

    test "a reopen the forge refuses for good files the finding again", ctx do
      id = fixed_flaky!(ctx, 55, @sha)
      Findings.sweep_tenant(ctx.tenant_id, @now, opts())
      day2 = DateTime.add(@now, 86_400, :second)
      flaky!(ctx.hcb, "t1", %{at: DateTime.add(day2, -60, :second)})
      Findings.sweep_tenant(ctx.tenant_id, day2, opts())

      reopen = action_of(ctx.tenant_id, :reopen)

      expect(Loopctl.MockPullRequestSource, :reopen_issue, fn _r, 55 ->
        {:error, {:github_api_error, 410}}
      end)

      assert {:abandoned, nil} = FindingFiler.perform(reopen)
      assert %Finding{issue_number: nil, state: :filed} = AdminRepo.get(Finding, id)

      assert [%FindingAction{generation: 1, status: :pending, title: title}] =
               Enum.filter(
                 actions(ctx.tenant_id),
                 &(&1.action == :open and &1.status == :pending)
               )

      assert title =~ "[chg-loop]"
    end
  end

  describe "source_silent (US-51.4)" do
    defp rows_on_days!(source, days_ago) do
      for d <- days_ago do
        ledger!(source, "gate", %{at: DateTime.add(@now, -d * 86_400, :second), verdict: "pass"})
      end
    end

    test "a sender active on 3 of the last 7 days and quiet for a day is a finding", ctx do
      rows_on_days!(ctx.hcb, [2, 4, 6])

      assert [s] = Findings.derive(ctx.tenant_id, @now, opts())
      assert s.kind == "source_silent"
      assert s.repo_full_name == @chg_repo
      assert s.fingerprint == "#{ctx.hcb.id}:minis"
      assert s.evidence["source_repo"] == "mkreyman/home_care_billing"
    end

    test "two active days, or a row in the last day, is not silence", ctx do
      rows_on_days!(ctx.hcb, [2, 4])
      assert Findings.derive(ctx.tenant_id, @now, opts()) == []

      rows_on_days!(ctx.chg, [2, 4, 6])
      ledger!(ctx.chg, "gate", %{at: DateTime.add(@now, -600, :second), verdict: "pass"})
      assert Findings.derive(ctx.tenant_id, @now, opts()) == []
    end

    test "a sender that resumes is fixed, then closes after the quiet period", ctx do
      rows_on_days!(ctx.hcb, [2, 4, 6])
      Findings.sweep_tenant(ctx.tenant_id, @now, opts())

      [finding] = findings(ctx.tenant_id)
      assert finding.state == :filed

      AdminRepo.update_all(from(f in Finding, where: f.id == ^finding.id),
        set: [issue_number: 77]
      )

      day2 = DateTime.add(@now, 86_400, :second)
      ledger!(ctx.hcb, "gate", %{at: DateTime.add(day2, -600, :second), verdict: "pass"})

      assert %{fixed: 1} = Findings.sweep_tenant(ctx.tenant_id, day2, opts())
      assert %Finding{state: :fixed, fix_merge_sha: nil} = AdminRepo.get(Finding, finding.id)

      later = DateTime.add(day2, Findings.quiet_days() * 86_400, :second)
      ledger!(ctx.hcb, "gate", %{at: DateTime.add(later, -600, :second), verdict: "pass"})

      assert %{closed: 1} = Findings.sweep_tenant(ctx.tenant_id, later, opts())
      assert action_of(ctx.tenant_id, :close).body =~ "the signal stopped"
    end
  end

  describe "list/2 and clear/3 (US-51.6)" do
    defp escalate!(id, issue) do
      AdminRepo.update_all(from(f in Finding, where: f.id == ^id),
        set: [
          state: :escalated,
          escalated_at: @now,
          escalated_reason: "fix_attempts_2",
          fix_attempts: 2,
          issue_number: issue
        ]
      )
    end

    test "filters by state, kind and repo, newest first, capped", ctx do
      flaky!(ctx.hcb, "t1", %{at: DateTime.add(@now, -7200, :second)})
      flaky!(ctx.hcb, "t2")
      selection_miss!(ctx.hcb)
      Findings.sweep_tenant(ctx.tenant_id, @now, opts())

      assert [first, _, _] = Findings.list(ctx.tenant_id)
      assert first.last_seen_at == DateTime.add(@now, -3600, :second)

      assert [%Finding{kind: "selection_miss"}] =
               Findings.list(ctx.tenant_id, kind: "selection_miss")

      assert [_, _] = Findings.list(ctx.tenant_id, repo: "MKREYMAN/Home_Care_Billing")
      assert [] = Findings.list(ctx.tenant_id, state: :escalated)
      assert [_] = Findings.list(ctx.tenant_id, limit: 1)
      assert [_, _, _] = Findings.list(ctx.tenant_id, limit: Findings.list_cap() + 50)
    end

    test "clear sends an escalated finding back to queued, audited", ctx do
      flaky!(ctx.hcb, "t1")
      Findings.sweep_tenant(ctx.tenant_id, @now, opts())
      [finding] = findings(ctx.tenant_id)
      escalate!(finding.id, 60)

      actor = %{api_key_id: nil, label: "user:test"}
      assert {:ok, cleared} = Findings.clear(ctx.tenant_id, finding.id, actor)

      assert %Finding{
               state: :queued,
               fix_attempts: 0,
               cycle: 1,
               issue_number: nil,
               escalated_reason: nil,
               escalated_at: nil
             } = cleared

      assert AdminRepo.exists?(
               from l in Loopctl.Audit.AuditLog,
                 where:
                   l.tenant_id == ^ctx.tenant_id and l.entity_id == ^finding.id and
                     l.action == "chg_finding_cleared"
             )
    end

    test "a cleared finding is filed afresh: its new open is not the old one", ctx do
      flaky!(ctx.hcb, "t1")
      Findings.sweep_tenant(ctx.tenant_id, @now, opts())
      [finding] = findings(ctx.tenant_id)
      escalate!(finding.id, 61)

      {:ok, _} = Findings.clear(ctx.tenant_id, finding.id, %{})
      Findings.sweep_tenant(ctx.tenant_id, DateTime.add(@now, 60, :second), opts())

      opens =
        ctx.tenant_id
        |> actions()
        |> Enum.filter(&(&1.action == :open))
        |> Enum.sort_by(& &1.cycle)

      assert [%FindingAction{cycle: 0, generation: 0}, %FindingAction{cycle: 1, generation: 0}] =
               opens

      assert %Finding{state: :filed, cycle: 1} = AdminRepo.get(Finding, finding.id)
    end

    test "clear refuses a finding that is not escalated, or not the tenant's", ctx do
      flaky!(ctx.hcb, "t1")
      Findings.sweep_tenant(ctx.tenant_id, @now, opts())
      [finding] = findings(ctx.tenant_id)

      assert {:error, :not_escalated} = Findings.clear(ctx.tenant_id, finding.id, %{})
      assert {:error, :not_found} = Findings.clear(ctx.tenant_id, Ecto.UUID.generate(), %{})
      assert {:error, :not_found} = Findings.clear(ctx.tenant_id, "nope", %{})

      escalate!(finding.id, 62)
      %{source: other} = fixture(:chg_source, %{repo_full_name: @chg_repo})
      assert {:error, :not_found} = Findings.clear(other.tenant_id, finding.id, %{})
      assert Findings.list(other.tenant_id) == []
    end
  end

  describe "tenant isolation" do
    test "one tenant's ledger never becomes another tenant's finding", ctx do
      %{source: other} = fixture(:chg_source, %{repo_full_name: "mkreyman/home_care_billing"})
      flaky!(other, "t-other")

      assert Findings.derive(ctx.tenant_id, @now, opts()) == []
      Findings.sweep_tenant(ctx.tenant_id, @now, opts())
      assert findings(ctx.tenant_id) == []

      assert [%Finding{}] =
               Findings.sweep_tenant(other.tenant_id, @now, opts()) && findings(other.tenant_id)
    end
  end
end
