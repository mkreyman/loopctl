defmodule Loopctl.Workers.MemoryPromotionWorker do
  @moduledoc """
  Oban worker that promotes ONE session's short-term turns into durable long-term
  memories (Epic 29, Agent Memory Part 2 / auto-promotion — US-29.2).

  Enqueued by the explicit trigger `Loopctl.Memory.promote_session/1` and by the
  cross-tenant `Loopctl.Workers.MemoryPromotionSweepWorker`. It is the SESSION-scoped
  half of the pipeline; the cron target is the sweep worker (this one needs a
  `session_id` and so cannot be a crontab entry).

  ## Flow (idempotency spine)

  1. **Watermark skip** — compute the session's current content hash
     (`Loopctl.Memory.Promoter.session_fingerprint/2`) and compare it to the stored
     `session_promotions` watermark. Equal hash → the session is unchanged since the
     last compile → skip WITHOUT calling the LLM (kills re-LLM-every-tick /
     paraphrase-drift). Emits `:skipped`.
  2. **Compile** — `Loopctl.Memory.Promoter.compile/2` (deterministic, temperature 0)
     → gated candidates. A `{:error, _}` compile/LLM failure returns `{:error, _}` for
     Oban RETRY with NO watermark advance (AC-29.2.9).
  3. **Persist** — `Loopctl.Memory.persist_promotion/2` writes survivors as
     `:promoted` memories (exact-dedupe + near-dup supersede, each row's embedding
     written SYNCHRONOUSLY at insert time so it is immediately recallable). Then the
     watermark is upserted — INCLUDING a zero-survivor run — so the next trigger skips.

  ## Terminal vs retryable

    * `{:error, :embeddings_degraded}` (recall fell back) → `{:snooze, n}`; NO
      watermark advance, so a later healthy run re-attempts (AC-29.2.4).
    * `{:error, :rate_limited_local}` (node-local provider admission gate shut,
      US-37.1) → `{:snooze, n}`; loss-free backpressure, NO attempt consumed and NO
      watermark advance, so the compile re-runs once local demand subsides.
    * `{:error, :quota_exceeded, _}` (subject at its memory cap) → `{:discard, _}`;
      TERMINAL — do NOT retry-loop the LLM. Watermark IS advanced so an unchanged
      session is not re-compiled just to hit the cap again. Because the cap halts the
      per-candidate reduce, survivors not yet written are DROPPED for this run; that
      count is emitted as `dropped` on the `:quota_exceeded` telemetry so the loss is
      VISIBLE, not silent. It is bounded (the subject is at its hard live-memory cap) and
      recoverable once the subject frees capacity AND the session content changes.
    * a compile/LLM `{:error, _}` → retryable, BUT bounded: a persistently-failing
      compile spends one BYO LLM call per attempt and is NOT reflected in the
      compiles/hour meter (which counts successful watermark rows), so after
      `@max_compile_attempts` attempts it is `{:discard, _}`ed rather than retried all the
      way to `max_attempts` — capping the uncounted key spend on the failure axis
      (AC-29.2.8).
    * any other `{:error, _}` (persist/write) → retryable; no watermark advance.

  ## Uniqueness (AC-29.2.5)

  Unique per `(tenant_id, subject_id, session_id)` across the live states, so a
  concurrent explicit + sweep enqueue for the same session cannot double-promote.
  """

  use Oban.Worker,
    queue: :memory,
    max_attempts: 5,
    unique: [
      keys: [:tenant_id, :subject_id, :session_id],
      states: [:available, :scheduled, :executing, :retryable],
      period: 900
    ]

  require Logger

  alias Loopctl.Memory
  alias Loopctl.Memory.Promoter
  alias Loopctl.Memory.PromotionTelemetry
  alias Loopctl.Memory.Scope
  alias Loopctl.Provider.Admission

  @snooze_seconds 300

  # Cap on the number of attempts a COMPILE (LLM) failure is retried before a terminal
  # discard. A failed compile spends one BYO LLM key call per attempt and is invisible to
  # the compiles/hour meter (which counts successful watermark rows), so retrying to the
  # full `max_attempts` would let a permanently-failing session spend the key unbounded on
  # the failure axis. A small cap keeps a transient provider blip retryable while bounding
  # that spend (AC-29.2.8). Persist/write failures are NOT subject to this cap — they cost
  # no LLM call — and retry to `max_attempts` as usual.
  @max_compile_attempts 2

  @impl Oban.Worker
  def perform(%Oban.Job{
        attempt: attempt,
        args:
          %{"tenant_id" => tenant_id, "subject_id" => subject_id, "session_id" => session_id} =
            args
      }) do
    scope = %Scope{
      tenant_id: tenant_id,
      subject_id: subject_id,
      project_id: Map.get(args, "project_id"),
      session_id: session_id
    }

    if subject_id == Memory.eval_subject_id() do
      # The reserved promotion-eval subject is NEVER auto-promoted — skip before spending an
      # LLM compile (a directly-enqueued job cannot slip past the sweep's candidate filter).
      # `persist_promotion/2` refuses it too as the final structural guarantee (US-29.5).
      PromotionTelemetry.emit(:skipped, %{count: 1}, meta(scope, session_id))
      :ok
    else
      promote_if_changed(scope, session_id, attempt)
    end
  end

  defp promote_if_changed(scope, session_id, attempt) do
    fingerprint = Promoter.session_fingerprint(scope, session_id)

    cond do
      # A 0/1-turn session has nothing durable to compile — `Promoter.compile/2`
      # short-circuits it to `{:ok, []}` with NO LLM call. Skip it HERE, BEFORE
      # `persist_promotion`, so it never writes a `session_promotions` watermark row.
      # Counting such a zero-LLM no-op against the per-hour budget is what let an agent
      # POST N distinct JUNK/empty `session_id`s (each 0 turns) and starve the tenant's
      # promotion budget at zero LLM cost (US-29.3 finding fix). No watermark advance is
      # correct: there is nothing to be idempotent about, and a later re-trigger is an
      # equally cheap no-op. A > 1-turn session that the LLM legitimately compiles to
      # zero survivors DID cost an LLM call and STILL watermarks (that path is unchanged).
      fingerprint.turn_count <= 1 ->
        PromotionTelemetry.emit(:skipped, %{count: 1}, meta(scope, session_id))
        :ok

      watermark_unchanged?(scope, session_id, fingerprint) ->
        PromotionTelemetry.emit(:skipped, %{count: 1}, meta(scope, session_id))
        :ok

      # AC-29.2.8 execution-time budget gate — the REAL cost boundary. `promote_session/1`
      # reserves atomically (per-tenant advisory lock), but the sweep's enqueue pre-check
      # is UNLOCKED, so a concurrent burst of distinct-session jobs can all pass that
      # pre-check and overshoot the compiles/hour cap by a small, bounded amount (roughly
      # ~memory-queue-concurrency) before any watermark advances. This RE-CHECK — right
      # before the LLM compile — is what actually caps the BYO-key spend: as earlier jobs
      # execute and advance the watermark count, later jobs in the burst bail here WITHOUT
      # an LLM call, so the overshoot converts to cheap no-ops rather than real compiles.
      # A watermark skip above is free (no LLM) and is intentionally NOT budget-gated.
      # Terminal discard (no retry loop against the same wall); the next sweep re-enqueues
      # if the session still needs promotion.
      not Memory.promotion_budget_available?(scope.tenant_id) ->
        PromotionTelemetry.emit(:budget_exceeded, %{count: 1}, meta(scope, session_id))
        {:discard, :budget_exceeded}

      true ->
        run_promotion(scope, session_id, fingerprint, attempt)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    trunc(:math.pow(attempt, 4) + 15 + :rand.uniform(30) * attempt)
  end

  defp watermark_unchanged?(scope, session_id, fingerprint) do
    case Memory.get_session_promotion(scope, session_id) do
      %{session_content_hash: hash} -> hash == fingerprint.content_hash
      nil -> false
    end
  end

  defp run_promotion(scope, session_id, fingerprint, attempt) do
    case Promoter.compile(scope, session_id) do
      {:ok, candidates} ->
        PromotionTelemetry.emit(
          :compiled,
          %{candidates: length(candidates)},
          meta(scope, session_id)
        )

        persist(scope, session_id, fingerprint, candidates)

      {:error, :rate_limited_local} ->
        # US-37.1 (AC-37.1.4): node-local provider admission backpressure. Snooze
        # loss-free (no attempt consumed, no watermark advance) rather than routing
        # through compile_failure_result/2, which would TERMINALLY discard after only
        # @max_compile_attempts under sustained provider backpressure. This is not a
        # compile FAILURE, so it is not counted/logged as one.
        {:snooze, Admission.snooze_seconds()}

      {:error, reason} ->
        PromotionTelemetry.emit(
          :failed,
          %{count: 1},
          Map.put(meta(scope, session_id), :stage, :compile)
        )

        # `session_id` is an opaque, agent-supplied free-form string — `inspect/1` it so
        # embedded newlines/control chars can't forge or corrupt log lines (log-injection
        # hardening for a chain-of-custody system). `tenant_id` is a server-derived UUID.
        Logger.warning(
          "MemoryPromotionWorker: compile failed tenant=#{scope.tenant_id} " <>
            "session=#{inspect(session_id)} reason=#{inspect(reason)}"
        )

        compile_failure_result(reason, attempt)
    end
  end

  # Bound the uncounted BYO-LLM key spend on the compile-failure axis (see
  # @max_compile_attempts). A transient blip stays retryable (`{:error, _}`); once the
  # attempt count reaches the cap it is TERMINALLY discarded rather than retried to
  # `max_attempts`. A bare `%Oban.Job{}` (unit tests) carries `attempt: 0` — below the cap
  # — so it stays retryable; the cap engages for real Oban-scheduled jobs as their attempt
  # count climbs.
  defp compile_failure_result(reason, attempt)
       when is_integer(attempt) and attempt >= @max_compile_attempts do
    {:discard, {:compile_failed, reason}}
  end

  defp compile_failure_result(reason, _attempt), do: {:error, reason}

  defp persist(scope, session_id, fingerprint, candidates) do
    case Memory.persist_promotion(scope, candidates) do
      {:ok, summary} ->
        emit_summary(scope, session_id, summary)
        {:ok, _} = Memory.upsert_session_promotion(scope, fingerprint)
        :ok

      {:error, :embeddings_degraded} ->
        PromotionTelemetry.emit(:degraded, %{count: 1}, meta(scope, session_id))
        # No watermark advance — retry when embeddings recover.
        {:snooze, @snooze_seconds}

      {:error, :quota_exceeded, summary} ->
        emit_summary(scope, session_id, summary)
        # The subject hit its hard live-memory cap mid-run, so `persist_promotion/2`
        # halted and the survivors not yet written were DROPPED. Emit that count alongside
        # `:quota_exceeded` so the loss is VISIBLE (not silent) in metrics — it is bounded
        # (subject at cap) and recoverable once capacity frees AND the session content
        # changes. `dropped` = compiled candidates minus the ones persist accounted for.
        dropped =
          max(length(candidates) - (summary.promoted + summary.superseded + summary.deduped), 0)

        PromotionTelemetry.emit(
          :quota_exceeded,
          %{count: 1, dropped: dropped},
          meta(scope, session_id)
        )

        # Advance the watermark so an unchanged session is not re-compiled just to hit
        # the cap again, then TERMINALLY discard (no LLM retry loop).
        {:ok, _} = Memory.upsert_session_promotion(scope, fingerprint)
        {:discard, :quota_exceeded}

      {:error, reason} ->
        PromotionTelemetry.emit(
          :failed,
          %{count: 1},
          Map.put(meta(scope, session_id), :stage, :persist)
        )

        {:error, reason}
    end
  end

  defp emit_summary(scope, session_id, summary) do
    base = meta(scope, session_id)
    PromotionTelemetry.emit(:promoted, %{count: summary.promoted}, base)
    PromotionTelemetry.emit(:superseded, %{count: summary.superseded}, base)
    PromotionTelemetry.emit(:gated_out, %{count: summary.deduped}, base)
  end

  defp meta(scope, session_id) do
    %{tenant_id: scope.tenant_id, subject_id: scope.subject_id, session_id: session_id}
  end
end
