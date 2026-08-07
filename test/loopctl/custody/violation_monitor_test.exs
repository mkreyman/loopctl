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

    test "a halt has ONE onset — a further violation does not refresh halted_at" do
      tenant = fixture(:tenant)

      for _ <- 1..ViolationMonitor.threshold() do
        ViolationMonitor.record(tenant.id, "self_report_blocked")
      end

      {:ok, halted} = Tenants.get_tenant(tenant.id)
      first_onset = halted.custody_halted_at

      assert {:ok, :already_halted, _count} =
               ViolationMonitor.record(tenant.id, "self_report_blocked")

      {:ok, still_halted} = Tenants.get_tenant(tenant.id)
      assert still_halted.custody_halted_at == first_onset
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
