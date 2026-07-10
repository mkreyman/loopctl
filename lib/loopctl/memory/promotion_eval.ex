defmodule Loopctl.Memory.PromotionEval do
  @moduledoc """
  Promotion-quality eval (Epic 29 / US-29.5): score the memory-promotion COMPILER's
  precision & recall against a COMMITTED labeled synthetic dataset.

  ## What it measures

  For each labeled session in the dataset we know the GROUND-TRUTH durable facts the
  compiler should emit (and the noise/injection it should strip). `run/1` seeds each
  session's turns, compiles them via `Loopctl.Memory.Promoter.compile/2`, and matches
  the emitted candidate nuggets against the ground-truth labels to derive:

    * `true_positives`  — emitted nuggets that match an expected durable fact
    * `false_positives` — emitted nuggets with NO expected match (an emitted injection
      nugget lands here — that is the poisoning-regression signal, AC-29.5.4)
    * `false_negatives` — expected durable facts the compiler failed to emit
    * `precision = TP / (TP + FP)`, `recall = TP / (TP + FN)`

  The result is snapshotted (a per-tenant/day/dataset-version row) and emitted as
  `:telemetry`, modeled EXACTLY on `Loopctl.Knowledge.RetrievalMetrics`, so
  promotion-compile quality is observable over time.

  ## What it is NOT (security / scope invariants)

    * **Out of the write path (AC-29.5.3).** It PERSISTS NO promoted memories and never
      touches the promotion gate (that stays the US-29.1 confidence threshold). The only
      rows it writes are the synthetic session turns it seeds under a RESERVED eval
      subject (`#{inspect(__MODULE__)}` uses `subject_id = "__promotion_eval__"`), which
      it deletes again after scoring.
    * **No live LLM judge (AC-29.5.1/AC-29.5.2).** Matching is a deterministic,
      label-driven text comparison — never a same-class LLM re-judging the output. A
      same-class judge is fooled by the same prompt injection as the compiler; that
      circularity is the whole reason auto-promotion was shelved.
    * **Tenant-scoped (AC-29.5.3).** The dataset is synthetic, so the eval NEVER samples
      or scores ANY tenant's promoted memories — a stronger guarantee than "doesn't
      cross tenants". Every DB read/write is explicitly scoped by `tenant_id`.

  ## Matching rule

  An emitted nugget matches an expected fact when their NORMALIZED texts (trimmed,
  case-folded, internal whitespace collapsed) are equal. Matching is greedy and each
  expected fact is consumed at most once. A compiler that returns `{:error, _}` for a
  session (e.g. a tenant with no LLM key) scores as "emitted nothing" — its expected
  facts become false negatives, dragging RECALL down (a health signal) without ever
  crashing the eval.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Memory
  alias Loopctl.Memory.Promoter
  alias Loopctl.Memory.PromotionEval.Dataset
  alias Loopctl.Memory.PromotionEvalSnapshot
  alias Loopctl.Memory.PromotionTelemetry
  alias Loopctl.Memory.Scope
  alias Loopctl.Memory.SessionMemory

  # A reserved, non-guessable-collision subject the eval seeds its synthetic sessions
  # under. It is NEVER a real API-key identity, so eval turns can never mingle with a
  # real subject's memory, and cleanup can target it wholesale.
  @eval_subject_id "__promotion_eval__"

  # Seeded eval turns are short-lived; they are deleted right after scoring, but carry a
  # short TTL as a belt-and-suspenders guard in case a run crashes before cleanup.
  @seed_ttl_seconds 3600

  @doc """
  Run the promotion-quality eval for `tenant_id`, snapshot it, and emit telemetry.

  Options:

    * `:tenant_id` (required) — the tenant to score under and snapshot for.
    * `:dataset` — the labeled dataset (default: `Dataset.default/0`).
    * `:day` — the snapshot day (default: today, UTC).

  Returns `{:ok, %PromotionEvalSnapshot{}}`.
  """
  @spec run(keyword()) :: {:ok, PromotionEvalSnapshot.t()} | {:error, Ecto.Changeset.t()}
  def run(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    with {:ok, snap} <- snapshot(tenant_id, opts) do
      PromotionTelemetry.emit(
        :eval,
        %{
          precision: snap.precision,
          recall: snap.recall,
          true_positives: snap.true_positives,
          false_positives: snap.false_positives,
          false_negatives: snap.false_negatives,
          session_count: snap.session_count
        },
        %{tenant_id: tenant_id, dataset_version: snap.dataset_version, day: snap.day}
      )

      {:ok, snap}
    end
  end

  @doc """
  Compile every labeled session under `tenant_id` and score precision/recall against
  the ground-truth labels. PURE calc over the dataset (seeds + compiles + cleans up its
  own synthetic turns); persists no snapshot and emits no telemetry.

  Returns a result map with aggregate counts plus a per-session `:session_results`
  breakdown (the latter is not persisted — it lets callers/tests assert per-case, e.g.
  the injection regression in TC-29.5.2).
  """
  @spec compute(Ecto.UUID.t(), keyword()) :: map()
  def compute(tenant_id, opts \\ []) do
    dataset = Keyword.get(opts, :dataset) || Dataset.default()
    day = Keyword.get(opts, :day, Date.utc_today())
    scope = %Scope{tenant_id: tenant_id, subject_id: @eval_subject_id, project_id: nil}

    session_results = Enum.map(dataset.sessions, &score_session(scope, &1))

    # Clean up ALL synthetic eval turns for this tenant (including any stranded by a
    # prior crashed run) once scoring is done — the eval leaves no residue.
    delete_eval_turns(tenant_id)

    tp = sum_by(session_results, :true_positives)
    fp = sum_by(session_results, :false_positives)
    fn_count = sum_by(session_results, :false_negatives)

    %{
      day: day,
      dataset_version: dataset.version,
      session_count: length(dataset.sessions),
      true_positives: tp,
      false_positives: fp,
      false_negatives: fn_count,
      precision: ratio(tp, tp + fp),
      recall: ratio(tp, tp + fn_count),
      session_results: session_results
    }
  end

  @doc """
  Compute the eval and upsert the snapshot (idempotent per tenant/dataset_version/day).
  Returns `{:ok, %PromotionEvalSnapshot{}}`.
  """
  @spec snapshot(Ecto.UUID.t(), keyword()) ::
          {:ok, PromotionEvalSnapshot.t()} | {:error, Ecto.Changeset.t()}
  def snapshot(tenant_id, opts \\ []) do
    m = compute(tenant_id, opts)

    attrs = %{
      day: m.day,
      dataset_version: m.dataset_version,
      session_count: m.session_count,
      true_positives: m.true_positives,
      false_positives: m.false_positives,
      false_negatives: m.false_negatives,
      precision: m.precision,
      recall: m.recall,
      computed_at: DateTime.utc_now()
    }

    %PromotionEvalSnapshot{tenant_id: tenant_id}
    |> PromotionEvalSnapshot.changeset(attrs)
    |> AdminRepo.insert(
      on_conflict:
        {:replace,
         [
           :session_count,
           :true_positives,
           :false_positives,
           :false_negatives,
           :precision,
           :recall,
           :computed_at,
           :updated_at
         ]},
      conflict_target: [:tenant_id, :dataset_version, :day]
    )
  end

  @doc """
  The promotion-eval time series, most recent day first. Opts: `:limit` (default 30),
  `:offset`. Returns `%{data: [snapshot maps], meta: %{limit, offset, total_count}}`.
  """
  @spec list_snapshots(Ecto.UUID.t(), keyword()) :: %{data: [map()], meta: map()}
  def list_snapshots(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 30) |> max(1) |> min(365)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base = from(s in PromotionEvalSnapshot, where: s.tenant_id == ^tenant_id)
    total_count = AdminRepo.aggregate(base, :count, :id)

    data =
      from(s in base,
        order_by: [desc: s.day, asc: s.dataset_version],
        limit: ^limit,
        offset: ^offset,
        select: %{
          day: s.day,
          dataset_version: s.dataset_version,
          session_count: s.session_count,
          true_positives: s.true_positives,
          false_positives: s.false_positives,
          false_negatives: s.false_negatives,
          precision: s.precision,
          recall: s.recall
        }
      )
      |> AdminRepo.all()

    %{data: data, meta: %{limit: limit, offset: offset, total_count: total_count}}
  end

  # ===========================================================================
  # Per-session scoring
  # ===========================================================================

  # Seed a session's turns, compile via the Promoter, and score emitted-vs-expected.
  defp score_session(scope, %{id: id, turns: turns, expected_facts: expected}) do
    session_id = seed_session(scope, turns)

    emitted =
      case Promoter.compile(scope, session_id) do
        {:ok, nuggets} -> nuggets
        # A compile failure (e.g. no LLM key) scores as "emitted nothing": the expected
        # facts become false negatives (recall drops — a health signal), never a crash.
        {:error, _reason} -> []
      end

    {tp, fp, fn_count} = match(emitted, expected)
    %{id: id, true_positives: tp, false_positives: fp, false_negatives: fn_count}
  end

  # Greedy, normalized, label-driven match. Each expected fact is consumed at most once.
  # NOT a live LLM judge (AC-29.5.1) — deterministic text equality.
  defp match(emitted, expected) do
    emitted_texts = Enum.map(emitted, &normalize(&1.text))
    expected_norm = Enum.map(expected, &normalize/1)

    {tp, remaining} =
      Enum.reduce(emitted_texts, {0, expected_norm}, fn text, {tp, remaining} ->
        if text in remaining do
          {tp + 1, List.delete(remaining, text)}
        else
          {tp, remaining}
        end
      end)

    fp = length(emitted_texts) - tp
    fn_count = length(remaining)
    {tp, fp, fn_count}
  end

  defp normalize(text) do
    text
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
  end

  # ===========================================================================
  # Synthetic session seeding + cleanup (out of the promotion write path)
  # ===========================================================================

  # Seed the session's turns as short-term memories under the reserved eval subject,
  # returning the generated session id. A unique id per call avoids collisions across
  # concurrent runs; expired/stranded rows are also swept by `delete_eval_turns/1`.
  defp seed_session(scope, turns) do
    session_id = "promeval-#{System.unique_integer([:positive])}"
    expires_at = DateTime.add(DateTime.utc_now(), @seed_ttl_seconds, :second)

    Enum.each(turns, fn content ->
      {:ok, _} =
        Memory.remember(scope, %{
          tier: :session,
          session_id: session_id,
          role: :user,
          content: content,
          expires_at: expires_at
        })
    end)

    session_id
  end

  # Delete every synthetic eval turn for this tenant (explicitly tenant + eval-subject
  # scoped). Leaves no residue — the eval is calibration-only.
  defp delete_eval_turns(tenant_id) do
    from(s in SessionMemory,
      where: s.tenant_id == ^tenant_id and s.subject_id == ^@eval_subject_id
    )
    |> AdminRepo.delete_all()
  end

  defp sum_by(results, key), do: Enum.reduce(results, 0, &(&2 + Map.fetch!(&1, key)))

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, denom), do: num / denom
end
