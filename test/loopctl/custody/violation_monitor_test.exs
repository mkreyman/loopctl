defmodule Loopctl.Custody.ViolationMonitorTest do
  @moduledoc """
  L6 halt escalation: a custody halt must require EVIDENCE OF A PATTERN.

  A halt suspends the tenant's custody surface until a human WebAuthn break-glass
  ceremony clears it, so a single event arming it turns any ordinary protocol
  error into a tenant-wide outage. These tests pin the threshold, the window, the
  tenant scoping of the counter, and the alerting an operator depends on.

  The window is driven through the `:clock` DI seam (`Loopctl.MockClock`) — no
  sleeping, no VM-global mutation.

  Async: every path runs on `Loopctl.AdminRepo`, sharing the sandbox connection
  the fixtures insert through.
  """
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog

  alias Loopctl.AuditChain
  alias Loopctl.Custody.ViolationMonitor
  alias Loopctl.Tenants

  setup :verify_on_exit!

  defp halted?(tenant_id) do
    {:ok, tenant} = Tenants.get_tenant(tenant_id)
    Tenants.custody_halted?(tenant)
  end

  defp pin_clock(at) do
    Mox.stub(Loopctl.MockClock, :utc_now, fn -> at end)
  end

  describe "threshold — a single violation must not halt a tenant" do
    test "the first violation is recorded and the tenant stays up" do
      tenant = fixture(:tenant)

      assert {:ok, :recorded, 1} =
               ViolationMonitor.record(tenant.id, "self_report_blocked")

      refute halted?(tenant.id)
    end

    test "violations below the threshold never halt" do
      tenant = fixture(:tenant)

      for n <- 1..(ViolationMonitor.threshold() - 1) do
        assert {:ok, :recorded, ^n} =
                 ViolationMonitor.record(tenant.id, "self_verify_blocked")

        refute halted?(tenant.id)
      end
    end

    test "reaching the threshold inside the window halts the tenant" do
      tenant = fixture(:tenant)
      threshold = ViolationMonitor.threshold()

      for _ <- 1..(threshold - 1) do
        ViolationMonitor.record(tenant.id, "self_verify_blocked")
      end

      refute halted?(tenant.id)

      assert {:ok, :halted, ^threshold} =
               ViolationMonitor.record(tenant.id, "self_verify_blocked")

      assert halted?(tenant.id)
    end

    test "a halt has ONE onset — a later pattern does not refresh halted_at" do
      tenant = fixture(:tenant)
      threshold = ViolationMonitor.threshold()

      for _ <- 1..threshold do
        ViolationMonitor.record(tenant.id, "self_report_blocked")
      end

      {:ok, halted} = Tenants.get_tenant(tenant.id)
      first_onset = halted.custody_halted_at

      # The evidence that armed the halt was claimed, so the counter restarts —
      # and a whole second pattern still cannot move the onset.
      outcomes =
        for _ <- 1..threshold, do: ViolationMonitor.record(tenant.id, "self_report_blocked")

      assert {:ok, :already_halted, _count} = List.last(outcomes)

      {:ok, still_halted} = Tenants.get_tenant(tenant.id)
      assert still_halted.custody_halted_at == first_onset
    end

    test "the third self-* gate counts too — self_review_blocked is not invisible" do
      tenant = fixture(:tenant)
      threshold = ViolationMonitor.threshold()

      for _ <- 1..(threshold - 1) do
        assert {:ok, :recorded, _} = ViolationMonitor.record(tenant.id, "self_review_blocked")
      end

      assert {:ok, :halted, ^threshold} =
               ViolationMonitor.record(tenant.id, "self_review_blocked")
    end
  end

  describe "recovery — the break-glass ceremony must actually clear the tenant" do
    test "one violation after a human clears the halt does not instantly re-halt" do
      tenant = fixture(:tenant)

      for _ <- 1..ViolationMonitor.threshold() do
        ViolationMonitor.record(tenant.id, "self_report_blocked")
      end

      assert halted?(tenant.id)
      {:ok, _} = Tenants.clear_custody_halt(tenant.id)

      # Same window, so a time-only counter would still hold the original rows and
      # re-halt on this one event — making the hardware-anchored ceremony buy
      # minutes of uptime.
      assert {:ok, :recorded, 1} = ViolationMonitor.record(tenant.id, "self_verify_blocked")
      refute halted?(tenant.id)
    end

    test "violations that land BEHIND an active halt cannot re-trip it after the clear" do
      tenant = fixture(:tenant)

      for _ <- 1..ViolationMonitor.threshold() do
        ViolationMonitor.record(tenant.id, "self_report_blocked")
      end

      assert halted?(tenant.id)

      # Requests already past CheckCustodyHalt when the halt armed still reach the
      # gate and record. Left unclaimed they survive the ceremony, and the very
      # next violation re-halts — the failure the claim exists to close.
      for _ <- 1..ViolationMonitor.threshold() do
        assert {:ok, :already_halted, _} =
                 ViolationMonitor.record(tenant.id, "self_verify_blocked")
      end

      assert ViolationMonitor.count_in_window(tenant.id) == 0
      {:ok, _} = Tenants.clear_custody_halt(tenant.id)

      assert {:ok, :recorded, 1} = ViolationMonitor.record(tenant.id, "self_report_blocked")
      refute halted?(tenant.id)
    end

    test "a fresh pattern after the clear halts again" do
      tenant = fixture(:tenant)
      threshold = ViolationMonitor.threshold()

      for _ <- 1..threshold, do: ViolationMonitor.record(tenant.id, "self_report_blocked")
      {:ok, _} = Tenants.clear_custody_halt(tenant.id)

      for _ <- 1..(threshold - 1), do: ViolationMonitor.record(tenant.id, "self_report_blocked")
      refute halted?(tenant.id)

      assert {:ok, :halted, ^threshold} =
               ViolationMonitor.record(tenant.id, "self_report_blocked")
    end
  end

  describe "config validation — the catastrophic values are inside the naive range" do
    test "0 (what an operator types meaning 'off') is refused, not honoured" do
      log =
        capture_log(fn ->
          assert ViolationMonitor.validate_positive_integer(0, 3, :custody_halt_threshold) == 3
        end)

      assert log =~ "custody_halt_config_invalid"
    end

    test "a non-integer is refused — it would silently disable L6 forever" do
      # `count < "3"` is ALWAYS true in Erlang term order, so a String threshold
      # (the shape System.get_env/1 returns) halts nobody, ever, with no error.
      for bad <- ["3", nil, 3.5, -1] do
        assert capture_log(fn ->
                 assert ViolationMonitor.validate_positive_integer(
                          bad,
                          7,
                          :custody_halt_window_seconds
                        ) ==
                          7
               end) =~ "custody_halt_config_invalid"
      end
    end

    test "a valid positive integer passes through untouched and logs nothing" do
      assert capture_log(fn ->
               assert ViolationMonitor.validate_positive_integer(5, 3, :custody_halt_threshold) ==
                        5
             end) == ""
    end

    test "an invalid value warns ONCE per process, not once per read" do
      # The knobs are read half a dozen times per recorded violation; an
      # unconditional warning floods the log at a multiple of the violation rate.
      log =
        capture_log(fn ->
          for _ <- 1..6, do: ViolationMonitor.threshold("3")
        end)

      assert log |> String.split("custody_halt_config_invalid") |> length() == 2
    end

    test "the ACCESSORS apply the guard — not just the guard function in isolation" do
      # Binds the wiring the mutation test would otherwise miss: delete the
      # validation from threshold/1 or window_seconds/1 and these fail.
      capture_log(fn ->
        assert ViolationMonitor.threshold(0) == 3
        assert ViolationMonitor.window_seconds("3600") == 3_600
      end)

      assert ViolationMonitor.threshold(5) == 5
      assert ViolationMonitor.window_seconds(60) == 60
    end
  end

  describe "window — violations age out of the detection window" do
    test "violations older than the window do not count toward the threshold" do
      tenant = fixture(:tenant)
      t0 = ~U[2026-01-01 00:00:00.000000Z]
      pin_clock(t0)

      for _ <- 1..(ViolationMonitor.threshold() - 1) do
        ViolationMonitor.record(tenant.id, "self_verify_blocked")
      end

      # Step past the window: the earlier violations are no longer evidence of a
      # CURRENT pattern, so the next one starts a fresh count instead of halting.
      later = DateTime.add(t0, ViolationMonitor.window_seconds() + 1, :second)
      pin_clock(later)

      assert {:ok, :recorded, 1} =
               ViolationMonitor.record(tenant.id, "self_verify_blocked")

      refute halted?(tenant.id)
    end

    test "violations inside the window still accumulate across time" do
      tenant = fixture(:tenant)
      t0 = ~U[2026-01-01 00:00:00.000000Z]
      threshold = ViolationMonitor.threshold()
      step = div(ViolationMonitor.window_seconds(), threshold + 1)

      for n <- 0..(threshold - 1) do
        pin_clock(DateTime.add(t0, n * step, :second))
        ViolationMonitor.record(tenant.id, "self_report_blocked")
      end

      assert halted?(tenant.id)
    end
  end

  describe "tenant isolation" do
    test "one tenant's violations never count toward another's threshold" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      for _ <- 1..(ViolationMonitor.threshold() * 2) do
        ViolationMonitor.record(tenant_a.id, "self_verify_blocked")
      end

      assert halted?(tenant_a.id)

      # Tenant B has contributed nothing and must be untouched: its counter starts
      # at 1 and its custody surface stays open.
      assert {:ok, :recorded, 1} =
               ViolationMonitor.record(tenant_b.id, "self_report_blocked")

      refute halted?(tenant_b.id)
      assert ViolationMonitor.count_in_window(tenant_b.id) == 1
    end

    test "count_in_window/2 is scoped to the tenant it is asked about" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      ViolationMonitor.record(tenant_a.id, "self_verify_blocked")
      ViolationMonitor.record(tenant_a.id, "self_verify_blocked")

      assert ViolationMonitor.count_in_window(tenant_a.id) == 2
      assert ViolationMonitor.count_in_window(tenant_b.id) == 0
    end
  end

  describe "alerting — an operator must learn about a halt immediately" do
    test "the halt emits [:loopctl, :custody, :halt] telemetry with the tenant and reason" do
      tenant = fixture(:tenant)
      test_pid = self()
      ref = make_ref()
      handler_id = "custody-halt-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :custody, :halt],
        fn _event, measurements, metadata, _config ->
          if metadata[:tenant_id] == tenant.id do
            send(test_pid, {ref, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      for _ <- 1..ViolationMonitor.threshold() do
        ViolationMonitor.record(tenant.id, "self_verify_blocked")
      end

      assert_receive {^ref, measurements, metadata}
      assert measurements.violations_in_window == ViolationMonitor.threshold()
      assert metadata.violation_type == "self_verify_blocked"
      assert metadata.threshold == ViolationMonitor.threshold()
    end

    test "the halt logs at :error carrying the tenant and the count" do
      tenant = fixture(:tenant)

      log =
        capture_log(fn ->
          for _ <- 1..ViolationMonitor.threshold() do
            ViolationMonitor.record(tenant.id, "self_report_blocked")
          end
        end)

      # capture_log sees the whole VM's Logger, so key on this tenant's own line.
      halt_line =
        log
        |> String.split("\n")
        |> Enum.filter(
          &(String.contains?(&1, tenant.id) and String.contains?(&1, "custody_halted"))
        )
        |> Enum.join("\n")

      assert halt_line =~ "custody_halted"
      assert halt_line =~ "threshold=#{ViolationMonitor.threshold()}"
    end

    test "the halt is appended to the tamper-evident audit chain" do
      tenant = fixture(:tenant)

      for _ <- 1..ViolationMonitor.threshold() do
        ViolationMonitor.record(tenant.id, "self_verify_blocked")
      end

      %{data: entries} = AuditChain.list_entries(tenant.id, action: "custody_halted")

      assert [entry] = entries
      assert entry.payload["reason"] == "self_verify_blocked"
      assert entry.payload["violations_in_window"] == ViolationMonitor.threshold()
    end
  end

  describe "input handling" do
    test "an unknown violation type is refused rather than silently counted" do
      tenant = fixture(:tenant)

      assert {:error, %Ecto.Changeset{}} =
               ViolationMonitor.record(tenant.id, "not_a_custody_violation")

      assert ViolationMonitor.count_in_window(tenant.id) == 0
    end

    test "a missing tenant id is refused" do
      assert {:error, :missing_tenant} = ViolationMonitor.record(nil, "self_report_blocked")
    end

    test "unparseable attribution ids never cost us the detection" do
      tenant = fixture(:tenant)

      assert {:ok, :recorded, 1} =
               ViolationMonitor.record(tenant.id, "self_report_blocked",
                 story_id: "not-a-uuid",
                 api_key_id: "also-not-a-uuid"
               )
    end
  end
end
