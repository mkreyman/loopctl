defmodule Loopctl.Holders.LeaseTest do
  @moduledoc """
  US-52.19: a holder's claims live by the holder's lease. A claim takes the lease, a heartbeat
  and a renew move it, a late heartbeat ends the holder, an end releases the claims, and the
  reclaim sweep ends every holder whose session can no longer be working.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches
  alias Loopctl.Holders
  alias Loopctl.Holders.Holder
  alias Loopctl.Progress
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ReclaimExpiredClaimsWorker

  setup :verify_on_exit!

  setup do
    agent = fixture(:agent, %{agent_type: :implementer})
    %{agent: agent, tenant_id: agent.tenant_id}
  end

  defp register(ctx, session_id) do
    attrs = %{"kind" => "interactive", "session_id" => session_id, "host" => "minis"}
    {:ok, result} = Holders.register(ctx.tenant_id, ctx.agent.id, attrs)
    result
  end

  defp story(ctx), do: fixture(:story, %{tenant_id: ctx.tenant_id, agent_status: :contracted})

  defp as(ctx, holder_id), do: [agent_id: ctx.agent.id, holder_id: holder_id]

  defp set_lease(%Holder{} = holder, until) do
    holder |> Ecto.Changeset.change(lease_until: until) |> AdminRepo.update!()
  end

  defp seconds(n), do: DateTime.add(DateTime.utc_now(), n, :second)

  defp reload(story), do: AdminRepo.get!(Story, story.id)

  defp released_reasons(tenant_id, story_id) do
    for %StageEvent{event: "released", reason: reason} <- Stages.list_events(tenant_id, story_id),
        do: reason
  end

  defp holder_row(id), do: AdminRepo.get!(Holder, id)

  defp live_keys(tenant_id, holder_id) do
    from(k in ApiKey,
      where: k.tenant_id == ^tenant_id and k.holder_id == ^holder_id and is_nil(k.revoked_at)
    )
    |> AdminRepo.aggregate(:count)
  end

  describe "a claim (AC-52.19.3)" do
    test "TC-52.19.2: takes the holder's lease and no cap; a lapsed or ended holder is refused",
         ctx do
      %{holder: h} = register(ctx, "live")
      h = set_lease(h, seconds(300))
      {:ok, claimed} = Progress.claim_story(ctx.tenant_id, story(ctx).id, as(ctx, h.id))

      assert claimed.claimed_until == h.lease_until
      assert is_nil(claimed.claim_lease_cap)

      %{holder: l} = register(ctx, "lapsed")
      l = set_lease(l, seconds(-1))
      s2 = story(ctx)

      assert {:error, :holder_lease_expired} =
               Progress.claim_story(ctx.tenant_id, s2.id, as(ctx, l.id))

      assert reload(s2).agent_status == :contracted

      %{holder: e, api_key: key} = register(ctx, "ended")
      {:ok, _} = Holders.end_holder(ctx.tenant_id, key, e.id)

      assert {:error, :holder_lease_expired} =
               Progress.claim_story(ctx.tenant_id, story(ctx).id, as(ctx, e.id))
    end

    test "a key with no holder keeps the global lease, and a cap stays a cap", ctx do
      {:ok, plain} = Progress.claim_story(ctx.tenant_id, story(ctx).id, as(ctx, nil))
      expected = DateTime.add(plain.assigned_at, Progress.claim_lease_seconds(), :second)
      assert abs(DateTime.diff(plain.claimed_until, expected)) <= 1

      %{holder: h} = register(ctx, "capped")
      cap = seconds(120)

      {:ok, capped} =
        Progress.claim_story(
          ctx.tenant_id,
          story(ctx).id,
          as(ctx, h.id) ++ [lease_until: cap]
        )

      assert capped.claim_lease_cap == cap
      assert capped.claimed_until == cap
    end

    test "a bulk claim by a holder takes its lease; a lapsed holder's bulk claim is refused",
         ctx do
      %{holder: h} = register(ctx, "bulk")
      h = set_lease(h, seconds(300))
      s = story(ctx)

      {:ok, [%{status: "success"}]} =
        Loopctl.BulkOperations.bulk_claim(ctx.tenant_id, [s.id], ctx.agent.id, holder_id: h.id)

      assert reload(s).claimed_until == h.lease_until
      assert is_nil(reload(s).claim_lease_cap)

      set_lease(h, seconds(-1))
      s2 = story(ctx)

      {:ok, [%{status: "error", reason: reason}]} =
        Loopctl.BulkOperations.bulk_claim(ctx.tenant_id, [s2.id], ctx.agent.id, holder_id: h.id)

      assert reason =~ "holder_lease_expired"
    end
  end

  describe "the heartbeat and renew (AC-52.19.4)" do
    test "TC-52.19.3: move uncapped claims only, never earlier; a plain key keeps the global lease",
         ctx do
      %{holder: h, api_key: key} = register(ctx, "hb")
      {:ok, s1} = Progress.claim_story(ctx.tenant_id, story(ctx).id, as(ctx, h.id))
      cap = seconds(90)

      {:ok, s2} =
        Progress.claim_story(ctx.tenant_id, story(ctx).id, as(ctx, h.id) ++ [lease_until: cap])

      {:ok, s3} = Progress.claim_story(ctx.tenant_id, story(ctx).id, as(ctx, nil))

      later = seconds(30)
      {:ok, beat} = Holders.heartbeat(ctx.tenant_id, key, h.id, now: later)

      assert reload(s1).claimed_until == beat.lease_until
      assert reload(s2).claimed_until == cap
      assert reload(s3).claimed_until == s3.claimed_until

      # An earlier heartbeat (a delayed duplicate) never moves a claim back.
      {:ok, _} = Holders.heartbeat(ctx.tenant_id, key, h.id, now: DateTime.utc_now())
      assert reload(s1).claimed_until == beat.lease_until

      {:ok, renewed} =
        Progress.renew_claim(
          ctx.tenant_id,
          s1.id,
          as(ctx, h.id) ++ [claim_epoch: s1.claim_epoch]
        )

      assert renewed.claimed_until == holder_row(h.id).lease_until

      {:ok, plain} =
        Progress.renew_claim(ctx.tenant_id, s3.id, as(ctx, nil) ++ [claim_epoch: s3.claim_epoch])

      expected = DateTime.add(DateTime.utc_now(), Progress.claim_lease_seconds(), :second)
      assert abs(DateTime.diff(plain.claimed_until, expected)) <= 2
    end

    test "a renew by a lapsed holder is refused", ctx do
      %{holder: h} = register(ctx, "renew-lapsed")
      {:ok, s} = Progress.claim_story(ctx.tenant_id, story(ctx).id, as(ctx, h.id))
      set_lease(holder_row(h.id), seconds(-1))

      assert {:error, :holder_lease_expired} =
               Progress.renew_claim(
                 ctx.tenant_id,
                 s.id,
                 as(ctx, h.id) ++ [claim_epoch: s.claim_epoch]
               )
    end

    test "a heartbeat after the lease ends the holder lapsed and releases its claims (AC-52.19.5)",
         ctx do
      %{holder: h, api_key: key} = register(ctx, "late")
      {:ok, s} = Progress.claim_story(ctx.tenant_id, story(ctx).id, as(ctx, h.id))

      assert {:error, :holder_lease_expired} =
               Holders.heartbeat(ctx.tenant_id, key, h.id,
                 now: seconds(Holders.lease_seconds() + 1)
               )

      ended = holder_row(h.id)
      assert ended.ended_reason == :lapsed
      assert ended.ended_at
      assert live_keys(ctx.tenant_id, h.id) == 0
      assert reload(s).agent_status == :pending
      assert released_reasons(ctx.tenant_id, s.id) == ["holder lapsed"]
    end
  end

  describe "an explicit end (AC-52.19.7)" do
    test "TC-52.19.7: releases the holder's uncapped claims with 'holder ended'", ctx do
      %{holder: h, api_key: key} = register(ctx, "end")
      {:ok, s1} = Progress.claim_story(ctx.tenant_id, story(ctx).id, as(ctx, h.id))

      {:ok, s2} =
        Progress.claim_story(
          ctx.tenant_id,
          story(ctx).id,
          as(ctx, h.id) ++ [lease_until: seconds(300)]
        )

      {:ok, _} = Holders.end_holder(ctx.tenant_id, key, h.id)

      released = reload(s1)
      assert released.agent_status == :pending
      assert is_nil(released.assigned_holder_id)
      assert released_reasons(ctx.tenant_id, s1.id) == ["holder ended"]

      # A capped claim belongs to its dispatch lease.
      assert reload(s2).assigned_holder_id == h.id

      # A repeated end releases nothing twice.
      {:ok, _} = Holders.end_holder(ctx.tenant_id, key, h.id)
      assert released_reasons(ctx.tenant_id, s1.id) == ["holder ended"]
    end

    test "a story whose review was requested is not released", ctx do
      %{holder: h, api_key: key} = register(ctx, "review")
      {:ok, s} = Progress.claim_story(ctx.tenant_id, story(ctx).id, as(ctx, h.id))

      reload(s)
      |> Ecto.Changeset.change(
        agent_status: :implementing,
        review_requested_at: DateTime.utc_now()
      )
      |> AdminRepo.update!()

      {:ok, _} = Holders.end_holder(ctx.tenant_id, key, h.id)
      assert reload(s).assigned_holder_id == h.id
      assert released_reasons(ctx.tenant_id, s.id) == []
    end
  end

  describe "the sweep (AC-52.19.6, AC-52.19.8)" do
    test "TC-52.19.6: ends lapsed session holders after releasing their claims", ctx do
      %{holder: d} = register(ctx, "dead")
      {:ok, ds} = Progress.claim_story(ctx.tenant_id, story(ctx).id, as(ctx, d.id))
      past = seconds(-60)
      set_lease(holder_row(d.id), past)
      reload(ds) |> Ecto.Changeset.change(claimed_until: past) |> AdminRepo.update!()

      %{holder: live} = register(ctx, "live")

      other_agent = fixture(:agent, %{agent_type: :implementer})

      {:ok, %{holder: other}} =
        Holders.register(other_agent.tenant_id, other_agent.id, %{
          "kind" => "interactive",
          "session_id" => "other",
          "host" => "x1"
        })

      set_lease(other, past)

      runner = runner_session(ctx, seconds(-700))
      {:ok, _} = Progress.claim_story(ctx.tenant_id, story(ctx).id, runner_claim(ctx, runner))

      :ok = ReclaimExpiredClaimsWorker.perform(%Oban.Job{args: %{}})

      assert reload(ds).agent_status == :pending
      assert released_reasons(ctx.tenant_id, ds.id) == ["lease expired"]
      assert holder_row(d.id).ended_reason == :lapsed
      assert live_keys(ctx.tenant_id, d.id) == 0
      assert is_nil(holder_row(live.id).ended_at)
      assert is_nil(holder_row(runner.holder.id).ended_at)

      ended_other = holder_row(other.id)
      assert ended_other.ended_reason == :lapsed
      assert ended_other.tenant_id == other_agent.tenant_id
    end

    test "TC-52.19.9: ends a runner session only when it can no longer be working", ctx do
      old = seconds(-700)
      past = seconds(-60)

      # R1: its claim's lease ran out, so the claim pass releases it and R1 holds none.
      r1 = runner_session(ctx, old)
      {:ok, r1s} = Progress.claim_story(ctx.tenant_id, story(ctx).id, runner_claim(ctx, r1))

      reload(r1s)
      |> Ecto.Changeset.change(claimed_until: past, claim_lease_cap: past)
      |> AdminRepo.update!()

      # R2: holds a live claim, but its dispatch is revoked.
      r2 = runner_session(ctx, old)
      {:ok, _} = Progress.claim_story(ctx.tenant_id, story(ctx).id, runner_claim(ctx, r2))

      r2.dispatch
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
      |> AdminRepo.update!()

      # R3: holds a live claim on a live dispatch.
      r3 = runner_session(ctx, old)
      {:ok, _} = Progress.claim_story(ctx.tenant_id, story(ctx).id, runner_claim(ctx, r3))

      # R4: its holder lease passed, its claim was moved later by the acceptance.
      r4 = runner_session(ctx, old)
      {:ok, _} = Progress.claim_story(ctx.tenant_id, story(ctx).id, runner_claim(ctx, r4))
      set_lease(holder_row(r4.holder.id), past)

      # R5: holder lease and claim cap both passed while the story waits at ci, claim held.
      r5 = runner_session(ctx, old)
      {:ok, r5s} = Progress.claim_story(ctx.tenant_id, story(ctx).id, runner_claim(ctx, r5))
      set_lease(holder_row(r5.holder.id), past)

      reload(r5s)
      |> Ecto.Changeset.change(
        agent_status: :implementing,
        claim_lease_cap: past,
        claimed_until: past,
        review_requested_at: DateTime.utc_now()
      )
      |> AdminRepo.update!()

      # R6: minted 10 s ago, its claim not committed yet.
      r6 = runner_session(ctx, seconds(-10))

      :ok = ReclaimExpiredClaimsWorker.perform(%Oban.Job{args: %{}})

      assert reload(r1s).agent_status == :pending

      for r <- [r1, r2] do
        assert holder_row(r.holder.id).ended_reason == :lapsed
        assert live_keys(ctx.tenant_id, r.holder.id) == 0
      end

      for r <- [r3, r4, r5, r6] do
        assert is_nil(holder_row(r.holder.id).ended_at)
        assert live_keys(ctx.tenant_id, r.holder.id) == 1
      end
    end

    test "a halted tenant's lapsed holders are left for after the halt", ctx do
      %{holder: d} = register(ctx, "halted")
      set_lease(holder_row(d.id), seconds(-60))

      Loopctl.Tenants.Tenant
      |> AdminRepo.get!(ctx.tenant_id)
      |> Ecto.Changeset.change(custody_halted_at: DateTime.utc_now())
      |> AdminRepo.update!()

      assert Holders.end_lapsed(DateTime.utc_now()) == 0
      assert is_nil(holder_row(d.id).ended_at)
    end
  end

  # A runner session's holder, minted with its dispatch as a placement mints it
  # (`Loopctl.Dispatches.create_dispatch/3`, US-52.15), then aged to `inserted_at`.
  defp runner_session(ctx, inserted_at) do
    {:ok, %{dispatch: dispatch, holder: holder}} =
      Dispatches.create_dispatch(
        ctx.tenant_id,
        %{role: :agent, agent_id: ctx.agent.id, expires_in_seconds: 3600},
        runner_session: %{host: "x1", lease_until: seconds(600)}
      )

    holder = holder |> Ecto.Changeset.change(inserted_at: inserted_at) |> AdminRepo.update!()
    %{dispatch: dispatch, holder: holder}
  end

  defp runner_claim(ctx, runner),
    do:
      as(ctx, runner.holder.id) ++
        [dispatch_id: runner.dispatch.id, lease_until: seconds(600)]
end
