defmodule Loopctl.Changes.EventsTest do
  @moduledoc """
  US-47.3: receipt, verification, idempotency, ordering and audit of chg change events
  (`Loopctl.Changes.Events`). The HTTP surface is `LoopctlWeb.ChangeEventControllerTest`; the
  pull is `Loopctl.Changes.ReconcileTest`; genuine lock contention is
  `Loopctl.Changes.EventsLockTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Changes
  alias Loopctl.Changes.Cursor
  alias Loopctl.Changes.Event
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.Signature
  alias Loopctl.Changes.UnboundEvent
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake.Source

  setup :verify_on_exit!

  setup do
    %{secret: secret, source: source, root: root} = fixture(:chg_source, %{})
    %{secret: secret, source: source, root: root, tenant_id: source.tenant_id}
  end

  defp push(ctx, event, opts \\ []) do
    raw = Keyword.get_lazy(opts, :raw, fn -> Jason.encode!(event) end)
    ts = Keyword.get(opts, :timestamp, Integer.to_string(System.os_time(:second)))
    secret = Keyword.get(opts, :secret, ctx.secret)

    signature =
      Keyword.get(opts, :signature, Signature.header(secret, Signature.delivery_string(ts, raw)))

    Events.receive_push(
      Keyword.get(opts, :source_id, ctx.source.id),
      %{raw_body: raw, timestamp: ts, signature: signature},
      Keyword.take(opts, [:now, :before_hold])
    )
  end

  defp event(change_id, seq, attrs \\ %{}),
    do: build(:chg_event, Map.merge(%{change_id: change_id, event_seq: seq}, attrs))

  defp applied_entries(tenant_id) do
    AdminRepo.all(
      from e in Entry,
        where: e.tenant_id == ^tenant_id and e.action == "change_event_applied",
        order_by: [asc: e.chain_position],
        select: e.payload
    )
  end

  defp count(schema, tenant_id),
    do: AdminRepo.aggregate(from(r in schema, where: r.tenant_id == ^tenant_id), :count)

  # Telemetry handlers run in the process that emits, so filtering on the test pid keeps a
  # concurrent test's refusals out of this one's mailbox.
  defp capture_refusals do
    parent = self()
    id = "changes-refused-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:loopctl, :changes, :event_refused],
      fn _event, measurements, metadata, _ ->
        if self() == parent, do: send(parent, {:refused, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "AC-47.3.2 / AC-47.3.4: an event is stored, applied once and audited" do
    test "seq 1 applies and appends change_id, event_seq and sha to the audit chain", ctx do
      e = event("C1", 1)

      assert {:ok, %{outcome: :applied, applied_seq: 1}} = push(ctx, e)

      assert [%Event{} = row] = Events.list_events(ctx.tenant_id, "mkreyman/infra", "C1")
      assert row.applied_at
      assert row.received_via == "push"
      assert row.source_id == ctx.source.id
      assert row.effect == %{"effect" => "recorded"}
      assert row.sha == e["sha"]

      assert [payload] = applied_entries(ctx.tenant_id)
      assert payload["change_id"] == "C1"
      assert payload["event_seq"] == 1
      assert payload["sha"] == e["sha"]
      assert payload["repo"] == "mkreyman/infra"
      assert payload["kind"] == "check_passed"
    end

    test "TC-47.3.2: a redelivery answers duplicate, applies nothing twice, audits once", ctx do
      e = event("C1", 1)
      assert {:ok, %{outcome: :applied}} = push(ctx, e)

      # Re-signed at send time, as chg does: a fresh timestamp over the same body.
      assert {:ok, %{outcome: :duplicate, applied_seq: 1}} = push(ctx, e)

      assert [_one] = Events.list_events(ctx.tenant_id, "mkreyman/infra", "C1")
      assert [_one_entry] = applied_entries(ctx.tenant_id)
    end

    test "the same key with different content is a conflict and writes nothing", ctx do
      e = event("C1", 1)
      assert {:ok, %{outcome: :applied}} = push(ctx, e)

      different = Map.put(e, "sha", String.duplicate("a", 40))
      assert {:error, :event_conflict} = push(ctx, different)

      assert [%Event{sha: sha}] = Events.list_events(ctx.tenant_id, "mkreyman/infra", "C1")
      assert sha == e["sha"]
      assert [_one_entry] = applied_entries(ctx.tenant_id)
    end

    test "the repository is keyed canonically, not by the envelope's spelling", ctx do
      e = event("C1", 1)
      assert {:ok, %{outcome: :applied}} = push(ctx, e)

      # A case-variant of the same repository is the same key, so this is a redelivery.
      assert {:ok, %{outcome: :duplicate}} = push(ctx, Map.put(e, "repo", "MKreyman/Infra"))

      assert [%Event{repo: "mkreyman/infra"}] =
               AdminRepo.all(from(r in Event, where: r.tenant_id == ^ctx.tenant_id))

      # Any spelling reads the one change.
      assert [_one] = Events.list_events(ctx.tenant_id, "MKreyman/Infra", "C1")
    end
  end

  describe "one canonical repository key across re-enrolment" do
    test "re-enrolled under another spelling, the change keeps one cursor and one binding",
         ctx do
      story = fixture(:story, %{tenant_id: ctx.tenant_id})
      submitted = event("C1", 1, %{kind: "submitted", data: %{"story_id" => story.id}})
      assert {:ok, %{outcome: :applied}} = push(ctx, submitted)

      for seq <- 2..6, do: assert({:ok, %{outcome: :applied}} = push(ctx, event("C1", seq)))

      {:ok, _} = Loopctl.Intake.revoke_source(ctx.tenant_id, ctx.source.id)

      %{secret: secret, source: source} =
        fixture(:chg_source, %{tenant_id: ctx.tenant_id, repo_full_name: "MKreyman/Infra"})

      ctx = %{ctx | secret: secret, source: source}
      seven = event("C1", 7, %{repo: "MKreyman/Infra"})
      assert {:ok, %{outcome: :applied, applied_seq: 7}} = push(ctx, seven)

      # A redelivery of an event applied under the old spelling is still a duplicate.
      assert {:ok, %{outcome: :duplicate, applied_seq: 7}} =
               push(ctx, Map.put(submitted, "repo", "MKreyman/Infra"))

      assert [%Cursor{repo: "mkreyman/infra", applied_seq: 7, source_id: source_id}] =
               AdminRepo.all(from(c in Cursor, where: c.tenant_id == ^ctx.tenant_id))

      assert source_id == source.id
      assert length(applied_entries(ctx.tenant_id)) == 7
      assert count(Event, ctx.tenant_id) == 7

      assert %Changes.Binding{repo: "mkreyman/infra", change_id: "C1"} =
               Changes.current_binding(ctx.tenant_id, story.id)
    end
  end

  describe "AC-47.3.3: events apply in event_seq order per change" do
    test "TC-47.3.3: seq 2 is held until seq 1 arrives, then both apply in order", ctx do
      assert {:ok, %{outcome: :held, applied_seq: 0}} = push(ctx, event("C1", 2))

      assert [%Event{event_seq: 2, applied_at: nil}] =
               Events.list_events(ctx.tenant_id, "mkreyman/infra", "C1")

      assert applied_entries(ctx.tenant_id) == []

      assert {:ok, %{outcome: :applied, applied_seq: 2}} = push(ctx, event("C1", 1))

      assert [%Event{event_seq: 1, applied_at: a1}, %Event{event_seq: 2, applied_at: a2}] =
               Events.list_events(ctx.tenant_id, "mkreyman/infra", "C1")

      assert a1 && a2
      assert Enum.map(applied_entries(ctx.tenant_id), & &1["event_seq"]) == [1, 2]
      assert %Cursor{applied_seq: 2} = Events.get_cursor(ctx.tenant_id, "mkreyman/infra", "C1")
    end

    test "a held event's redelivery is a duplicate and still waits", ctx do
      e3 = event("C1", 3)
      assert {:ok, %{outcome: :held}} = push(ctx, e3)
      assert {:ok, %{outcome: :duplicate, applied_seq: 0}} = push(ctx, e3)
      assert {:ok, %{outcome: :applied, applied_seq: 1}} = push(ctx, event("C1", 1))
      assert {:ok, %{outcome: :applied, applied_seq: 3}} = push(ctx, event("C1", 2))
    end

    test "two changes order independently", ctx do
      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 2))
      assert {:ok, %{outcome: :applied, applied_seq: 1}} = push(ctx, event("C2", 1))
      assert %Cursor{applied_seq: 0} = Events.get_cursor(ctx.tenant_id, "mkreyman/infra", "C1")
    end
  end

  describe "AC-47.3.6: an unmapped kind is recorded and keeps ordering whole" do
    test "TC-47.3.5: submitted, review_requested, review_findings apply in turn, none held",
         ctx do
      story = fixture(:story, %{tenant_id: ctx.tenant_id})

      assert {:ok, %{outcome: :applied, applied_seq: 1}} =
               push(ctx, event("C1", 1, %{kind: "submitted", data: %{"story_id" => story.id}}))

      assert {:ok, %{outcome: :applied, applied_seq: 2}} =
               push(ctx, event("C1", 2, %{kind: "review_requested"}))

      # seq 3 is not held behind seq 2: an unmapped kind advanced the cursor.
      assert {:ok, %{outcome: :applied, applied_seq: 3}} =
               push(
                 ctx,
                 event("C1", 3, %{
                   kind: "review_findings",
                   data: %{"findings" => 2, "round" => 1, "dispatch_key" => "k"}
                 })
               )

      assert [_, %Event{effect: %{"effect" => "recorded"}}, _] =
               Events.list_events(ctx.tenant_id, "mkreyman/infra", "C1")

      # US-47.3 moves no stage: the stage mapping is US-47.4's.
      assert count(StoryStage, ctx.tenant_id) == 0
    end

    test "check_failed, conflict, ready and a kind chg adds later are all recorded", ctx do
      for {kind, seq} <- Enum.with_index(~w(check_failed conflict ready a_future_kind), 1) do
        assert {:ok, %{outcome: :applied, applied_seq: ^seq}} =
                 push(ctx, event("C1", seq, %{kind: kind}))
      end

      assert Enum.map(applied_entries(ctx.tenant_id), & &1["kind"]) ==
               ~w(check_failed conflict ready a_future_kind)
    end
  end

  describe "a submitted event binds its change (PRD §4)" do
    test "a story the tenant owns is bound, by the webhook as a non-claimant", ctx do
      story = fixture(:story, %{tenant_id: ctx.tenant_id})

      assert {:ok, %{outcome: :applied}} =
               push(ctx, event("C1", 1, %{kind: "submitted", data: %{"story_id" => story.id}}))

      binding = Changes.current_binding(ctx.tenant_id, story.id)
      assert binding.change_id == "C1"
      assert binding.repo == "mkreyman/infra"
      assert binding.submitter_not_claimant

      [%Event{effect: effect}] = Events.list_events(ctx.tenant_id, "mkreyman/infra", "C1")
      assert effect["binding"] == %{"outcome" => "bound", "id" => binding.id}
    end

    test "a later revision's submitted finds the existing binding", ctx do
      story = fixture(:story, %{tenant_id: ctx.tenant_id})
      data = %{"story_id" => story.id}

      assert {:ok, _} = push(ctx, event("C1", 1, %{kind: "submitted", data: data}))

      assert {:ok, %{outcome: :applied}} =
               push(ctx, event("C1", 2, %{kind: "submitted", revision: 2, data: data}))

      assert [_one] = Changes.list_bindings(ctx.tenant_id, story.id)

      [_, %Event{effect: effect}] = Events.list_events(ctx.tenant_id, "mkreyman/infra", "C1")
      assert effect["binding"]["outcome"] == "existing"
    end

    test "another tenant's story never binds and the event still applies", ctx do
      other = fixture(:tenant)
      foreign = fixture(:story, %{tenant_id: other.id})

      assert {:ok, %{outcome: :applied}} =
               push(ctx, event("C1", 1, %{kind: "submitted", data: %{"story_id" => foreign.id}}))

      assert Changes.list_bindings(other.id, foreign.id) == []

      assert [%UnboundEvent{}] =
               Changes.list_unbound_events(ctx.tenant_id, "mkreyman/infra", "C1")

      assert count(UnboundEvent, other.id) == 0
    end

    test "a change bound to another story is refused as the effect, not as the event", ctx do
      story = fixture(:story, %{tenant_id: ctx.tenant_id})
      other = fixture(:story, %{tenant_id: ctx.tenant_id})

      fixture(:change_binding, %{
        tenant_id: ctx.tenant_id,
        story_id: other.id,
        repo: "mkreyman/infra",
        change_id: "C1"
      })

      assert {:ok, %{outcome: :applied, applied_seq: 1}} =
               push(ctx, event("C1", 1, %{kind: "submitted", data: %{"story_id" => story.id}}))

      [%Event{effect: effect}] = Events.list_events(ctx.tenant_id, "mkreyman/infra", "C1")

      assert effect["binding"] == %{
               "outcome" => "refused",
               "reason" => "change_bound_to_other_story"
             }

      assert Changes.current_binding(ctx.tenant_id, story.id) == nil
    end

    test "a null story_id binds nothing", ctx do
      assert {:ok, %{outcome: :applied}} =
               push(ctx, event("C1", 1, %{kind: "submitted", data: %{"story_id" => nil}}))

      [%Event{effect: effect}] = Events.list_events(ctx.tenant_id, "mkreyman/infra", "C1")
      assert effect["binding"] == "no_story"
    end
  end

  describe "AC-47.3.1 / AC-47.3.7: every refusal is :unauthorized and writes nothing" do
    setup do
      capture_refusals()
      :ok
    end

    defp assert_nothing_written(ctx) do
      assert count(Event, ctx.tenant_id) == 0
      assert count(Cursor, ctx.tenant_id) == 0
      assert applied_entries(ctx.tenant_id) == []
    end

    test "an unknown source id", ctx do
      assert {:error, :unauthorized} = push(ctx, event("C1", 1), source_id: Ecto.UUID.generate())
      assert {:error, :unauthorized} = push(ctx, event("C1", 1), source_id: "not-a-uuid")
      assert_receive {:refused, %{count: 1}, %{source: "unknown", reason: :unknown_source}}
      assert_nothing_written(ctx)
    end

    test "a wrong signature, a missing one and another source's secret", ctx do
      assert {:error, :unauthorized} =
               push(ctx, event("C1", 1), signature: "sha256=" <> String.duplicate("0", 64))

      assert {:error, :unauthorized} = push(ctx, event("C1", 1), signature: nil)

      assert {:error, :unauthorized} =
               push(ctx, event("C1", 1), secret: String.duplicate("x", 32))

      source_id = ctx.source.id
      assert_receive {:refused, _, %{source: ^source_id, reason: :bad_signature}}
      assert_nothing_written(ctx)
    end

    test "a timestamp six minutes old, or six minutes ahead, or not a number", ctx do
      now = System.os_time(:second)

      for ts <- [now - 360, now + 360] do
        assert {:error, :unauthorized} =
                 push(ctx, event("C1", 1), timestamp: Integer.to_string(ts), now: now)
      end

      assert {:error, :unauthorized} = push(ctx, event("C1", 1), timestamp: "soon")

      # Inside the window either way is fine.
      assert {:ok, _} =
               push(ctx, event("C1", 1), timestamp: Integer.to_string(now - 290), now: now)

      source_id = ctx.source.id
      assert_receive {:refused, _, %{source: ^source_id, reason: :stale_timestamp}}
    end

    test "TC-47.3.6: a chg root revoked after enrolment refuses a correctly signed event", ctx do
      {1, _} =
        AdminRepo.update_all(
          from(d in Loopctl.Dispatches.Dispatch, where: d.id == ^ctx.root.id),
          set: [revoked_at: DateTime.utc_now()]
        )

      assert {:error, :unauthorized} = push(ctx, event("C1", 1))
      source_id = ctx.source.id
      assert_receive {:refused, _, %{source: ^source_id, reason: :chg_root_invalid}}
      assert_nothing_written(ctx)
    end

    test "a root that is no longer parentless is refused the same way", ctx do
      parent = fixture(:chg_root_dispatch, %{tenant_id: ctx.tenant_id})

      {1, _} =
        AdminRepo.update_all(
          from(d in Loopctl.Dispatches.Dispatch, where: d.id == ^ctx.root.id),
          set: [parent_dispatch_id: parent.id]
        )

      assert {:error, :unauthorized} = push(ctx, event("C1", 1))
      assert_nothing_written(ctx)
    end

    test "a revoked source, and a source switched back to pr", ctx do
      {:ok, _} = Loopctl.Intake.update_source(ctx.tenant_id, ctx.source.id, %{mode: "pr"})
      assert {:error, :unauthorized} = push(ctx, event("C1", 1))
      source_id = ctx.source.id
      assert_receive {:refused, _, %{source: ^source_id, reason: :not_chg_source}}

      {1, _} =
        AdminRepo.update_all(from(s in Source, where: s.id == ^ctx.source.id),
          set: [mode: :chg, revoked_at: DateTime.utc_now()]
        )

      assert {:error, :unauthorized} = push(ctx, event("C1", 1))
      assert_nothing_written(ctx)
    end

    test "a secret rotated after the pre-check refuses the event signed with the old one", ctx do
      new_secret = "chg-rotated-" <> Base.encode16(:crypto.strong_rand_bytes(16))

      rotate = fn ->
        {:ok, _} =
          Loopctl.Intake.update_source(ctx.tenant_id, ctx.source.id, %{
            change_events_secret: new_secret
          })
      end

      assert {:error, :unauthorized} = push(ctx, event("C1", 1), before_hold: rotate)
      source_id = ctx.source.id
      assert_receive {:refused, _, %{source: ^source_id, reason: :bad_signature}}
      assert_nothing_written(ctx)

      # The new secret is the one that now authenticates.
      assert {:ok, %{outcome: :applied}} = push(ctx, event("C1", 1), secret: new_secret)
    end

    test "a tenant suspended after the pre-check refuses the event", ctx do
      suspend = fn ->
        {:ok, tenant} = Loopctl.Tenants.get_tenant(ctx.tenant_id)
        {:ok, _} = Loopctl.Tenants.suspend_tenant(tenant)
      end

      assert {:error, :unauthorized} = push(ctx, event("C1", 1), before_hold: suspend)
      source_id = ctx.source.id
      assert_receive {:refused, _, %{source: ^source_id, reason: :tenant_inactive}}
      assert_nothing_written(ctx)
    end

    test "an envelope naming another repository", ctx do
      assert {:error, :unauthorized} = push(ctx, event("C1", 1, %{repo: "mkreyman/loopctl"}))
      source_id = ctx.source.id
      assert_receive {:refused, _, %{source: ^source_id, reason: :repository_mismatch}}
      assert_nothing_written(ctx)
    end

    test "the refusal log names no secret and no body", ctx do
      e = event("C1", 1, %{data: %{"marker" => "body-marker-xyz"}})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :unauthorized} =
                   push(ctx, e, signature: "sha256=" <> String.duplicate("0", 64))
        end)

      assert log =~ "change event refused"
      refute log =~ ctx.secret
      refute log =~ "body-marker-xyz"
    end
  end

  describe "a signed but malformed body" do
    test "is a bad request and writes nothing", ctx do
      for bad <- [
            Map.put(event("C1", 1), "v", 2),
            Map.delete(event("C1", 1), "sha"),
            Map.put(event("C1", 1), "event_seq", 0),
            Map.put(event("C1", 1), "kind", "Not A Kind"),
            Map.put(event("C1", 1), "sha", "nothex"),
            Map.put(event("C1", 1), "change_id", "has/slash"),
            Map.put(event("C1", 1), "data", "not an object")
          ] do
        assert {:error, {:bad_request, "invalid_event"}} = push(ctx, bad)
      end

      assert {:error, {:bad_request, "invalid_event"}} = push(ctx, nil, raw: "not json")
      assert count(Event, ctx.tenant_id) == 0
    end
  end

  describe "tenant isolation" do
    test "tenant B reads none of tenant A's events or cursors", ctx do
      assert {:ok, _} = push(ctx, event("C1", 1))
      other = fixture(:tenant)

      assert Events.list_events(other.id, "mkreyman/infra", "C1") == []
      assert Events.get_cursor(other.id, "mkreyman/infra", "C1") == nil
      assert [_] = Events.list_events(ctx.tenant_id, "mkreyman/infra", "C1")
    end

    test "tenant B's source id signed with tenant A's secret is the same refusal", ctx do
      %{source: b_source} = fixture(:chg_source, %{})

      assert {:error, :unauthorized} = push(ctx, event("C1", 1), source_id: b_source.id)
      assert count(Event, b_source.tenant_id) == 0
      assert count(Event, ctx.tenant_id) == 0
    end
  end
end
