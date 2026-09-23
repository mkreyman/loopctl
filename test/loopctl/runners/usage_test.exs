defmodule Loopctl.Runners.UsageTest do
  @moduledoc """
  US-44.6: `Loopctl.Runners.Usage` — the subscription window a runner declares, stored on its
  `runners` row, and read account-wide by every placement path.

  Async on the RLS `Loopctl.Repo` sandbox, which is where every read and write here runs; the
  runners are `fixture(:stage_runner)` rows on that same connection. The channel and placement
  wiring, which span both repos, are in `LoopctlWeb.RunnerChannelUsageTest`,
  `Loopctl.Delivery.DispatchDriverTest` and `Loopctl.Delivery.SessionEndReleaseTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.Repo
  alias Loopctl.Runners
  alias Loopctl.Runners.Runner
  alias Loopctl.Runners.Usage

  setup :verify_on_exit!

  @eight_days 8 * 24 * 60 * 60

  defp runner(tenant_id), do: fixture(:stage_runner, %{tenant_id: tenant_id})

  defp row(runner) do
    {:ok, row} = Repo.with_tenant(runner.tenant_id, fn -> Repo.get!(Runner, runner.id) end)
    row
  end

  # A value written straight to the row, for a state no public writer produces on demand — a
  # reset already in the PAST, or a peer revoked while exhausted.
  defp put_row(runner, changes) do
    {:ok, {1, _}} =
      Repo.with_tenant(runner.tenant_id, fn ->
        Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: changes)
      end)

    :ok
  end

  defp seconds_from_now(%DateTime{} = at), do: DateTime.diff(at, DateTime.utc_now(), :second)

  # The SQL this process sent while `fun` ran — for a write that changes no row's value, and so
  # can only be seen by whether it was issued at all.
  defp queries_during(fun) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, [:loopctl, :repo, :query], &__MODULE__.collect_query/4, self())

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    collect_queries([])
  end

  @doc false
  def collect_query(_event, _measurements, %{query: query}, pid) do
    if self() == pid, do: send(pid, {:query_seen, query})
  end

  defp collect_queries(acc) do
    receive do
      {:query_seen, query} -> collect_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "clamp/2 (AC-44.6.2, AC-44.6.3)" do
    @now ~U[2026-09-23 12:00:00.000000Z]

    test "a reset inside the window is kept as sent" do
      at = DateTime.add(@now, 3_600, :second)
      assert Usage.clamp(at, @now) == at
    end

    test "a reset past eight days is held at eight days" do
      assert Usage.clamp(DateTime.add(@now, 30 * 86_400, :second), @now) ==
               DateTime.add(@now, @eight_days, :second)
    end

    test "a reset under a minute out, or already past, is held at one minute" do
      floor = DateTime.add(@now, 60, :second)

      assert Usage.clamp(DateTime.add(@now, 5, :second), @now) == floor
      # A runner whose clock runs behind control's: the reset it sends is already past, and a
      # declared exhaustion is never a no-op.
      assert Usage.clamp(DateTime.add(@now, -3_600, :second), @now) == floor
    end

    test "no reset at all is the upper bound, never ignored" do
      assert Usage.clamp(nil, @now) == DateTime.add(@now, @eight_days, :second)
    end
  end

  describe "record/3 with exhausted: true (AC-44.6.2, AC-44.6.3)" do
    test "stores the clamped reset and the account on the runner's own row" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)

      resets_at = DateTime.add(DateTime.utc_now(), 7_200, :second)

      assert :ok =
               Usage.record(tenant.id, r.id, %{
                 exhausted: true,
                 resets_at: resets_at,
                 account_ref: "acct-a"
               })

      stored = row(r)
      assert DateTime.compare(stored.usage_exhausted_until, resets_at) == :eq
      assert stored.account_ref == "acct-a"
    end

    test "a far reset is clamped to eight days" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)

      far = DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: true, resets_at: far})

      assert_in_delta seconds_from_now(row(r).usage_exhausted_until), @eight_days, 5
    end

    test "no reset holds for eight days" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)

      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: true})

      assert_in_delta seconds_from_now(row(r).usage_exhausted_until), @eight_days, 5
    end

    test "SETS rather than keeping the later value, so a real reset corrects the bound" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)

      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: true})
      soon = DateTime.add(DateTime.utc_now(), 600, :second)
      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: true, resets_at: soon})

      assert DateTime.compare(row(r).usage_exhausted_until, soon) == :eq
    end

    test "WITH an account, sets every same-tenant row of that account — a stale peer hold " <>
           "included — and no other" do
      tenant = fixture(:stage_tenant)
      [r1, r2, other] = for _ <- 1..3, do: runner(tenant.id)
      soon = DateTime.add(DateTime.utc_now(), 600, :second)

      assert :ok = Usage.record(tenant.id, r2.id, %{exhausted: false, account_ref: "acct-a"})
      assert :ok = Usage.record(tenant.id, other.id, %{exhausted: false, account_ref: "acct-b"})
      # r2's session ran dry and held it for the eight-day bound.
      assert :ok = Usage.mark_session_exhausted(tenant.id, r2.id, nil)

      # r1 reports the real reset for the account. Correcting only r1's row left r2's 8-day
      # hold standing, and the effective value is the LATEST across the account.
      assert :ok =
               Usage.record(tenant.id, r1.id, %{
                 exhausted: true,
                 resets_at: soon,
                 account_ref: "acct-a"
               })

      assert DateTime.compare(row(r2).usage_exhausted_until, soon) == :eq
      assert DateTime.compare(Usage.exhausted_until(tenant.id, r2.id), soon) == :eq
      assert row(other).usage_exhausted_until == nil
    end

    test "an unchanged account_ref is not rewritten" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)
      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: false, account_ref: "acct-a"})

      sent =
        queries_during(fn ->
          assert :ok = Usage.record(tenant.id, r.id, %{exhausted: true, account_ref: "acct-a"})
          assert :ok = Usage.record(tenant.id, r.id, %{exhausted: false, account_ref: "acct-a"})
        end)

      refute Enum.any?(sent, &(&1 =~ ~r/ SET (?:(?! WHERE ).)*"account_ref" = /))
      assert row(r).account_ref == "acct-a"
    end

    test "an omitted account_ref keeps the one sent before" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)

      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: false, account_ref: "acct-a"})
      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: true})

      assert row(r).account_ref == "acct-a"
    end
  end

  describe "record/3 with exhausted: false (AC-44.6.7)" do
    test "clears every runner in the tenant sharing the account, and only those" do
      tenant = fixture(:stage_tenant)
      [r1, r2, other] = for _ <- 1..3, do: runner(tenant.id)

      assert :ok = Usage.record(tenant.id, r1.id, %{exhausted: true, account_ref: "acct-a"})
      assert :ok = Usage.record(tenant.id, r2.id, %{exhausted: true, account_ref: "acct-a"})
      assert :ok = Usage.record(tenant.id, other.id, %{exhausted: true, account_ref: "acct-b"})

      assert :ok = Usage.record(tenant.id, r2.id, %{exhausted: false, account_ref: "acct-a"})

      assert row(r1).usage_exhausted_until == nil
      assert row(r2).usage_exhausted_until == nil
      assert %DateTime{} = row(other).usage_exhausted_until
    end

    test "touches only the rows that hold a value, and stamps each one it clears" do
      tenant = fixture(:stage_tenant)
      [r1, r2] = for _ <- 1..2, do: runner(tenant.id)

      assert :ok = Usage.record(tenant.id, r2.id, %{exhausted: false, account_ref: "acct-a"})
      assert :ok = Usage.record(tenant.id, r1.id, %{exhausted: false, account_ref: "acct-a"})
      # Nothing was exhausted, so nothing was cleared: no status rewrites the whole account.
      assert row(r1).usage_cleared_at == nil
      assert row(r2).usage_cleared_at == nil

      :ok = put_row(r2, usage_exhausted_until: DateTime.add(DateTime.utc_now(), 600, :second))
      assert :ok = Usage.record(tenant.id, r1.id, %{exhausted: false})

      assert row(r2).usage_exhausted_until == nil
      assert %DateTime{} = row(r2).usage_cleared_at
      assert row(r1).usage_cleared_at == nil
    end

    test "with no account_ref sent, clears by the account the runner sent before" do
      tenant = fixture(:stage_tenant)
      [r1, r2] = for _ <- 1..2, do: runner(tenant.id)

      assert :ok = Usage.record(tenant.id, r1.id, %{exhausted: true, account_ref: "acct-a"})
      assert :ok = Usage.record(tenant.id, r2.id, %{exhausted: true, account_ref: "acct-a"})

      assert :ok = Usage.record(tenant.id, r2.id, %{exhausted: false})

      assert row(r1).usage_exhausted_until == nil
      assert row(r2).usage_exhausted_until == nil
    end

    test "a runner with no account clears its own row alone" do
      tenant = fixture(:stage_tenant)
      [r1, r2] = for _ <- 1..2, do: runner(tenant.id)

      assert :ok = Usage.record(tenant.id, r1.id, %{exhausted: true})
      assert :ok = Usage.record(tenant.id, r2.id, %{exhausted: true})

      assert :ok = Usage.record(tenant.id, r1.id, %{exhausted: false})

      assert row(r1).usage_exhausted_until == nil
      assert %DateTime{} = row(r2).usage_exhausted_until
    end

    test "a runner switching account hands its hold to the machines left on the old one" do
      tenant = fixture(:stage_tenant)
      [r1, r2, r3] = for _ <- 1..3, do: runner(tenant.id)
      later = DateTime.add(DateTime.utc_now(), @eight_days + 3_600, :second)

      for r <- [r1, r2, r3],
          do: assert(:ok = Usage.record(tenant.id, r.id, %{exhausted: false, account_ref: "a"}))

      # r1's session ran dry: its row alone holds account a out. r3 holds a LATER value.
      assert :ok = Usage.mark_session_exhausted(tenant.id, r1.id, nil)
      hold = row(r1).usage_exhausted_until
      :ok = put_row(r3, usage_exhausted_until: later)

      # r1 moves to a login that is fine. Account a is still dry.
      assert :ok = Usage.record(tenant.id, r1.id, %{exhausted: false, account_ref: "b"})

      assert row(r1).account_ref == "b"
      assert row(r1).usage_exhausted_until == nil
      assert DateTime.compare(row(r2).usage_exhausted_until, hold) == :eq
      assert DateTime.compare(row(r3).usage_exhausted_until, later) == :eq
    end

    test "a switch hands over nothing when the hold is already past" do
      tenant = fixture(:stage_tenant)
      [r1, r2] = for _ <- 1..2, do: runner(tenant.id)

      for r <- [r1, r2],
          do: assert(:ok = Usage.record(tenant.id, r.id, %{exhausted: false, account_ref: "a"}))

      :ok = put_row(r1, usage_exhausted_until: DateTime.add(DateTime.utc_now(), -60, :second))
      assert :ok = Usage.record(tenant.id, r1.id, %{exhausted: true, account_ref: "b"})

      assert row(r2).usage_exhausted_until == nil
    end

    test "never reaches another tenant's runner on the same account (tenant isolation)" do
      tenant_a = fixture(:stage_tenant)
      tenant_b = fixture(:stage_tenant)
      a = runner(tenant_a.id)
      b = runner(tenant_b.id)

      assert :ok = Usage.record(tenant_b.id, b.id, %{exhausted: true, account_ref: "acct-a"})
      assert :ok = Usage.record(tenant_a.id, a.id, %{exhausted: false, account_ref: "acct-a"})

      assert %DateTime{} = row(b).usage_exhausted_until
    end
  end

  describe "mark_session_exhausted/3 (AC-44.6.4)" do
    test "holds a runner with no value for eight days" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)

      assert :ok = Usage.mark_session_exhausted(tenant.id, r.id, nil)

      assert_in_delta seconds_from_now(row(r).usage_exhausted_until), @eight_days, 5
    end

    test "replaces an EARLIER stored reset with the bound" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)
      soon = DateTime.add(DateTime.utc_now(), 600, :second)
      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: true, resets_at: soon})

      assert :ok = Usage.mark_session_exhausted(tenant.id, r.id, nil)

      assert_in_delta seconds_from_now(row(r).usage_exhausted_until), @eight_days, 5
    end

    test "skips an account cleared AFTER the session's dispatch was accepted" do
      tenant = fixture(:stage_tenant)
      [r1, r2] = for _ <- 1..2, do: runner(tenant.id)
      accepted_at = DateTime.add(DateTime.utc_now(), -60, :second)

      for r <- [r1, r2],
          do: assert(:ok = Usage.record(tenant.id, r.id, %{exhausted: false, account_ref: "a"}))

      # Only the PEER held a value, so only the peer's row is cleared and stamped: the skip
      # has to come from the account, not from r1's own row.
      :ok = put_row(r2, usage_exhausted_until: DateTime.add(DateTime.utc_now(), 600, :second))
      assert :ok = Usage.record(tenant.id, r2.id, %{exhausted: false})
      assert row(r1).usage_cleared_at == nil

      assert :ok = Usage.mark_session_exhausted(tenant.id, r1.id, accepted_at)

      assert row(r1).usage_exhausted_until == nil
    end

    test "skips a runner with no account whose own row was cleared after acceptance" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)
      accepted_at = DateTime.add(DateTime.utc_now(), -60, :second)

      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: true})
      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: false})

      assert :ok = Usage.mark_session_exhausted(tenant.id, r.id, accepted_at)

      assert row(r).usage_exhausted_until == nil
    end

    test "marks when the clear came BEFORE the dispatch was accepted" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)

      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: true})
      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: false})
      accepted_at = DateTime.add(DateTime.utc_now(), 1, :second)

      assert :ok = Usage.mark_session_exhausted(tenant.id, r.id, accepted_at)

      assert_in_delta seconds_from_now(row(r).usage_exhausted_until), @eight_days, 5
    end

    test "keeps a LATER stored reset" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)
      later = DateTime.add(DateTime.utc_now(), @eight_days + 3_600, :second)
      :ok = put_row(r, usage_exhausted_until: later)

      assert :ok = Usage.mark_session_exhausted(tenant.id, r.id, nil)

      assert DateTime.compare(row(r).usage_exhausted_until, later) == :eq
    end
  end

  describe "exhausted_until/2 and Runners.usage_exhausted?/2 (AC-44.6.5)" do
    test "a runner that never reported is not exhausted" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)

      assert Usage.exhausted_until(tenant.id, r.id) == nil
      refute Runners.usage_exhausted?(tenant.id, r.id)
    end

    test "its own future value exhausts it, and a past one does not" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)

      :ok = put_row(r, usage_exhausted_until: DateTime.add(DateTime.utc_now(), -1, :second))
      assert Usage.exhausted_until(tenant.id, r.id) == nil

      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: true})
      assert %DateTime{} = Usage.exhausted_until(tenant.id, r.id)
      assert Runners.usage_exhausted?(tenant.id, r.id)
    end

    test "a same-account peer's value exhausts it — a revoked peer's too" do
      tenant = fixture(:stage_tenant)
      [r1, r2, stranger] = for _ <- 1..3, do: runner(tenant.id)

      assert :ok = Usage.record(tenant.id, r2.id, %{exhausted: false, account_ref: "acct-a"})

      assert :ok =
               Usage.record(tenant.id, stranger.id, %{exhausted: false, account_ref: "acct-z"})

      assert :ok = Usage.record(tenant.id, r1.id, %{exhausted: false, account_ref: "acct-a"})
      # Straight onto r1's row: `record/3` would set r2's own row too, and this is about the
      # READ joining a peer's value.
      :ok = put_row(r1, usage_exhausted_until: DateTime.add(DateTime.utc_now(), 600, :second))

      assert DateTime.compare(
               Usage.exhausted_until(tenant.id, r2.id),
               row(r1).usage_exhausted_until
             ) == :eq

      assert Usage.exhausted_until(tenant.id, stranger.id) == nil

      # Revoking the machine that ran dry does not refill the account it drew on.
      :ok = put_row(r1, revoked_at: DateTime.utc_now())
      assert Runners.usage_exhausted?(tenant.id, r2.id)
    end

    test "an unshared runner is not exhausted by another runner's value" do
      tenant = fixture(:stage_tenant)
      [r1, r2] = for _ <- 1..2, do: runner(tenant.id)

      # Neither sent an account: two NULLs are not one account.
      assert :ok = Usage.record(tenant.id, r1.id, %{exhausted: true})
      assert Usage.exhausted_until(tenant.id, r2.id) == nil
    end

    test "another tenant's exhausted runner on the same account_ref does not count (TC-44.6.8)" do
      tenant_a = fixture(:stage_tenant)
      tenant_b = fixture(:stage_tenant)
      a = runner(tenant_a.id)
      b = runner(tenant_b.id)

      assert :ok = Usage.record(tenant_a.id, a.id, %{exhausted: false, account_ref: "acct-a"})
      assert :ok = Usage.record(tenant_b.id, b.id, %{exhausted: true, account_ref: "acct-a"})

      assert Usage.exhausted_until(tenant_a.id, a.id) == nil
      assert Usage.exhausted_until_by_runner(tenant_a.id) == %{}
    end

    test "a runner id that is not a UUID is not exhausted, and does not raise" do
      tenant = fixture(:stage_tenant)
      assert Usage.exhausted_until(tenant.id, "not-a-uuid") == nil
    end
  end

  describe "exhausted_until_by_runner/1 (AC-44.6.8)" do
    test "maps each exhausted active runner to its effective reset" do
      tenant = fixture(:stage_tenant)
      [r1, r2, r3, idle] = for _ <- 1..4, do: runner(tenant.id)

      soon = DateTime.add(DateTime.utc_now(), 600, :second)
      later = DateTime.add(DateTime.utc_now(), 7_200, :second)

      assert :ok = Usage.record(tenant.id, r2.id, %{exhausted: false, account_ref: "acct-a"})

      assert :ok = Usage.record(tenant.id, r1.id, %{exhausted: false, account_ref: "acct-a"})
      :ok = put_row(r1, usage_exhausted_until: later)

      assert :ok = Usage.record(tenant.id, r3.id, %{exhausted: true, resets_at: soon})

      by_runner = Usage.exhausted_until_by_runner(tenant.id)

      assert Map.keys(by_runner) |> Enum.sort() == Enum.sort([r1.id, r2.id, r3.id])
      assert DateTime.compare(by_runner[r2.id], later) == :eq
      assert DateTime.compare(by_runner[r3.id], soon) == :eq
      refute Map.has_key?(by_runner, idle.id)

      # A revoked runner is not in the pool, so it is not reported — though its value still
      # holds its peers out (above).
      :ok = put_row(r3, revoked_at: DateTime.utc_now())
      refute Map.has_key?(Usage.exhausted_until_by_runner(tenant.id), r3.id)
    end

    test "empty when nothing in the tenant is exhausted" do
      tenant = fixture(:stage_tenant)
      runner(tenant.id)

      assert Usage.exhausted_until_by_runner(tenant.id) == %{}
    end
  end

  describe "exhausted_for_pass/2" do
    test "reads the tenant once per pass: a later call answers from the cache" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)

      {first, cache} = Usage.exhausted_for_pass(%{}, tenant.id)
      assert first == %{}

      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: true})

      assert {^first, ^cache} = Usage.exhausted_for_pass(cache, tenant.id)
      assert {%{} = fresh, _cache} = Usage.exhausted_for_pass(%{}, tenant.id)
      assert Map.has_key?(fresh, r.id)
    end
  end

  describe "note_no_runner/4 (AC-44.6.8)" do
    setup do
      Logger.put_module_level(Usage, :info)
      on_exit(fn -> Logger.delete_module_level(Usage) end)
      :ok
    end

    test "logs the earliest reset of the runners refused for exhaustion, once per tenant" do
      candidate = %{tenant_id: Ecto.UUID.generate(), story_id: Ecto.UUID.generate()}
      soon = DateTime.add(DateTime.utc_now(), 600, :second)
      later = DateTime.add(soon, 3_600, :second)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          cache = Usage.note_no_runner(%{}, "Pass", candidate, [later, soon])
          assert Usage.note_no_runner(cache, "Pass", candidate, [later]) == cache
        end)

      assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "earliest_usage_reset="))
      assert line =~ "Pass: "
      assert line =~ "earliest_usage_reset=#{DateTime.to_iso8601(soon)}:"
    end

    test "logs nothing, and notes nothing, when no runner was refused for exhaustion" do
      candidate = %{tenant_id: Ecto.UUID.generate(), story_id: Ecto.UUID.generate()}

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert Usage.note_no_runner(%{}, "Pass", candidate, []) == %{}
        end)

      refute log =~ "earliest_usage_reset"
    end
  end
end
