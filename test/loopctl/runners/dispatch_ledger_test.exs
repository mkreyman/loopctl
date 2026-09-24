defmodule Loopctl.Runners.DispatchLedgerTest do
  @moduledoc """
  Issue #803: the dispatch ledger and trace intake — a dispatch's identity is written once,
  a reply applies once and only from the runner it was sent to at the dispatched epoch, and
  a trace is stored once per `(run_id, seq)` with a contiguous ack computed in SQL.

  ## Why `async: false` and COMMITTED runners

  The ledger runs on the RLS `Loopctl.Repo` (inside `Repo.with_tenant/2`), while tenants,
  runner keys and runner rows are written through `Loopctl.AdminRepo`. The two are separate
  sandbox connections that cannot see each other's uncommitted rows, and a ledger row's
  foreign keys must see its tenant and runner — so those are committed
  (`fixture(:committed_runner)`), swept at module boundaries, and no other test may run
  meanwhile. Every read of a ledger or trace row here goes through `Repo.with_tenant/2`,
  the path the code uses, so the RLS policy is exercised rather than bypassed.
  """

  use Loopctl.DataCase, async: false

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Delivery.DispatchLease
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.Runners.TraceEvent

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  setup do
    # Room for every dispatch a test here sends: capacity is tested in
    # `Loopctl.Runners.CapacityTest`, and a slot limit would only cap how many rows a test can
    # write.
    {_raw, runner} = fixture(:committed_runner, %{name: "minis", max_sessions: 64})
    %{runner: runner}
  end

  defp as_tenant(tenant_id, fun) do
    {:ok, result} = Repo.with_tenant(tenant_id, fun)
    result
  end

  # A dispatch payload for a real story at the dispatch's epoch, on the connection the
  # ledger's claim fence reads (unless the caller names a story).
  defp dispatch_payload(tenant_id, attrs \\ %{}) do
    attrs = Map.new(attrs)

    story_id =
      Map.get_lazy(attrs, "story_id", fn ->
        fixture(:ledger_story, %{
          tenant_id: tenant_id,
          claim_epoch: Map.get(attrs, "claim_epoch", 0)
        }).id
      end)

    build(:runner_dispatch, Map.put(attrs, "story_id", story_id))
  end

  # A release of the story's claim, as every release path in `Progress` writes it.
  defp release_claim(tenant_id, story_id) do
    as_tenant(tenant_id, fn ->
      story = Repo.get!(Loopctl.WorkBreakdown.Story, story_id)

      story
      |> Ecto.Changeset.change(Loopctl.Progress.claim_release_change(story))
      |> Repo.update!()
    end)
  end

  # `after_cast` overrides fields of the CAST dispatch, for the values the outbound cast
  # legitimately refuses but the ledger must still store.
  defp sent(runner, attrs \\ %{}, after_cast \\ %{}) do
    {:ok, dispatch} = RunnerContract.cast_dispatch(dispatch_payload(runner.tenant_id, attrs))

    {:ok, record} =
      DispatchLedger.record_sent(runner.tenant_id, runner.id, Map.merge(dispatch, after_cast))

    record
  end

  defp reply(runner, record, attrs \\ %{}) do
    payload =
      Map.merge(
        %{
          "dispatch_id" => record.dispatch_id,
          "claim_epoch" => record.claim_epoch,
          "decision" => "accepted"
        },
        attrs
      )

    {:ok, reply} = RunnerContract.cast_dispatch_reply(payload)
    DispatchLedger.record_reply(runner.tenant_id, runner.id, reply)
  end

  defp accepted(runner, attrs \\ %{}) do
    record = sent(runner, attrs)
    {:ok, record} = reply(runner, record)
    record
  end

  defp trace(runner, record, run_id, seqs, attrs \\ %{}) do
    payload =
      build(
        :runner_trace_batch,
        Map.merge(
          %{
            :seqs => seqs,
            "run_id" => run_id,
            "dispatch_id" => record.dispatch_id,
            "claim_epoch" => record.claim_epoch
          },
          attrs
        )
      )

    {:ok, batch} = RunnerContract.cast_trace_batch(payload)
    DispatchLedger.record_trace(runner.tenant_id, runner.id, batch)
  end

  defp stored_seqs(tenant_id, run_id) do
    as_tenant(tenant_id, fn ->
      Repo.all(
        from e in TraceEvent,
          where: e.tenant_id == ^tenant_id and e.run_id == ^run_id,
          order_by: e.seq,
          select: e.seq
      )
    end)
  end

  describe "record_sent/3" do
    test "writes one `sent` row carrying the dispatch's identity", %{runner: runner} do
      # The kind is set AFTER the cast: `triage` is a declared kind the cast refuses to
      # dispatch (contract 1.5.0), while the ledger stores whatever kind it is handed — which
      # is what this asserts, and what keeps the row honest once triage has its own payload.
      record = sent(runner, %{"claim_epoch" => 3}, %{kind: "triage"})

      assert record.status == "sent"
      assert record.runner_id == runner.id
      assert record.claim_epoch == 3
      assert record.kind == "triage"
      assert record.trace_acked_seq == -1
      assert DispatchLedger.get_record(runner.tenant_id, record.dispatch_id).id == record.id
    end

    test "the same dispatch_id twice finds the first row instead of writing a second",
         %{runner: runner} do
      payload = dispatch_payload(runner.tenant_id)
      {:ok, dispatch} = RunnerContract.cast_dispatch(payload)

      assert {:ok, first} = DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)
      assert {:ok, again} = DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)
      assert again.id == first.id

      assert 1 ==
               as_tenant(runner.tenant_id, fn ->
                 Repo.aggregate(
                   from(r in DispatchRecord, where: r.dispatch_id == ^dispatch.dispatch_id),
                   :count
                 )
               end)
    end

    test "refuses a dispatch_id already recorded with a different identity", %{runner: runner} do
      {_raw, other} = fixture(:committed_runner, %{name: "blockit", tenant_id: runner.tenant_id})
      record = sent(runner)

      base =
        build(:runner_dispatch, %{
          "dispatch_id" => record.dispatch_id,
          "story_id" => record.story_id
        })

      # The unchanged identity is accepted, so each refusal below is its one differing field.
      {:ok, same} = RunnerContract.cast_dispatch(base)
      assert {:ok, _} = DispatchLedger.record_sent(runner.tenant_id, runner.id, same)

      # Each differing identity passes the claim fence (a real story at the presented epoch),
      # so the refusal is the ledger's identity check, not the fence.
      other_story = fixture(:ledger_story, %{tenant_id: runner.tenant_id})

      # `after_cast` for the kind, which the outbound cast refuses to dispatch; the ledger's
      # identity check reads the stored column either way.
      for {who, attrs, after_cast} <- [
            {runner, %{}, %{kind: "triage"}},
            {runner, %{"story_id" => other_story.id}, %{}},
            {other, %{}, %{}}
          ] do
        {:ok, dispatch} = RunnerContract.cast_dispatch(Map.merge(base, attrs))

        assert {:error, :dispatch_id_conflict} =
                 DispatchLedger.record_sent(
                   who.tenant_id,
                   who.id,
                   Map.merge(dispatch, after_cast)
                 )
      end

      # A different epoch on the SAME story: once the story has moved to it, that too is a
      # different identity for this dispatch_id.
      release_claim(runner.tenant_id, record.story_id)
      {:ok, next_epoch} = RunnerContract.cast_dispatch(Map.put(base, "claim_epoch", 1))

      assert {:error, :dispatch_id_conflict} =
               DispatchLedger.record_sent(runner.tenant_id, runner.id, next_epoch)
    end

    test "refuses to re-send a dispatch the runner already answered", %{runner: runner} do
      record = accepted(runner)

      {:ok, dispatch} =
        RunnerContract.cast_dispatch(
          build(:runner_dispatch, %{
            "dispatch_id" => record.dispatch_id,
            "story_id" => record.story_id
          })
        )

      assert {:error, :dispatch_already_replied} =
               DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)
    end

    test "the same dispatch_id in another tenant is a separate row", %{runner: runner} do
      record = sent(runner)
      tenant_b = fixture(:committed_tenant, %{})
      {_raw, runner_b} = fixture(:committed_runner, %{name: "minis", tenant_id: tenant_b.id})

      {:ok, dispatch} =
        RunnerContract.cast_dispatch(
          dispatch_payload(tenant_b.id, %{"dispatch_id" => record.dispatch_id})
        )

      assert {:ok, record_b} = DispatchLedger.record_sent(tenant_b.id, runner_b.id, dispatch)
      assert record_b.id != record.id
      assert DispatchLedger.get_record(tenant_b.id, record.dispatch_id).id == record_b.id
      assert DispatchLedger.get_record(runner.tenant_id, record.dispatch_id).id == record.id
    end
  end

  describe "kind_unsupported?/3" do
    test "is true only for the kind the runner actually refused", %{runner: runner} do
      # Scoped BY KIND, and that cannot be shown through `Runners.dispatch/3` while
      # `implement` is the only dispatchable kind — so it is shown here, against the read
      # itself. Without the kind predicate a machine that declined triage would never be sent
      # an implement dispatch again.
      record = sent(runner)

      {:ok, _} =
        reply(runner, record, %{"decision" => "refused", "reason" => "kind_not_supported"})

      assert DispatchLedger.kind_unsupported?(runner.tenant_id, runner.id, "implement")
      refute DispatchLedger.kind_unsupported?(runner.tenant_id, runner.id, "triage")
    end

    test "an accepted or otherwise-refused dispatch says nothing about the kind",
         %{runner: runner} do
      accepted = sent(runner)
      {:ok, _} = reply(runner, accepted)

      other = sent(runner)
      {:ok, _} = reply(runner, other, %{"decision" => "refused", "reason" => "draining"})

      refute DispatchLedger.kind_unsupported?(runner.tenant_id, runner.id, "implement")
    end

    test "the database is what makes a reason without a refusal impossible", %{runner: runner} do
      # `kind_unsupported?/3` also filters on `status == "refused"`, and no test can turn that
      # predicate red — because the state it excludes cannot exist. This is why: the
      # `runner_dispatches_reason_iff_refused` CHECK refuses the row outright, so the
      # predicate is defence in depth over an L2 invariant rather than the enforcement. If
      # this assertion ever goes red, that predicate has become load-bearing and needs a test
      # of its own.
      record = sent(runner)

      assert_raise Postgrex.Error, ~r/runner_dispatches_reason_iff_refused/, fn ->
        as_tenant(runner.tenant_id, fn ->
          from(r in DispatchRecord, where: r.id == ^record.id)
          |> Repo.update_all(set: [reason: "kind_not_supported"])
        end)
      end
    end

    test "one runner's refusal does not speak for another", %{runner: runner} do
      {_raw, other} = fixture(:committed_runner, %{name: "blockit", tenant_id: runner.tenant_id})

      record = sent(runner)

      {:ok, _} =
        reply(runner, record, %{"decision" => "refused", "reason" => "kind_not_supported"})

      assert DispatchLedger.kind_unsupported?(runner.tenant_id, runner.id, "implement")
      refute DispatchLedger.kind_unsupported?(other.tenant_id, other.id, "implement")
    end
  end

  describe "unsupported_kinds/1" do
    test "groups the tenant's barred kinds by runner, and omits runners with none",
         %{runner: runner} do
      {_raw, clean} = fixture(:committed_runner, %{name: "blockit", tenant_id: runner.tenant_id})

      barred = sent(runner)

      {:ok, _} =
        reply(runner, barred, %{"decision" => "refused", "reason" => "kind_not_supported"})

      # A second refusal of the SAME kind must not produce a duplicate entry.
      again = sent(runner)

      {:ok, _} =
        reply(runner, again, %{"decision" => "refused", "reason" => "kind_not_supported"})

      ordinary = sent(clean)
      {:ok, _} = reply(clean, ordinary, %{"decision" => "refused", "reason" => "draining"})

      kinds = DispatchLedger.unsupported_kinds(runner.tenant_id)

      assert kinds == %{runner.id => ["implement"]}
      refute Map.has_key?(kinds, clean.id)
    end

    test "is tenant-scoped", %{runner: runner} do
      other_tenant = fixture(:committed_tenant, %{})

      record = sent(runner)

      {:ok, _} =
        reply(runner, record, %{"decision" => "refused", "reason" => "kind_not_supported"})

      assert DispatchLedger.unsupported_kinds(other_tenant.id) == %{}
    end

    test "the partial index the two reads depend on exists, is valid, and is partial" do
      # `kind_unsupported?/3` runs on the dispatch hot path and `unsupported_kinds/1` on every
      # pool poll, and `runner_dispatches` has no age-based retention — so without this index
      # the common NO-MATCH case examines every dispatch the runner ever held.
      #
      # What this asserts is existence, VALIDITY and shape. A concurrent build that was
      # interrupted leaves an INVALID index occupying the name: the reads silently go back to
      # the scan and nothing looks wrong, which is the failure worth a test. What it does NOT
      # assert is the query PLAN — at test-DB scale the planner picks a sequential scan
      # whatever indexes exist, so an EXPLAIN here would prove nothing about production.
      sql = """
      SELECT pg_get_indexdef(c.oid), x.indisvalid
        FROM pg_class c
        JOIN pg_index x ON x.indexrelid = c.oid
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE c.relname = $1 AND c.relkind = 'i' AND n.nspname = 'public'
      """

      assert [[definition, true]] =
               Repo.query!(sql, ["runner_dispatches_unsupported_kind_idx"]).rows

      assert definition =~ "USING btree (tenant_id, runner_id, kind)"

      # PARTIAL on both values, which is what keeps it a handful of rows rather than a second
      # copy of the table.
      assert definition =~ "WHERE"
      assert definition =~ "refused"
      assert definition =~ "kind_not_supported"
    end

    test "nothing under lib/ deletes a dispatch row, because those rows ARE the memory" do
      # The capability memory is DERIVED from `runner_dispatches`, so its lifetime is that
      # table's retention — and the coupling is invisible from a pruner's own file. The day
      # something prunes this table by age, a runner that told loopctl it cannot do a kind
      # becomes eligible again: silently, on a schedule, with no reply from the runner and
      # nothing in any log to say why the dispatches resumed. This is where a pruner's author
      # finds out. Excluding those rows in the predicate is the fix; relaxing this is not.
      # Matched by PROXIMITY, not by one call shape. The first version of this guard matched
      # only `delete_all(from(x in DispatchRecord` and `Repo.delete(%DispatchRecord` — and the
      # PIPE form, which is how most of the deletes in `lib/` are actually written, walked
      # straight past it, as did `Multi.delete_all` and raw SQL naming the table. A guard that
      # misses the way the code is written is not a guard.
      #
      # The unit is a CHUNK: contiguous non-blank lines, which is one expression or function
      # body in this codebase's layout. A chunk carrying both a delete verb and a reference to
      # these rows is flagged whichever order they appear in, so the pipe form (target first)
      # and the argument form (verb first) are both caught.
      # Raw SQL is in the pattern too: a pruner written as `Repo.query!("DELETE FROM
      # runner_dispatches ...")` carries no Ecto verb at all and slipped past a shape-based
      # scan entirely.
      verb =
        ~r/\b(?:delete_all|delete!?)\s*[(|]|\|>\s*[A-Za-z.]*[Rr]epo\.delete|\bDELETE\s+FROM\b|\bTRUNCATE\b/i

      target = ~r/DispatchRecord|runner_dispatches/

      files = Path.wildcard("lib/**/*.ex")
      assert length(files) > 100, "the source scan found no files, so it proves nothing"

      mentions = Enum.filter(files, &(File.read!(&1) =~ target))

      assert "lib/loopctl/runners/dispatch_ledger.ex" in mentions,
             "the scan no longer sees the module that owns these rows"

      # The verb pattern must actually match the delete shapes this repo uses, or the scan is
      # looking for something that is never written and can never fire.
      assert Enum.any?(Path.wildcard("lib/**/*.ex"), fn file ->
               File.read!(file) =~ ~r/\|>\s*[A-Za-z.]*[Rr]epo\.delete_all\(/
             end),
             "no pipe-form delete found in lib/, so the pipe half of the verb pattern is untested"

      deletes =
        for file <- mentions,
            source = File.read!(file),
            chunk <- String.split(source, ~r/\n\s*\n/),
            Regex.match?(verb, chunk) and Regex.match?(target, chunk),
            uniq: true,
            do: file

      assert deletes == [],
             "these delete dispatch rows: #{inspect(deletes)}. A row with status " <>
               "'refused' and reason 'kind_not_supported' is the ONLY storage of the " <>
               "capability memory kind_unsupported?/3 reads — see the Retention section of " <>
               "Loopctl.Runners.DispatchLedger. Exclude those rows, or do not prune here."
    end
  end

  describe "record_reply/3" do
    test "accepted moves the row out of sent and writes no audit-chain entry",
         %{runner: runner} do
      record = sent(runner)

      audit_count = fn ->
        AdminRepo.aggregate(from(e in Entry, where: e.tenant_id == ^runner.tenant_id), :count)
      end

      # One entry of its own, so an unchanged count is a count that could have moved.
      {:ok, _} =
        AuditChain.append(runner.tenant_id, %{
          action: "runner_enrolled",
          actor_lineage: [],
          entity_type: "runner",
          entity_id: runner.id,
          payload: %{}
        })

      before = audit_count.()
      assert before > 0, "the seeded entry must be counted, or this count proves nothing"

      assert {:ok, updated} = reply(runner, record)
      assert updated.status == "accepted"
      assert updated.replied_at
      assert is_nil(updated.reason)

      assert audit_count.() == before
    end

    test "refused records the reason and detail", %{runner: runner} do
      record = sent(runner)

      assert {:ok, updated} =
               reply(runner, record, %{
                 "decision" => "refused",
                 "reason" => "other",
                 "detail" => "disk quota"
               })

      assert updated.status == "refused"
      assert updated.reason == "other"
      assert updated.reason_detail == "disk quota"
    end

    test "an identical repeat is ok and a different second reply is refused",
         %{runner: runner} do
      record = sent(runner)
      refusal = %{"decision" => "refused", "reason" => "draining"}

      assert {:ok, _} = reply(runner, record, refusal)
      assert {:ok, again} = reply(runner, record, refusal)
      assert again.status == "refused"

      assert {:error, :already_replied} = reply(runner, record)

      assert {:error, :already_replied} =
               reply(runner, record, %{refusal | "reason" => "at_capacity"})

      assert DispatchLedger.get_record(runner.tenant_id, record.dispatch_id).reason == "draining"
    end

    test "a reply for another runner's dispatch is unknown and changes nothing",
         %{runner: runner} do
      {_raw, other} = fixture(:committed_runner, %{name: "blockit", tenant_id: runner.tenant_id})
      record = sent(other)

      assert {:error, :unknown_dispatch} = reply(runner, record)
      assert DispatchLedger.get_record(runner.tenant_id, record.dispatch_id).status == "sent"
    end

    test "a reply for another tenant's dispatch is unknown and changes nothing",
         %{runner: runner} do
      tenant_b = fixture(:committed_tenant, %{})
      {_raw, runner_b} = fixture(:committed_runner, %{name: "minis", tenant_id: tenant_b.id})
      record_b = sent(runner_b)

      assert {:error, :unknown_dispatch} = reply(runner, record_b)
      assert DispatchLedger.get_record(tenant_b.id, record_b.dispatch_id).status == "sent"
    end

    test "a reply for a dispatch that was never sent is unknown", %{runner: runner} do
      record = %{dispatch_id: Ecto.UUID.generate(), claim_epoch: 0}
      assert {:error, :unknown_dispatch} = reply(runner, record)
    end

    test "a reply at another claim_epoch is stale and changes nothing", %{runner: runner} do
      record = sent(runner, %{"claim_epoch" => 2})

      assert {:error, :stale_claim_epoch} = reply(runner, record, %{"claim_epoch" => 1})
      assert {:error, :stale_claim_epoch} = reply(runner, record, %{"claim_epoch" => 3})
      assert DispatchLedger.get_record(runner.tenant_id, record.dispatch_id).status == "sent"
    end
  end

  # #879 (US-44.5): a placed claim's cap is provisional (placed_at + wall clock + grace) until
  # the runner accepts, and the acceptance moves it — and the lease — to replied_at + the
  # dispatch's wall clock + grace, the anchor `Capacity` bounds the session by.
  describe "record_reply/3 re-anchors a placed claim's lease on acceptance" do
    test "an acceptance moves a capped claim to replied_at + wall clock + grace",
         %{runner: runner} do
      record = sent(runner)
      provisional = DateTime.add(DateTime.utc_now(), 60, :second)
      set_lease(runner.tenant_id, record.story_id, provisional, provisional)

      assert {:ok, updated} = reply(runner, record)

      expected = DispatchLease.cap(updated.replied_at, record.wall_clock_seconds)
      assert DateTime.compare(expected, provisional) == :gt
      assert lease(runner.tenant_id, record.story_id) == {expected, expected}
    end

    test "only forward: a cap already later is left where it is", %{runner: runner} do
      record = sent(runner)
      later = DateTime.add(DateTime.utc_now(), 86_400 * 2, :second)
      set_lease(runner.tenant_id, record.story_id, later, later)

      assert {:ok, _updated} = reply(runner, record)
      assert lease(runner.tenant_id, record.story_id) == {later, later}
    end

    test "an uncapped claim is left uncapped, its lease untouched", %{runner: runner} do
      record = sent(runner)
      until = DateTime.add(DateTime.utc_now(), 60, :second)
      set_lease(runner.tenant_id, record.story_id, until, nil)

      assert {:ok, _updated} = reply(runner, record)
      assert lease(runner.tenant_id, record.story_id) == {until, nil}
    end

    test "a refusal moves nothing", %{runner: runner} do
      record = sent(runner)
      provisional = DateTime.add(DateTime.utc_now(), 60, :second)
      set_lease(runner.tenant_id, record.story_id, provisional, provisional)

      assert {:ok, _} =
               reply(runner, record, %{
                 "decision" => "refused",
                 "reason" => "other",
                 "detail" => "x"
               })

      assert lease(runner.tenant_id, record.story_id) == {provisional, provisional}
    end
  end

  defp set_lease(tenant_id, story_id, claimed_until, cap) do
    as_tenant(tenant_id, fn ->
      {1, _} =
        from(s in Loopctl.WorkBreakdown.Story,
          where: s.tenant_id == ^tenant_id and s.id == ^story_id
        )
        |> Repo.update_all(set: [claimed_until: claimed_until, claim_lease_cap: cap])
    end)
  end

  defp lease(tenant_id, story_id) do
    as_tenant(tenant_id, fn ->
      Repo.one!(
        from s in Loopctl.WorkBreakdown.Story,
          where: s.tenant_id == ^tenant_id and s.id == ^story_id,
          select: {s.claimed_until, s.claim_lease_cap}
      )
    end)
  end

  describe "record_trace/3" do
    setup %{runner: runner} do
      %{record: accepted(runner), run_id: Ecto.UUID.generate()}
    end

    test "stores a batch and acks its last seq", %{runner: runner, record: record, run_id: run_id} do
      assert {:ok, 2} = trace(runner, record, run_id, [0, 1, 2])
      assert stored_seqs(runner.tenant_id, run_id) == [0, 1, 2]

      [event | _] =
        as_tenant(runner.tenant_id, fn ->
          Repo.all(from e in TraceEvent, where: e.run_id == ^run_id, order_by: e.seq)
        end)

      assert event.tenant_id == runner.tenant_id
      assert event.runner_dispatch_id == record.id
      assert event.event_id == "evt-0"
      assert is_nil(event.parent)
      assert event.data == %{"tool" => "Read"}
    end

    test "a batch sent twice is stored once", %{runner: runner, record: record, run_id: run_id} do
      assert {:ok, 1} = trace(runner, record, run_id, [0, 1])
      assert {:ok, 1} = trace(runner, record, run_id, [0, 1])
      assert stored_seqs(runner.tenant_id, run_id) == [0, 1]
    end

    test "a re-sent seq with different content keeps the first copy",
         %{runner: runner, record: record, run_id: run_id} do
      assert {:ok, 0} = trace(runner, record, run_id, [0])

      resent =
        build(:runner_trace_batch, %{
          :seqs => [0],
          "run_id" => run_id,
          "dispatch_id" => record.dispatch_id,
          "claim_epoch" => record.claim_epoch
        })
        |> put_in(["events", Access.at(0), "data"], %{"tool" => "Write"})

      {:ok, batch} = RunnerContract.cast_trace_batch(resent)
      assert {:ok, 0} = DispatchLedger.record_trace(runner.tenant_id, runner.id, batch)

      assert [%TraceEvent{data: %{"tool" => "Read"}}] =
               as_tenant(runner.tenant_id, fn ->
                 Repo.all(from e in TraceEvent, where: e.run_id == ^run_id)
               end)
    end

    test "the ack is the end of the contiguous seqs from 0, and moves when the gap fills",
         %{runner: runner, record: record, run_id: run_id} do
      assert {:ok, 1} = trace(runner, record, run_id, [0, 1, 3])
      assert DispatchLedger.trace_cursor(runner.tenant_id, runner.id, run_id) == 1

      assert {:ok, 3} = trace(runner, record, run_id, [2])
      assert DispatchLedger.trace_cursor(runner.tenant_id, runner.id, run_id) == 3

      assert {:ok, 3} = trace(runner, record, run_id, [5, 6])
      assert {:ok, 6} = trace(runner, record, run_id, [4])
    end

    test "nothing is acked while seq 0 is missing", %{
      runner: runner,
      record: record,
      run_id: run_id
    } do
      assert {:ok, -1} = trace(runner, record, run_id, [1, 2])
      assert {:ok, 2} = trace(runner, record, run_id, [0])
    end

    test "a batch for a run of an unknown dispatch is refused", %{runner: runner, run_id: run_id} do
      unknown = %{dispatch_id: Ecto.UUID.generate(), claim_epoch: 0}
      assert {:error, :unknown_dispatch} = trace(runner, unknown, run_id, [0])
      assert stored_seqs(runner.tenant_id, run_id) == []
    end

    test "a batch at another claim_epoch is refused", %{
      runner: runner,
      record: record,
      run_id: run_id
    } do
      assert {:error, :stale_claim_epoch} =
               trace(runner, record, run_id, [0], %{"claim_epoch" => record.claim_epoch + 1})

      assert stored_seqs(runner.tenant_id, run_id) == []
    end

    test "a batch for a dispatch not accepted is refused", %{runner: runner, run_id: run_id} do
      pending = sent(runner)
      assert {:error, :dispatch_not_accepted} = trace(runner, pending, run_id, [0])

      refused = sent(runner)
      {:ok, _} = reply(runner, refused, %{"decision" => "refused", "reason" => "draining"})
      assert {:error, :dispatch_not_accepted} = trace(runner, refused, run_id, [0])
      assert stored_seqs(runner.tenant_id, run_id) == []
    end

    test "a batch for another runner's dispatch is refused", %{runner: runner, run_id: run_id} do
      {_raw, other} = fixture(:committed_runner, %{name: "blockit", tenant_id: runner.tenant_id})
      theirs = accepted(other)

      assert {:error, :unknown_dispatch} = trace(runner, theirs, run_id, [0])
      assert stored_seqs(runner.tenant_id, run_id) == []
    end

    test "the first batch binds the run; another run for the dispatch, or the run for another dispatch, is refused",
         %{runner: runner, record: record, run_id: run_id} do
      assert {:ok, 0} = trace(runner, record, run_id, [0])
      assert DispatchLedger.get_record(runner.tenant_id, record.dispatch_id).run_id == run_id

      assert {:error, :run_mismatch} = trace(runner, record, Ecto.UUID.generate(), [0])

      second = accepted(runner)
      assert {:error, :run_mismatch} = trace(runner, second, run_id, [1])
      assert stored_seqs(runner.tenant_id, run_id) == [0]
    end

    test "another tenant's trace for the same run_id is isolated", %{
      runner: runner,
      record: record,
      run_id: run_id
    } do
      tenant_b = fixture(:committed_tenant, %{})
      {_raw, runner_b} = fixture(:committed_runner, %{name: "minis", tenant_id: tenant_b.id})
      record_b = accepted(runner_b)

      assert {:ok, 1} = trace(runner, record, run_id, [0, 1])
      assert {:ok, 0} = trace(runner_b, record_b, run_id, [0])

      assert stored_seqs(runner.tenant_id, run_id) == [0, 1]
      assert stored_seqs(tenant_b.id, run_id) == [0]
      assert DispatchLedger.trace_cursor(tenant_b.id, runner_b.id, run_id) == 0
      assert DispatchLedger.trace_cursor(tenant_b.id, runner.id, run_id) == -1
    end
  end

  describe "trace_cursor/3" do
    test "is -1 before anything is stored, then the acked seq", %{runner: runner} do
      record = accepted(runner)
      run_id = Ecto.UUID.generate()

      assert DispatchLedger.trace_cursor(runner.tenant_id, runner.id, run_id) == -1
      assert {:ok, 4} = trace(runner, record, run_id, [0, 1, 2, 3, 4])
      assert DispatchLedger.trace_cursor(runner.tenant_id, runner.id, run_id) == 4
    end

    test "answers -1 for a run another runner holds", %{runner: runner} do
      {_raw, other} = fixture(:committed_runner, %{name: "blockit", tenant_id: runner.tenant_id})
      theirs = accepted(other)
      run_id = Ecto.UUID.generate()
      assert {:ok, 0} = trace(other, theirs, run_id, [0])

      assert DispatchLedger.trace_cursor(runner.tenant_id, runner.id, run_id) == -1
    end
  end

  describe "the claim fence" do
    test "after the story's claim is released, a trace and a reply are stale and the row reads superseded",
         %{runner: runner} do
      # Claim (epoch 1), dispatch at that epoch, the runner accepts and ships a batch.
      story = fixture(:ledger_story, %{tenant_id: runner.tenant_id, claim_epoch: 1})
      record = accepted(runner, %{"story_id" => story.id, "claim_epoch" => 1})
      run_id = Ecto.UUID.generate()
      assert {:ok, 0} = trace(runner, record, run_id, [0])

      # The claim is reclaimed: the story moves to epoch 2. The zombie still presents 1.
      release_claim(runner.tenant_id, story.id)

      assert {:error, :stale_claim_epoch} = trace(runner, record, run_id, [1])

      assert DispatchLedger.get_record(runner.tenant_id, record.dispatch_id).status ==
               "superseded"

      assert {:error, :stale_claim_epoch} = reply(runner, record)
      assert stored_seqs(runner.tenant_id, run_id) == [0]
    end

    test "a sent row whose story moved on is superseded by the reply, and nothing is applied",
         %{runner: runner} do
      record = sent(runner)
      release_claim(runner.tenant_id, record.story_id)

      assert {:error, :stale_claim_epoch} = reply(runner, record)

      assert %{status: "superseded", replied_at: nil} =
               DispatchLedger.get_record(runner.tenant_id, record.dispatch_id)
    end

    test "a refused row stays refused when its story moves on", %{runner: runner} do
      record = sent(runner)
      {:ok, _} = reply(runner, record, %{"decision" => "refused", "reason" => "draining"})
      release_claim(runner.tenant_id, record.story_id)

      assert {:error, :stale_claim_epoch} = reply(runner, record)

      assert %{status: "refused", reason: "draining"} =
               DispatchLedger.get_record(runner.tenant_id, record.dispatch_id)
    end

    test "nothing is recorded for a dispatch whose epoch is not the story's, or whose story does not exist",
         %{runner: runner} do
      story = fixture(:ledger_story, %{tenant_id: runner.tenant_id, claim_epoch: 3})

      for payload <- [
            build(:runner_dispatch, %{"story_id" => story.id, "claim_epoch" => 2}),
            build(:runner_dispatch, %{"claim_epoch" => 0})
          ] do
        {:ok, dispatch} = RunnerContract.cast_dispatch(payload)

        assert {:error, :stale_claim_epoch} =
                 DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)

        assert DispatchLedger.get_record(runner.tenant_id, dispatch.dispatch_id) == nil
      end
    end

    test "another tenant's story is not a story for this tenant's dispatch", %{runner: runner} do
      tenant_b = fixture(:committed_tenant, %{})
      theirs = fixture(:ledger_story, %{tenant_id: tenant_b.id})

      {:ok, dispatch} =
        RunnerContract.cast_dispatch(build(:runner_dispatch, %{"story_id" => theirs.id}))

      assert {:error, :stale_claim_epoch} =
               DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)
    end
  end

  describe "values a runner can send" do
    test "an uppercase run_id is one run across batches", %{runner: runner} do
      record = accepted(runner)
      upper = String.upcase(Ecto.UUID.generate())

      assert {:ok, 0} = trace(runner, record, upper, [0])
      assert {:ok, 1} = trace(runner, record, upper, [1])
      assert {:ok, 2} = trace(runner, record, String.downcase(upper), [2])
      assert DispatchLedger.trace_cursor(runner.tenant_id, runner.id, String.downcase(upper)) == 2
    end

    test "an uppercase story_id or dispatch_id is sendable, and a re-send finds the same row",
         %{runner: runner} do
      story = fixture(:ledger_story, %{tenant_id: runner.tenant_id})

      payload =
        build(:runner_dispatch, %{
          "dispatch_id" => String.upcase(Ecto.UUID.generate()),
          "story_id" => String.upcase(story.id)
        })

      {:ok, dispatch} = RunnerContract.cast_dispatch(payload)
      assert {:ok, first} = DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)
      assert {:ok, again} = DispatchLedger.record_sent(runner.tenant_id, runner.id, dispatch)
      assert again.id == first.id

      {:ok, reply} =
        RunnerContract.cast_dispatch_reply(%{
          "dispatch_id" => payload["dispatch_id"],
          "claim_epoch" => 0,
          "decision" => "accepted"
        })

      assert {:ok, %{status: "accepted"}} =
               DispatchLedger.record_reply(runner.tenant_id, runner.id, reply)
    end

    test "a seq at max_seq is stored, and the ack keeps advancing after it", %{runner: runner} do
      record = accepted(runner)
      run_id = Ecto.UUID.generate()

      assert {:ok, 0} = trace(runner, record, run_id, [0, RunnerContract.max_seq()])
      assert {:ok, 1} = trace(runner, record, run_id, [1])
      assert {:ok, 2} = trace(runner, record, run_id, [2])
    end

    test "a value Postgres refuses is rejected_by_database, never a raise, and the next call works",
         %{runner: runner} do
      record = accepted(runner)
      run_id = Ecto.UUID.generate()

      {:ok, batch} =
        RunnerContract.cast_trace_batch(
          build(:runner_trace_batch, %{
            :seqs => [0],
            "run_id" => run_id,
            "dispatch_id" => record.dispatch_id,
            "claim_epoch" => record.claim_epoch
          })
        )

      # Built past the contract cast, which refuses these first: the backstop is what is tested.
      nul_data =
        update_in(
          batch,
          [:events, Access.at(0)],
          &Map.put(&1, :data, %{"k" => "SECRET" <> <<0>>})
        )

      nul_text = update_in(batch, [:events, Access.at(0)], &Map.put(&1, :type, "SECRET" <> <<0>>))

      past_bound =
        update_in(batch, [:events, Access.at(0)], &Map.put(&1, :seq, 9_223_372_036_854_775_807))

      for bad <- [nul_data, nul_text, past_bound] do
        assert {:error, :rejected_by_database} =
                 DispatchLedger.record_trace(runner.tenant_id, runner.id, bad)
      end

      assert {:ok, 0} = DispatchLedger.record_trace(runner.tenant_id, runner.id, batch)

      pending = sent(runner)

      reply = %{
        dispatch_id: pending.dispatch_id,
        claim_epoch: pending.claim_epoch,
        decision: "refused",
        reason: "other",
        detail: "SECRET" <> <<0>>
      }

      assert {:error, :rejected_by_database} =
               DispatchLedger.record_reply(runner.tenant_id, runner.id, reply)

      assert DispatchLedger.get_record(runner.tenant_id, pending.dispatch_id).status == "sent"
    end

    test "a rejection is logged and counted with identifiers and SQLSTATE, never the value",
         %{runner: runner} do
      record = accepted(runner)
      run_id = Ecto.UUID.generate()
      handler = "ledger-rejected-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:loopctl, :runners, :ledger_rejected_by_database],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:rejected, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, batch} =
        RunnerContract.cast_trace_batch(
          build(:runner_trace_batch, %{
            :seqs => [0],
            "run_id" => run_id,
            "dispatch_id" => record.dispatch_id,
            "claim_epoch" => record.claim_epoch
          })
        )

      bad = update_in(batch, [:events, Access.at(0)], &Map.put(&1, :type, "SECRET" <> <<0>>))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :rejected_by_database} =
                   DispatchLedger.record_trace(runner.tenant_id, runner.id, bad)
        end)

      assert_received {:rejected, %{count: 1}, metadata}
      assert metadata.operation == :record_trace
      assert metadata.tenant_id == runner.tenant_id
      assert metadata.runner_id == runner.id
      assert metadata.dispatch_id == record.dispatch_id
      assert metadata.run_id == run_id
      assert "22" <> _ = metadata.sqlstate

      for fragment <- [
            "rejected by the database",
            "operation=record_trace",
            "sqlstate=#{metadata.sqlstate}",
            runner.tenant_id,
            runner.id,
            record.dispatch_id,
            run_id
          ] do
        assert log =~ fragment
      end

      refute log =~ "SECRET"
      refute inspect(metadata) =~ "SECRET"
    end

    test "record_sent/3 is not a runner write: a database error there raises", %{runner: runner} do
      {:ok, dispatch} = RunnerContract.cast_dispatch(dispatch_payload(runner.tenant_id))

      # Server-side input the contract cannot produce; Postgres refuses the NUL in `kind`.
      assert_raise Postgrex.Error, fn ->
        DispatchLedger.record_sent(runner.tenant_id, runner.id, %{
          dispatch
          | kind: "implement" <> <<0>>
        })
      end
    end
  end

  describe "the Repo path" do
    test "every ledger and trace query runs on Loopctl.Repo inside an RLS context, none on AdminRepo",
         %{runner: runner} do
      handler = "dispatch-ledger-repo-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler,
        [[:loopctl, :repo, :query], [:loopctl, :admin_repo, :query]],
        fn [:loopctl, repo, :query], _measurements, metadata, _config ->
          if metadata[:source] in ["runner_dispatches", "runner_trace_events"] or
               String.contains?(metadata[:query] || "", "app.current_tenant_id") do
            send(test_pid, {:ledger_query, repo, metadata[:source], metadata[:params]})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      record = accepted(runner)
      run_id = Ecto.UUID.generate()
      assert {:ok, 0} = trace(runner, record, run_id, [0])
      assert DispatchLedger.trace_cursor(runner.tenant_id, runner.id, run_id) == 0
      assert DispatchLedger.get_record(runner.tenant_id, record.dispatch_id)
      :telemetry.detach(handler)

      queries = collect_ledger_queries([])
      sources = for {_repo, source, _params} <- queries, source, do: source

      assert "runner_dispatches" in sources
      assert "runner_trace_events" in sources

      assert Enum.all?(queries, fn {repo, _, _} -> repo == :repo end),
             "a ledger query ran on AdminRepo: #{inspect(queries)}"

      assert Enum.any?(queries, fn {_repo, source, params} ->
               is_nil(source) and runner.tenant_id in List.wrap(params)
             end),
             "no RLS context was set for the tenant on the Repo connection"
    end

    test "under RLS alone, one tenant's context reads none of another tenant's rows",
         %{runner: runner} do
      tenant_b = fixture(:committed_tenant, %{})
      {_raw, runner_b} = fixture(:committed_runner, %{name: "minis", tenant_id: tenant_b.id})
      run_a = Ecto.UUID.generate()
      run_b = Ecto.UUID.generate()

      record_a = accepted(runner)
      record_b = accepted(runner_b)
      assert {:ok, 0} = trace(runner, record_a, run_a, [0])
      assert {:ok, 0} = trace(runner_b, record_b, run_b, [0])

      # No tenant predicate in these queries: only the policy can filter them.
      for {tenant_id, own_record, own_run} <- [
            {runner.tenant_id, record_a, run_a},
            {tenant_b.id, record_b, run_b}
          ] do
        assert [%DispatchRecord{id: id}] =
                 as_tenant(tenant_id, fn -> Repo.all(DispatchRecord) end)

        assert id == own_record.id

        assert [%TraceEvent{run_id: ^own_run}] =
                 as_tenant(tenant_id, fn -> Repo.all(TraceEvent) end)
      end

      # And the context functions refuse across tenants on the same path, in both
      # directions (a stale RLS context left by the last read must not decide either).
      assert DispatchLedger.get_record(tenant_b.id, record_a.dispatch_id) == nil
      assert DispatchLedger.get_record(runner.tenant_id, record_b.dispatch_id) == nil
      assert DispatchLedger.trace_cursor(tenant_b.id, runner_b.id, run_a) == -1
    end
  end

  defp collect_ledger_queries(acc) do
    receive do
      {:ledger_query, repo, source, params} ->
        collect_ledger_queries([{repo, source, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
