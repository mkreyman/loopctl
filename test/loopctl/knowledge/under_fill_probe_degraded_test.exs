defmodule Loopctl.Knowledge.UnderFillProbeDegradedTest do
  @moduledoc """
  The under-fill probe's fail-soft exit (`Loopctl.Knowledge.under_fill_probe_degraded/2`).

  The probe is ADVISORY — it runs only once the suggestions are already in hand — so a DB
  fault on it degrades to "no truncation signal" and the request still returns 200. That
  makes the refusal INVISIBLE unless it carries a signal of its own, which is why the
  degradation emits a bounded counter rather than only a log line. A future change that
  reinstated the old `reraise` would trade a valid 200 for a 503 over a diagnostic read,
  the exact AREA-5 fail-soft violation this path exists to avoid.

  `LocalGuc`'s capture ABORT shares `DBConnection.ConnectionError` with a transient pool
  fault and is deliberate, so it must stay separable on a dashboard.
  """
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog

  alias Loopctl.ExitTag
  alias Loopctl.Knowledge
  alias Loopctl.LocalGuc
  alias Loopctl.TelemetryEvents

  setup :verify_on_exit!

  # Forward the degraded-probe counter for THIS tenant to the test process (the handler is
  # process-GLOBAL and the suite is async), with guaranteed detach.
  defp attach_degraded(tenant_id) do
    test_pid = self()
    handler_id = "probe-degraded-#{System.unique_integer([:positive])}"
    event = TelemetryEvents.vector_search_under_fill_probe_degraded()

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _ ->
        if metadata.tenant_id == tenant_id,
          do: send(test_pid, {:probe_degraded, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Built by hand, then BOUND to the real discriminator: if `LocalGuc`'s abort tag ever
  # changes, `capture_abort?/1` stops matching and this fails HERE, loudly, instead of
  # quietly turning the assertion below into "connection" == "connection".
  defp capture_abort_error do
    e = %DBConnection.ConnectionError{
      message:
        ~s(LocalGuc: could not capture ["statement_timeout"], which an enclosing scope ) <>
          "already overrode"
    }

    assert LocalGuc.capture_abort?(e)
    e
  end

  test "a LocalGuc capture abort degrades (never raises) under its OWN error_class" do
    tenant_id = Ecto.UUID.generate()
    attach_degraded(tenant_id)

    assert :error = Knowledge.under_fill_probe_degraded(tenant_id, capture_abort_error())

    assert_receive {:probe_degraded, %{count: 1}, metadata}
    assert metadata.endpoint == :suggested_links
    # Not "connection": a deliberate refusal must be distinguishable from a pool blip.
    assert metadata.error_class == "guc_capture_abort"
  end

  test "a transient pool fault and a 57014 cancel each degrade under their own class" do
    tenant_id = Ecto.UUID.generate()
    attach_degraded(tenant_id)

    pool_fault = %DBConnection.ConnectionError{message: "tcp connect (db.internal:5432): timeout"}
    cancel = %Postgrex.Error{postgres: %{code: :query_canceled, message: "canceling statement"}}

    assert :error = Knowledge.under_fill_probe_degraded(tenant_id, pool_fault)
    assert_receive {:probe_degraded, %{count: 1}, %{error_class: "connection"}}

    assert :error = Knowledge.under_fill_probe_degraded(tenant_id, cancel)
    assert_receive {:probe_degraded, %{count: 1}, %{error_class: "timeout"}}
  end

  test "a pool EXIT degrades under a kind-prefixed, bounded class" do
    # The probe's two rescue clauses cover only the RAISE shape. A DBConnection checkout
    # against a wedged or unstarted pool EXITS, escaping them entirely and destroying an
    # ALREADY-COMPUTED suggestions response — turning a diagnostic read into a failed
    # request, which is the trade the `DBConnection.ConnectionError` clause exists to
    # prevent. `Loopctl.ExitTag` classifies the reason; the kind prefix keeps a dead pool
    # distinguishable from a throw.
    tenant_id = Ecto.UUID.generate()
    attach_degraded(tenant_id)

    assert :error =
             Knowledge.under_fill_probe_degraded(
               tenant_id,
               {:exit, ExitTag.tag({:noproc, {DBConnection, :execute, []}})}
             )

    assert_receive {:probe_degraded, %{count: 1}, metadata}
    assert metadata.error_class == "exit:noproc"
    # Bounded: never the raw reason, which carries the DBConnection call tuple.
    refute metadata.error_class =~ "DBConnection"
  end

  test "the log carries the class tag, never the backend host from the exception message" do
    tenant_id = Ecto.UUID.generate()
    pool_fault = %DBConnection.ConnectionError{message: "tcp connect (db.internal:5432): timeout"}

    log = capture_log(fn -> Knowledge.under_fill_probe_degraded(tenant_id, pool_fault) end)

    assert log =~ "under_fill probe degraded (connection)"
    refute log =~ "db.internal"
  end
end
