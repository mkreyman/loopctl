defmodule Loopctl.Custody.ViolationMonitor do
  @moduledoc """
  L6 byzantine detection: records chain-of-custody violations and halts a tenant
  only once a REPEATED pattern is established.

  ## The invariant this restores

  A custody halt is the heaviest action loopctl can take against a tenant — it
  suspends the custody surface for every key the tenant holds, and only a human
  WebAuthn break-glass ceremony clears it. The gate that arms it must therefore
  fire on EVIDENCE OF A PATTERN, not on a single event, because a single event
  is not evidence of anything: distributed systems produce isolated protocol
  errors as a matter of course (a retried request, a resumed session, a token
  that aged out mid-flight). A halt that one ordinary error can arm is not a
  security control; it is an availability hazard that a well-behaved client
  trips by accident.

  So the halt now needs `threshold/0` violations inside `window_seconds/0`
  before it fires. Below the threshold the offending operation is STILL refused
  — the self-* gates return their 409 exactly as before, so nothing byzantine
  gets through while the counter fills. What changed is only the ESCALATION.

  ## Why a threshold, and not per-key scoping

  Scoping the halt to the offending key was the other candidate and it does not
  work here. Chain of Custody v2 mints an EPHEMERAL key per dispatch
  (`Loopctl.Dispatches`), so "the offending key" is gone by the next dispatch: a
  per-key halt is evaded for free by anyone with dispatch authority, while still
  bricking an honest agent's in-flight dispatch on its first protocol slip. The
  tenant remains the right BLAST RADIUS for a byzantine finding — a tenant whose
  agents are repeatedly trying to close their own custody loops has a systemic
  problem, not a key problem. What was wrong was the TRIGGER, not the scope.

  ## What counts, and what deliberately does not

  Only `Loopctl.Custody.Violation.valid_types/0` count: a caller refused by the
  self-verify or self-report gate. Those are unambiguous — the server resolved
  the caller's own lineage and found it closing its own loop, and no retry,
  timeout or crash-resume produces that shape.

  A capability-token rejection does NOT count and no longer halts anything. Every
  rejection reason the token layer can produce has a benign cause that ordinary
  operation reaches: a token is SINGLE-USE, so any retry of a request whose first
  attempt already consumed it is rejected as a replay; a token has a bounded TTL,
  so a slow or resumed agent presents an expired one; rotating the tenant audit
  key invalidates every outstanding signature at once. The token layer cannot
  distinguish those from abuse, the operation is already refused with a 403, and
  arming a tenant-wide halt from a signal that benign retries generate inverts
  the control. Capability rejections are instead surfaced as telemetry
  (`[:loopctl, :custody, :cap_rejected]`) plus a warning log, so an operator can
  alert on a genuine SPIKE — which is the shape that actually carries signal.

  ## Storage

  Violations live in `custody_violations`, tenant-scoped with RLS, so the counter
  is durable across restarts (an in-memory counter would let a slow drip reset
  itself on every deploy) and gives an operator the forensic record of WHY a
  halt fired. Counting is always scoped by an explicit `tenant_id` predicate —
  one tenant's violations can never contribute to another's threshold, and the
  count is never exposed across a tenant boundary.

  The clock is resolved through the `:clock` DI seam so the window is testable
  without sleeping or mutating global state.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.Custody.Violation
  alias Loopctl.Tenants

  @default_threshold 3
  @default_window_seconds 3_600

  @typedoc "Outcome of recording one violation."
  @type outcome ::
          {:ok, :recorded, non_neg_integer()}
          | {:ok, :halted, non_neg_integer()}
          | {:ok, :already_halted, non_neg_integer()}
          | {:error, term()}

  @doc """
  Number of violations inside the window that arms a custody halt.

  Configurable with `config :loopctl, :custody_halt_threshold`.
  """
  @spec threshold() :: pos_integer()
  def threshold, do: Application.get_env(:loopctl, :custody_halt_threshold, @default_threshold)

  @doc """
  Length of the detection window, in seconds.

  Configurable with `config :loopctl, :custody_halt_window_seconds`.
  """
  @spec window_seconds() :: pos_integer()
  def window_seconds,
    do: Application.get_env(:loopctl, :custody_halt_window_seconds, @default_window_seconds)

  @doc """
  Records one custody violation for `tenant_id` and halts the tenant if the
  windowed count has reached `threshold/0`.

  Returns `{:ok, :recorded, count}` below the threshold, `{:ok, :halted, count}`
  when this call armed the halt, `{:ok, :already_halted, count}` when the tenant
  was halted already (the halt timestamp is NOT refreshed — a halt has one
  onset), and `{:error, reason}` if the violation could not be recorded.

  ## Options

    * `:story_id` / `:api_key_id` / `:agent_id` — attribution for the forensic
      record. All optional; the gates that call this do not always have them.

  Never raises: the caller is an error path that must still return its 4xx.
  """
  @spec record(Ecto.UUID.t(), String.t(), keyword()) :: outcome()
  def record(tenant_id, violation_type, opts \\ [])

  def record(tenant_id, violation_type, opts) when is_binary(tenant_id) do
    now = clock().utc_now()

    with {:ok, _violation} <- insert(tenant_id, violation_type, now, opts) do
      count = count_in_window(tenant_id, now)
      emit_violation(tenant_id, violation_type, count, opts)
      maybe_halt(tenant_id, violation_type, count, now)
    end
  rescue
    e ->
      # A detection-path fault must never convert a clean 409 into a 500. Log it
      # loudly instead: a monitor that is silently down is itself an incident.
      Logger.error(
        "custody_violation_record_failed: #{Exception.message(e)} " <>
          "tenant_id=#{tenant_id} violation_type=#{violation_type}"
      )

      {:error, :record_failed}
  end

  def record(_tenant_id, _violation_type, _opts), do: {:error, :missing_tenant}

  @doc """
  Counts `tenant_id`'s violations inside the detection window ending at `now`.

  Scoped by an explicit `tenant_id` predicate — this runs on `AdminRepo`
  (BYPASSRLS), so the predicate IS the isolation. Another tenant's violations
  can never be counted here.
  """
  @spec count_in_window(Ecto.UUID.t(), DateTime.t() | nil) :: non_neg_integer()
  def count_in_window(tenant_id, now \\ nil) do
    now = now || clock().utc_now()
    since = DateTime.add(now, -window_seconds(), :second)

    Violation
    |> where([v], v.tenant_id == ^tenant_id and v.occurred_at >= ^since)
    |> AdminRepo.aggregate(:count)
  end

  # --- Private ---

  defp insert(tenant_id, violation_type, now, opts) do
    %Violation{tenant_id: tenant_id}
    |> Violation.changeset(%{
      violation_type: violation_type,
      occurred_at: now,
      story_id: uuid_or_nil(opts[:story_id]),
      api_key_id: uuid_or_nil(opts[:api_key_id]),
      agent_id: uuid_or_nil(opts[:agent_id])
    })
    |> AdminRepo.insert()
  end

  # Attribution is best-effort forensic detail; an unparseable id must never cost
  # us the DETECTION. Drop it rather than failing the insert on a cast error.
  defp uuid_or_nil(nil), do: nil

  defp uuid_or_nil(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp maybe_halt(tenant_id, violation_type, count, now) do
    cond do
      count < threshold() ->
        {:ok, :recorded, count}

      already_halted?(tenant_id) ->
        {:ok, :already_halted, count}

      true ->
        do_halt(tenant_id, violation_type, count, now)
    end
  end

  defp already_halted?(tenant_id) do
    case Tenants.get_tenant(tenant_id) do
      {:ok, tenant} -> Tenants.custody_halted?(tenant)
      _ -> false
    end
  end

  defp do_halt(tenant_id, violation_type, count, now) do
    case Tenants.halt_custody(tenant_id) do
      {:ok, _tenant} ->
        # An operator must learn about a halt from their alerting, not from a
        # support ticket: the tenant's custody surface is now frozen until a
        # human break-glass ceremony clears it.
        Logger.error(
          "custody_halted: tenant custody operations halted after repeated custody " <>
            "violations tenant_id=#{tenant_id} violation_type=#{violation_type} " <>
            "violations_in_window=#{count} threshold=#{threshold()} " <>
            "window_seconds=#{window_seconds()}"
        )

        :telemetry.execute(
          [:loopctl, :custody, :halt],
          %{count: 1, violations_in_window: count},
          %{
            tenant_id: tenant_id,
            violation_type: violation_type,
            threshold: threshold(),
            window_seconds: window_seconds()
          }
        )

        append_halt_audit(tenant_id, violation_type, count, now)
        {:ok, :halted, count}

      {:error, reason} ->
        Logger.error(
          "custody_halt_failed: could not halt tenant after repeated custody violations " <>
            "tenant_id=#{tenant_id} violation_type=#{violation_type} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # The halt itself belongs in the tamper-evident chain, not only in the app log:
  # it is a custody-state transition that a later audit must be able to replay.
  defp append_halt_audit(tenant_id, violation_type, count, now) do
    AuditChain.append(tenant_id, %{
      action: "custody_halted",
      actor_lineage: [],
      entity_type: "tenant",
      entity_id: tenant_id,
      payload: %{
        "reason" => violation_type,
        "violations_in_window" => count,
        "threshold" => threshold(),
        "window_seconds" => window_seconds(),
        "halted_at" => DateTime.to_iso8601(now)
      }
    })
  rescue
    e ->
      Logger.error("custody_halt_audit_failed: #{Exception.message(e)} tenant_id=#{tenant_id}")

      :ok
  end

  defp emit_violation(tenant_id, violation_type, count, opts) do
    Logger.warning(
      "custody_violation: custody gate refused a caller tenant_id=#{tenant_id} " <>
        "violation_type=#{violation_type} violations_in_window=#{count} " <>
        "threshold=#{threshold()} story_id=#{inspect(opts[:story_id])}"
    )

    :telemetry.execute(
      [:loopctl, :custody, :violation],
      %{count: 1, violations_in_window: count},
      %{
        tenant_id: tenant_id,
        violation_type: violation_type,
        story_id: opts[:story_id],
        threshold: threshold()
      }
    )
  end

  defp clock, do: Application.get_env(:loopctl, :clock, Loopctl.Clock.Default)
end
