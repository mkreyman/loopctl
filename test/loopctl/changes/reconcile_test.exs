defmodule Loopctl.Changes.ReconcileTest do
  @moduledoc """
  US-47.3 AC-47.3.3: gap and staleness reconciliation — the candidate reads, the sweep that
  enqueues one pull per change, and the pull itself against a mocked chg client.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Cursor
  alias Loopctl.Changes.Event
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.Reconcile
  alias Loopctl.Changes.Signature
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Workers.ChangeReconcileSweepWorker
  alias Loopctl.Workers.ChangeReconcileWorker
  alias Loopctl.Workers.ScaleAlertDeliveryWorker

  @repo "mkreyman/infra"
  @url "https://chg.test"

  setup :verify_on_exit!

  setup do
    %{secret: secret, source: source, root: root} = fixture(:chg_source, %{})
    %{secret: secret, source: source, root: root, tenant_id: source.tenant_id}
  end

  defp push(ctx, event) do
    raw = Jason.encode!(event)
    ts = Integer.to_string(System.os_time(:second))

    Events.receive_push(ctx.source.id, %{
      raw_body: raw,
      timestamp: ts,
      signature: Signature.header(ctx.secret, Signature.delivery_string(ts, raw))
    })
  end

  defp event(change_id, seq, attrs \\ %{}),
    do: build(:chg_event, Map.merge(%{change_id: change_id, event_seq: seq}, attrs))

  defp later(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp mine(candidates, tenant_id), do: Enum.filter(candidates, &(&1.tenant_id == tenant_id))

  defp reconcile_jobs(tenant_id) do
    worker = inspect(ChangeReconcileWorker)

    Loopctl.Repo.all(
      from j in Oban.Job,
        where: j.worker == ^worker and fragment("?->>'tenant_id' = ?", j.args, ^tenant_id)
    )
  end

  defp alert_jobs(change_id) do
    worker = inspect(ScaleAlertDeliveryWorker)

    Loopctl.Repo.all(
      from j in Oban.Job,
        where:
          j.worker == ^worker and
            fragment("?->'payload'->>'change_id' = ?", j.args, ^change_id)
    )
  end

  describe "gap_candidates/2" do
    test "a change with an event held ahead of a gap for over ten minutes", ctx do
      assert {:ok, %{outcome: :applied}} = push(ctx, event("C1", 1))
      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 3))

      assert mine(Reconcile.gap_candidates(later(9 * 60), 100), ctx.tenant_id) == []

      assert [%{repo: @repo, change_id: "C1"}] =
               mine(Reconcile.gap_candidates(later(11 * 60), 100), ctx.tenant_id)
    end

    test "a change with nothing held is not a candidate", ctx do
      assert {:ok, %{outcome: :applied}} = push(ctx, event("C1", 1))
      assert mine(Reconcile.gap_candidates(later(3_600), 100), ctx.tenant_id) == []
    end

    test "a change pulled within the interval is not asked again", ctx do
      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 2))

      AdminRepo.update_all(from(c in Cursor, where: c.tenant_id == ^ctx.tenant_id),
        set: [last_pulled_at: later(10 * 60)]
      )

      assert mine(Reconcile.gap_candidates(later(11 * 60), 100), ctx.tenant_id) == []
    end
  end

  describe "stale_candidates/2" do
    setup ctx do
      story = fixture(:story, %{tenant_id: ctx.tenant_id})

      assert {:ok, _} =
               push(ctx, event("C1", 1, %{kind: "submitted", data: %{"story_id" => story.id}}))

      %{story: story}
    end

    test "a bound change quiet for six hours, its story not terminal", ctx do
      assert mine(Reconcile.stale_candidates(later(5 * 3_600), 100), ctx.tenant_id) == []

      assert [%{change_id: "C1"}] =
               mine(Reconcile.stale_candidates(later(7 * 3_600), 100), ctx.tenant_id)
    end

    test "a story at a terminal stage is not pulled", ctx do
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, stage: :done})
      assert mine(Reconcile.stale_candidates(later(7 * 3_600), 100), ctx.tenant_id) == []
    end

    test "a non-terminal stage is pulled", ctx do
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, stage: :reviewing})

      assert [_] = mine(Reconcile.stale_candidates(later(7 * 3_600), 100), ctx.tenant_id)
    end

    test "an unbound change is not pulled for staleness", ctx do
      assert {:ok, _} = push(ctx, event("C2", 1))

      assert [%{change_id: "C1"}] =
               mine(Reconcile.stale_candidates(later(7 * 3_600), 100), ctx.tenant_id)
    end
  end

  describe "TC-47.3.4: gap reconciliation" do
    test "one reconciliation job; seq 2 fetched and both applied", ctx do
      assert {:ok, %{outcome: :applied}} = push(ctx, event("C1", 1))
      e3 = event("C1", 3)
      assert {:ok, %{outcome: :held}} = push(ctx, e3)
      e2 = event("C1", 2)
      secret = ctx.secret

      Oban.Testing.with_testing_mode(:manual, fn ->
        # Two sweeps see the same gap; the job is unique on the change.
        assert :ok = ChangeReconcileSweepWorker.sweep(later(11 * 60), @url)
        assert :ok = ChangeReconcileSweepWorker.sweep(later(12 * 60), @url)
        assert [%Oban.Job{args: args}] = reconcile_jobs(ctx.tenant_id)

        assert args == %{
                 "tenant_id" => ctx.tenant_id,
                 "repo" => @repo,
                 "change_id" => "C1",
                 "reason" => "gap"
               }

        expect(Loopctl.MockChgClient, :events_after, fn @url, ^secret, "C1", 1 ->
          {:ok, [e2, e3]}
        end)

        expect(Loopctl.MockChgClient, :events_after, fn @url, ^secret, "C1", 3 -> {:ok, []} end)

        assert %{success: 1} = Oban.drain_queue(queue: :default)
      end)

      assert [
               %Event{event_seq: 1, received_via: "push", applied_at: %DateTime{}},
               %Event{event_seq: 2, received_via: "pull", applied_at: %DateTime{}},
               %Event{event_seq: 3, received_via: "push", applied_at: %DateTime{}}
             ] = Events.list_events(ctx.tenant_id, @repo, "C1")

      assert %Cursor{applied_seq: 3, last_pulled_at: %DateTime{}} =
               Events.get_cursor(ctx.tenant_id, @repo, "C1")
    end

    test "with CHG_SERVER_URL unset the sweep enqueues nothing", ctx do
      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 2))

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = ChangeReconcileSweepWorker.sweep(later(11 * 60), nil)
        assert reconcile_jobs(ctx.tenant_id) == []
      end)
    end
  end

  describe "pull/4" do
    setup ctx do
      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 2))
      :ok
    end

    test "pages while the cursor advances, then stops", ctx do
      expect(Loopctl.MockChgClient, :events_after, fn _, _, "C1", 0 -> {:ok, [event("C1", 1)]} end)

      expect(Loopctl.MockChgClient, :events_after, fn _, _, "C1", 2 -> {:ok, [event("C1", 3)]} end)

      expect(Loopctl.MockChgClient, :events_after, fn _, _, "C1", 3 -> {:ok, []} end)

      assert {:ok, %{applied_seq: 3, pages: 3}} = Reconcile.pull(ctx.tenant_id, @repo, "C1")
    end

    test "an envelope about another change or repository is dropped", ctx do
      expect(Loopctl.MockChgClient, :events_after, fn _, _, "C1", 0 ->
        {:ok, [event("C9", 1), event("C1", 1, %{repo: "mkreyman/loopctl"}), %{"garbage" => true}]}
      end)

      assert {:ok, %{applied_seq: 0}} = Reconcile.pull(ctx.tenant_id, @repo, "C1")
      assert [%Event{event_seq: 2}] = Events.list_events(ctx.tenant_id, @repo, "C1")
      assert Events.list_events(ctx.tenant_id, @repo, "C9") == []
    end

    test "a pull refused for its signature raises an operator alert", ctx do
      expect(Loopctl.MockChgClient, :events_after, fn _, _, "C1", 0 -> {:error, :unauthorized} end)

      Oban.Testing.with_testing_mode(:manual, fn ->
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:error, :pull_unauthorized} = Reconcile.pull(ctx.tenant_id, @repo, "C1")
          end)

        assert log =~ "chg-server refused loopctl's signed gap pull"
        refute log =~ ctx.secret

        assert [%Oban.Job{args: %{"payload" => payload}}] = alert_jobs("C1")
        assert payload["alert"] == "changes.pull_unauthorized"
        assert payload["source_id"] == ctx.source.id
        assert payload["tenant_id"] == ctx.tenant_id
        refute inspect(payload) =~ ctx.secret
      end)

      # Stamped, so the next sweep does not ask again inside the interval.
      assert %Cursor{last_pulled_at: %DateTime{}} = Events.get_cursor(ctx.tenant_id, @repo, "C1")
    end

    test "the worker cancels on a final answer and retries a transient one", ctx do
      args = %{"tenant_id" => ctx.tenant_id, "repo" => @repo, "change_id" => "C1"}

      expect(Loopctl.MockChgClient, :events_after, fn _, _, _, _ -> {:error, :unauthorized} end)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:cancel, :pull_unauthorized} =
                 ChangeReconcileWorker.perform(%Oban.Job{args: args})
      end)

      expect(Loopctl.MockChgClient, :events_after, fn _, _, _, _ ->
        {:error, {:chg_server_error, 502}}
      end)

      assert {:error, {:chg_server_error, 502}} =
               ChangeReconcileWorker.perform(%Oban.Job{args: args})
    end

    test "unconfigured, it asks nothing", ctx do
      assert {:error, :chg_server_unconfigured} =
               Reconcile.pull(ctx.tenant_id, @repo, "C1", base_url: nil)
    end

    test "a revoked root refuses the pulled events too", ctx do
      {1, _} =
        AdminRepo.update_all(from(d in Dispatch, where: d.id == ^ctx.root.id),
          set: [revoked_at: DateTime.utc_now()]
        )

      expect(Loopctl.MockChgClient, :events_after, fn _, _, _, _ -> {:ok, [event("C1", 1)]} end)

      assert {:error, :source_refused} = Reconcile.pull(ctx.tenant_id, @repo, "C1")

      assert [%Event{event_seq: 2, applied_at: nil}] =
               Events.list_events(ctx.tenant_id, @repo, "C1")
    end

    test "tenant isolation: another tenant cannot pull this tenant's change", ctx do
      other = fixture(:tenant)
      assert {:error, :unknown_change} = Reconcile.pull(other.id, @repo, "C1")
      assert %Cursor{last_pulled_at: nil} = Events.get_cursor(ctx.tenant_id, @repo, "C1")
    end
  end
end
