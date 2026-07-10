defmodule Loopctl.Workers.MemoryPromotionSweepWorker do
  @moduledoc """
  Scheduled cross-tenant promotion sweep (Epic 29, Agent Memory Part 2 — US-29.2).

  The crontab target for auto-promotion (the per-session
  `Loopctl.Workers.MemoryPromotionWorker` cannot be a cron entry — it needs a
  `session_id`). Each tick it enumerates candidate sessions ACROSS ALL TENANTS on the
  BYPASSRLS `Loopctl.AdminRepo`, pairs each session with ITS OWN `(tenant_id,
  subject_id)` from the row so a session is NEVER mis-attributed to another
  tenant/subject, and enqueues a per-session promotion job.

  ## Candidate query — a single scoped aggregate (NOT a per-tenant fan-out)

  Unlike `KnowledgeMocWorker` (which fans out over the small `tenants` table one tenant
  at a time), this worker issues ONE `GROUP BY (tenant_id, subject_id, session_id)`
  aggregate over `session_memories`, `LEFT JOIN`ed to `session_promotions`. This is a
  deliberate choice, not the fan-out pattern: fanning out would run N separate aggregates
  (one per tenant) with no efficiency gain — the union still scans every session row —
  whereas the single aggregate does one indexed pass. Two properties keep it bounded at
  scale:

    * **Watermark filter is applied IN SQL, before the `LIMIT`.** The `HAVING` clause
      drops any session whose newest turn (`max(inserted_at)`) does not exceed its
      watermark's `last_turn_inserted_at` — so already-promoted, unchanged sessions never
      consume a scan slot or an enqueue. At steady state the candidate set is only the
      sessions that have actually changed since their last compile.
    * **Oldest-active first.** Rows are ordered `asc: max(inserted_at)` so the sessions
      whose turns are CLOSEST to their prune deadline are enqueued first. This bounds the
      AC-29.2.10 starvation risk: `SessionMemoryPruneWorker` deletes turns oldest-first,
      so promoting oldest-first keeps prune from ever racing ahead of the sweep for a
      given session (paired with the server-governed `expires_at` floor in
      `Loopctl.Memory`, which guarantees every turn outlives at least one sweep window).

  A supporting composite index `(tenant_id, subject_id, session_id, inserted_at)` backs
  the group/aggregate (migration `20260710130000`).

  ## Bounding (AC-29.2.7 / AC-29.2.8)

    * **Watermark pre-filter** — enforced in SQL (above); the Elixir `watermark_current?/1`
      re-check is a belt-and-suspenders guard against a watermark that advanced (e.g. an
      explicit trigger) between the query and the enqueue.
    * **Per-tenant budget** — a tenant already at its compiles/hour cap is skipped
      (`Loopctl.Memory.promotion_budget_available?/2`, offset by this tick's own
      enqueues), so a tenant with thousands of stale sessions cannot exhaust its BYO
      LLM key. The per-session worker RE-CHECKS this at execution too.
    * **Per-tick cap** — at most `:memory_promotion_sweep_max_per_tick` sessions are
      enqueued per tick.

  ## Failure telemetry (AC-29.2.11)

  Each `Oban.insert/1` result is inspected: a failing enqueue emits a `:failed`
  `PromotionTelemetry` event and is NOT counted toward `allocated`/the `:swept`
  `enqueued` measurement — so a sweep whose enqueues error every tick is VISIBLE in
  metrics rather than silently reporting success-shaped counts.

  Sessions with a single turn are excluded (nothing durable to compile) so they do not
  consume budget. Sweep-promoted memories are tenant-wide (`project_id: nil`); the
  explicit trigger carries `project_id`.
  """

  use Oban.Worker,
    queue: :memory,
    max_attempts: 3,
    unique: [fields: [:worker], period: 60]

  require Logger

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Memory
  alias Loopctl.Memory.PromotionTelemetry
  alias Loopctl.Memory.Scope
  alias Loopctl.Memory.SessionMemory
  alias Loopctl.Memory.SessionPromotion
  alias Loopctl.Workers.MemoryPromotionWorker

  @default_max_per_tick 100
  @default_scan_limit 2000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cap = max_per_tick()
    sessions = candidate_sessions(scan_limit())

    {_count, allocated, seen} =
      Enum.reduce_while(sessions, {0, %{}, %{}}, fn session, {count, allocated, seen} ->
        {tenant_id, _subject_id, _session_id, _last_at} = session
        seen = Map.update(seen, tenant_id, 1, &(&1 + 1))

        cond do
          count >= cap ->
            {:halt, {count, allocated, seen}}

          watermark_current?(session) ->
            {:cont, {count, allocated, seen}}

          true ->
            maybe_enqueue(session, count, allocated, seen)
        end
      end)

    emit_swept(seen, allocated)
    :ok
  end

  defp maybe_enqueue({tenant_id, subject_id, session_id, _last_at}, count, allocated, seen) do
    used = Map.get(allocated, tenant_id, 0)

    if Memory.promotion_budget_available?(tenant_id, used) do
      case enqueue(tenant_id, subject_id, session_id) do
        {:ok, _job} ->
          {:cont, {count + 1, Map.update(allocated, tenant_id, 1, &(&1 + 1)), seen}}

        {:error, reason} ->
          # AC-29.2.11: a failing enqueue is surfaced as :failed telemetry and NOT
          # counted toward `allocated` (which skews both the budget offset and the
          # :swept `enqueued` measurement). A sweep erroring every tick stays visible.
          PromotionTelemetry.emit(:failed, %{count: 1}, %{
            tenant_id: tenant_id,
            subject_id: subject_id,
            session_id: session_id,
            stage: :enqueue
          })

          # `session_id` is an opaque, agent-supplied free-form string — `inspect/1` it so
          # embedded newlines/control chars can't forge or corrupt log lines (log-injection
          # hardening). `tenant_id` is a server-derived UUID and safe.
          Logger.warning(
            "MemoryPromotionSweepWorker: enqueue failed tenant=#{tenant_id} " <>
              "session=#{inspect(session_id)} reason=#{inspect(reason)}"
          )

          {:cont, {count, allocated, seen}}
      end
    else
      {:cont, {count, allocated, seen}}
    end
  end

  defp enqueue(tenant_id, subject_id, session_id) do
    %{"tenant_id" => tenant_id, "subject_id" => subject_id, "session_id" => session_id}
    |> MemoryPromotionWorker.new()
    |> Oban.insert()
  end

  # Distinct (tenant_id, subject_id, session_id) with the session's newest-turn time,
  # across ALL tenants (BYPASSRLS). Single-turn sessions are excluded. The watermark
  # filter is applied IN SQL (LEFT JOIN session_promotions, HAVING newest-turn exceeds
  # the watermark) BEFORE the LIMIT, so already-promoted/unchanged sessions never consume
  # a scan slot. Oldest-active first (`asc: max(inserted_at)`) so sessions nearest their
  # prune deadline are enqueued first, bounding AC-29.2.10 starvation (prune deletes
  # oldest-first).
  #
  # The reserved promotion-eval subject (`Memory.eval_subject_id/0`) is excluded
  # STRUCTURALLY here: the eval (US-29.5) seeds synthetic labeled sessions — including an
  # adversarial injection turn — under that subject, and each has count > 1 and no
  # watermark, so without this filter a sweep tick overlapping the eval's seed→delete
  # window would enqueue them and promote the injection payload into a real `:promoted`
  # memory (AC-29.5.3 — the eval must stay out of the write path).
  defp candidate_sessions(limit) do
    eval_subject_id = Memory.eval_subject_id()

    from(s in SessionMemory,
      where: s.subject_id != ^eval_subject_id,
      left_join: w in SessionPromotion,
      on:
        w.tenant_id == s.tenant_id and w.subject_id == s.subject_id and
          w.session_id == s.session_id,
      group_by: [s.tenant_id, s.subject_id, s.session_id, w.last_turn_inserted_at],
      having:
        count(s.id) > 1 and
          (is_nil(w.last_turn_inserted_at) or max(s.inserted_at) > w.last_turn_inserted_at),
      order_by: [asc: max(s.inserted_at)],
      limit: ^limit,
      select: {s.tenant_id, s.subject_id, s.session_id, max(s.inserted_at)}
    )
    |> AdminRepo.all()
  end

  defp watermark_current?({tenant_id, subject_id, session_id, last_at}) do
    scope = %Scope{tenant_id: tenant_id, subject_id: subject_id}

    case Memory.get_session_promotion(scope, session_id) do
      %{last_turn_inserted_at: %DateTime{} = wm_at} -> DateTime.compare(wm_at, last_at) == :eq
      _ -> false
    end
  end

  defp emit_swept(seen, allocated) do
    Enum.each(seen, fn {tenant_id, sessions} ->
      PromotionTelemetry.emit(
        :swept,
        %{sessions: sessions, enqueued: Map.get(allocated, tenant_id, 0)},
        %{tenant_id: tenant_id}
      )
    end)
  end

  defp max_per_tick do
    Application.get_env(:loopctl, :memory_promotion_sweep_max_per_tick, @default_max_per_tick)
  end

  defp scan_limit do
    Application.get_env(:loopctl, :memory_promotion_sweep_scan_limit, @default_scan_limit)
  end
end
