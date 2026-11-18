defmodule Loopctl.Changes.ReconcileTest do
  @moduledoc """
  US-47.3 AC-47.3.3, reworked by US-50.2: gap and staleness detection — the candidate reads,
  and the sweep that flags each change for the operator once instead of pulling it.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Cursor
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.Reconcile
  alias Loopctl.Changes.Signature
  alias Loopctl.Workers.ChangeReconcileSweepWorker
  alias Loopctl.Workers.ScaleAlertDeliveryWorker

  @repo "mkreyman/infra"

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

  defp alert_jobs(change_id) do
    worker = inspect(ScaleAlertDeliveryWorker)

    Loopctl.Repo.all(
      from j in Oban.Job,
        where:
          j.worker == ^worker and
            fragment("?->'payload'->>'change_id' = ?", j.args, ^change_id)
    )
  end

  defp candidate(ctx, change_id),
    do: %{tenant_id: ctx.tenant_id, repo: @repo, change_id: change_id}

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

    test "a change already flagged gap is not a candidate again", ctx do
      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 2))

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :flagged = Reconcile.flag(candidate(ctx, "C1"), :gap, later(11 * 60))
      end)

      assert mine(Reconcile.gap_candidates(later(60 * 60), 100), ctx.tenant_id) == []
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

    test "a story at a terminal stage is not flagged", ctx do
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, stage: :done})
      assert mine(Reconcile.stale_candidates(later(7 * 3_600), 100), ctx.tenant_id) == []
    end

    test "a non-terminal stage is flagged", ctx do
      fixture(:story_stage, %{tenant_id: ctx.tenant_id, story_id: ctx.story.id, stage: :reviewing})

      assert [_] = mine(Reconcile.stale_candidates(later(7 * 3_600), 100), ctx.tenant_id)
    end

    test "an unbound change is not flagged for staleness", ctx do
      assert {:ok, _} = push(ctx, event("C2", 1))

      assert [%{change_id: "C1"}] =
               mine(Reconcile.stale_candidates(later(7 * 3_600), 100), ctx.tenant_id)
    end

    test "a change flagged for anything is not a stale candidate", ctx do
      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 3))

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :flagged = Reconcile.flag(candidate(ctx, "C1"), :gap, later(11 * 60))
      end)

      assert mine(Reconcile.stale_candidates(later(7 * 3_600), 100), ctx.tenant_id) == []
    end
  end

  describe "flag/3 re-judges the condition in its own write" do
    test "a gap filled after the candidate read is not flagged", ctx do
      assert {:ok, %{outcome: :applied}} = push(ctx, event("C1", 1))
      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 3))
      now = later(11 * 60)
      assert [_] = mine(Reconcile.gap_candidates(now, 100), ctx.tenant_id)

      assert {:ok, _} = push(ctx, event("C1", 2))

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :unchanged = Reconcile.flag(candidate(ctx, "C1"), :gap, now)
        assert alert_jobs("C1") == []
      end)

      assert %Cursor{attention: nil} = Events.get_cursor(ctx.tenant_id, @repo, "C1")
    end

    test "an event that ended the quiet after the candidate read is not flagged stale", ctx do
      story = fixture(:story, %{tenant_id: ctx.tenant_id})

      assert {:ok, _} =
               push(ctx, event("C1", 1, %{kind: "submitted", data: %{"story_id" => story.id}}))

      now = later(7 * 3_600)
      assert [_] = mine(Reconcile.stale_candidates(now, 100), ctx.tenant_id)

      # An arrival at `now`, as `touch_cursor` writes it.
      {1, _} =
        AdminRepo.update_all(
          from(c in Cursor, where: c.tenant_id == ^ctx.tenant_id and c.change_id == "C1"),
          set: [last_event_at: now]
        )

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :unchanged = Reconcile.flag(candidate(ctx, "C1"), :stale, now)
        assert alert_jobs("C1") == []
      end)
    end
  end

  describe "TC-50.2.3: a gap alerts once and pulls nothing" do
    test "two sweeps flag the change once and raise one alert", ctx do
      assert {:ok, %{outcome: :applied}} = push(ctx, event("C1", 1))
      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 3))

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = ChangeReconcileSweepWorker.sweep(later(11 * 60))
        assert :ok = ChangeReconcileSweepWorker.sweep(later(12 * 60))

        assert [%Oban.Job{args: %{"payload" => payload}}] = alert_jobs("C1")
        assert payload["alert"] == "changes.gap"
        assert payload["tenant_id"] == ctx.tenant_id
        assert payload["change_id"] == "C1"

        # The operator plane carries ids, never tenant content or the secret.
        refute inspect(payload) =~ @repo
        refute inspect(payload) =~ ctx.secret
      end)

      assert %Cursor{attention: "gap", attention_at: %DateTime{}, applied_seq: 1} =
               Events.get_cursor(ctx.tenant_id, @repo, "C1")
    end

    test "a change both gapped and stale is flagged gap only", ctx do
      story = fixture(:story, %{tenant_id: ctx.tenant_id})

      assert {:ok, _} =
               push(ctx, event("C1", 1, %{kind: "submitted", data: %{"story_id" => story.id}}))

      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 3))

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok = ChangeReconcileSweepWorker.sweep(later(7 * 3_600))
        assert [%Oban.Job{args: %{"payload" => %{"alert" => "changes.gap"}}}] = alert_jobs("C1")
      end)
    end
  end

  describe "TC-50.2.4: an applied event clears the flag" do
    test "filling the gap clears gap", ctx do
      assert {:ok, %{outcome: :applied}} = push(ctx, event("C1", 1))
      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 3))

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :flagged = Reconcile.flag(candidate(ctx, "C1"), :gap, later(11 * 60))
      end)

      assert {:ok, %{outcome: :applied, cursor: %{applied_through: 3, held: []}}} =
               push(ctx, event("C1", 2))

      assert %Cursor{attention: nil, attention_at: nil} =
               Events.get_cursor(ctx.tenant_id, @repo, "C1")
    end

    test "a partial fill keeps gap while something is still held", ctx do
      assert {:ok, %{outcome: :applied}} = push(ctx, event("C1", 1))
      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 3))
      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 5))

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :flagged = Reconcile.flag(candidate(ctx, "C1"), :gap, later(11 * 60))
      end)

      assert {:ok, %{cursor: %{applied_through: 3, held: [5]}}} = push(ctx, event("C1", 2))
      assert %Cursor{attention: "gap"} = Events.get_cursor(ctx.tenant_id, @repo, "C1")
    end

    test "any arrival clears stale, and the change can alert again later", ctx do
      assert {:ok, _} = push(ctx, event("C1", 1))

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :flagged = Reconcile.flag(candidate(ctx, "C1"), :stale, later(7 * 3_600))
        assert :unchanged = Reconcile.flag(candidate(ctx, "C1"), :stale, later(7 * 3_600))
      end)

      assert {:ok, _} = push(ctx, event("C1", 2))
      assert %Cursor{attention: nil} = Events.get_cursor(ctx.tenant_id, @repo, "C1")

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :flagged = Reconcile.flag(candidate(ctx, "C1"), :stale, later(7 * 3_600))
        assert length(alert_jobs("C1")) == 2
      end)
    end
  end

  describe "flag/3 tenant isolation" do
    test "another tenant's candidate for the same change flags nothing here", ctx do
      assert {:ok, %{outcome: :held}} = push(ctx, event("C1", 2))
      other = fixture(:tenant)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :unchanged =
                 Reconcile.flag(%{candidate(ctx, "C1") | tenant_id: other.id}, :gap, later(660))
      end)

      assert [%Cursor{attention: nil}] =
               AdminRepo.all(from(c in Cursor, where: c.tenant_id == ^ctx.tenant_id))
    end
  end
end
