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

  describe "mark_session_exhausted/2 (AC-44.6.4)" do
    test "holds a runner with no value for eight days" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)

      assert :ok = Usage.mark_session_exhausted(tenant.id, r.id)

      assert_in_delta seconds_from_now(row(r).usage_exhausted_until), @eight_days, 5
    end

    test "replaces an EARLIER stored reset with the bound" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)
      soon = DateTime.add(DateTime.utc_now(), 600, :second)
      assert :ok = Usage.record(tenant.id, r.id, %{exhausted: true, resets_at: soon})

      assert :ok = Usage.mark_session_exhausted(tenant.id, r.id)

      assert_in_delta seconds_from_now(row(r).usage_exhausted_until), @eight_days, 5
    end

    test "keeps a LATER stored reset" do
      tenant = fixture(:stage_tenant)
      r = runner(tenant.id)
      later = DateTime.add(DateTime.utc_now(), @eight_days + 3_600, :second)
      :ok = put_row(r, usage_exhausted_until: later)

      assert :ok = Usage.mark_session_exhausted(tenant.id, r.id)

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

      assert :ok = Usage.record(tenant.id, r1.id, %{exhausted: true, account_ref: "acct-a"})

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
      assert Usage.earliest_reset(tenant_a.id) == nil
      assert Usage.exhausted_until_by_runner(tenant_a.id) == %{}
    end

    test "a runner id that is not a UUID is not exhausted, and does not raise" do
      tenant = fixture(:stage_tenant)
      assert Usage.exhausted_until(tenant.id, "not-a-uuid") == nil
    end
  end

  describe "exhausted_until_by_runner/1 and earliest_reset/1 (AC-44.6.8)" do
    test "maps each exhausted active runner to its effective reset; the earliest is the min" do
      tenant = fixture(:stage_tenant)
      [r1, r2, r3, idle] = for _ <- 1..4, do: runner(tenant.id)

      soon = DateTime.add(DateTime.utc_now(), 600, :second)
      later = DateTime.add(DateTime.utc_now(), 7_200, :second)

      assert :ok = Usage.record(tenant.id, r2.id, %{exhausted: false, account_ref: "acct-a"})

      assert :ok =
               Usage.record(tenant.id, r1.id, %{
                 exhausted: true,
                 resets_at: later,
                 account_ref: "acct-a"
               })

      assert :ok = Usage.record(tenant.id, r3.id, %{exhausted: true, resets_at: soon})

      by_runner = Usage.exhausted_until_by_runner(tenant.id)

      assert Map.keys(by_runner) |> Enum.sort() == Enum.sort([r1.id, r2.id, r3.id])
      assert DateTime.compare(by_runner[r2.id], later) == :eq
      refute Map.has_key?(by_runner, idle.id)

      assert DateTime.compare(Usage.earliest_reset(tenant.id), soon) == :eq

      # A revoked runner is not in the pool, so it is not reported — though its value still
      # holds its peers out (above).
      :ok = put_row(r3, revoked_at: DateTime.utc_now())
      refute Map.has_key?(Usage.exhausted_until_by_runner(tenant.id), r3.id)
      assert DateTime.compare(Usage.earliest_reset(tenant.id), later) == :eq
    end

    test "nil when nothing in the tenant is exhausted" do
      tenant = fixture(:stage_tenant)
      runner(tenant.id)

      assert Usage.earliest_reset(tenant.id) == nil
    end
  end
end
