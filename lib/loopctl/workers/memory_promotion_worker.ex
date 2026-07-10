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
     enqueued async). Then the watermark is upserted — INCLUDING a zero-survivor run —
     so the next trigger skips.

  ## Terminal vs retryable

    * `{:error, :embeddings_degraded}` (recall fell back) → `{:snooze, n}`; NO
      watermark advance, so a later healthy run re-attempts (AC-29.2.4).
    * `{:error, :quota_exceeded, _}` (subject at its memory cap) → `{:discard, _}`;
      TERMINAL — do NOT retry-loop the LLM. Watermark IS advanced so an unchanged
      session is not re-compiled just to hit the cap again.
    * any other `{:error, _}` (compile/LLM/write) → retryable; no watermark advance.

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

  @snooze_seconds 300

  @impl Oban.Worker
  def perform(%Oban.Job{
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

    fingerprint = Promoter.session_fingerprint(scope, session_id)

    if watermark_unchanged?(scope, session_id, fingerprint) do
      PromotionTelemetry.emit(:skipped, %{count: 1}, meta(scope, session_id))
      :ok
    else
      run_promotion(scope, session_id, fingerprint)
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

  defp run_promotion(scope, session_id, fingerprint) do
    case Promoter.compile(scope, session_id) do
      {:ok, candidates} ->
        PromotionTelemetry.emit(
          :compiled,
          %{candidates: length(candidates)},
          meta(scope, session_id)
        )

        persist(scope, session_id, fingerprint, candidates)

      {:error, reason} ->
        PromotionTelemetry.emit(
          :failed,
          %{count: 1},
          Map.put(meta(scope, session_id), :stage, :compile)
        )

        Logger.warning(
          "MemoryPromotionWorker: compile failed tenant=#{scope.tenant_id} " <>
            "session=#{session_id} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

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
        PromotionTelemetry.emit(:quota_exceeded, %{count: 1}, meta(scope, session_id))
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
