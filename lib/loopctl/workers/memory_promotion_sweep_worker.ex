defmodule Loopctl.Workers.MemoryPromotionSweepWorker do
  @moduledoc """
  Scheduled cross-tenant promotion sweep (Epic 29, Agent Memory Part 2 — US-29.2).

  The crontab target for auto-promotion (the per-session
  `Loopctl.Workers.MemoryPromotionWorker` cannot be a cron entry — it needs a
  `session_id`). Each tick it enumerates candidate sessions ACROSS ALL TENANTS on the
  BYPASSRLS `Loopctl.AdminRepo` (mirroring `KnowledgeMocWorker`'s all-tenants
  fan-out), pairs each session with ITS OWN `(tenant_id, subject_id)` from the row so a
  session is NEVER mis-attributed to another tenant/subject, and enqueues a
  per-session promotion job.

  ## Bounding (AC-29.2.7 / AC-29.2.8)

    * **Watermark pre-filter** — a session whose newest turn (`max(inserted_at)`)
      equals its watermark's `last_turn_inserted_at` is unchanged since the last
      compile and is skipped WITHOUT enqueuing (the worker re-checks the authoritative
      content hash).
    * **Per-tenant budget** — a tenant already at its compiles/hour cap is skipped
      (`Loopctl.Memory.promotion_budget_available?/2`, offset by this tick's own
      enqueues), so a tenant with thousands of stale sessions cannot exhaust its BYO
      LLM key.
    * **Per-tick cap** — at most `:memory_promotion_sweep_max_per_tick` sessions are
      enqueued per tick.

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
      enqueue(tenant_id, subject_id, session_id)
      {:cont, {count + 1, Map.update(allocated, tenant_id, 1, &(&1 + 1)), seen}}
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
  # across ALL tenants (BYPASSRLS). Single-turn sessions are excluded. Newest-active
  # sessions first so an active session is promoted before a stale one when capped.
  defp candidate_sessions(limit) do
    from(s in SessionMemory,
      group_by: [s.tenant_id, s.subject_id, s.session_id],
      having: count(s.id) > 1,
      order_by: [desc: max(s.inserted_at)],
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
