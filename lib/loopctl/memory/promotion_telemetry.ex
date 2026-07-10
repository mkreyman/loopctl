defmodule Loopctl.Memory.PromotionTelemetry do
  @moduledoc """
  `:telemetry` emission for the Epic 29 memory-promotion pipeline (US-29.2,
  AC-29.2.11 / SOUL rule 7).

  Every event is `[:loopctl, :memory_promotion, <event>]` with per-tenant metadata,
  so a sweep failing every tick (bad BYO key, open circuit, budget wall) is VISIBLE
  in metrics rather than silent. Emitted by both `Loopctl.Memory` (budget refusals)
  and the two workers (`MemoryPromotionWorker`, `MemoryPromotionSweepWorker`).

  ## Events

    * `:swept` — a sweep tick enumerated sessions (`%{sessions, enqueued}`).
    * `:skipped` — a session was watermark-unchanged and not re-compiled.
    * `:compiled` — a session was compiled (`%{candidates}` surviving the gate).
    * `:gated_out` — candidates dropped at promotion as exact duplicates.
    * `:promoted` — fresh `:promoted` memories written.
    * `:superseded` — near-dup supersedes (new row + prior superseded).
    * `:degraded` — recall fell back (embeddings degraded); run snoozed.
    * `:quota_exceeded` — subject hit its memory cap; run terminally discarded.
    * `:budget_exceeded` — tenant hit its compiles/hour cap; refused pre-LLM.
    * `:failed` — a compile/LLM/write failure (retryable).
  """

  @prefix [:loopctl, :memory_promotion]

  @type event ::
          :swept
          | :skipped
          | :compiled
          | :gated_out
          | :promoted
          | :superseded
          | :degraded
          | :quota_exceeded
          | :budget_exceeded
          | :failed

  @doc "Emit a promotion telemetry event with `measurements` and `metadata`."
  @spec emit(event(), map(), map()) :: :ok
  def emit(event, measurements, metadata)
      when is_atom(event) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(@prefix ++ [event], measurements, metadata)
  end
end
