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

  An emitted nugget matches an expected fact by TOKEN-OVERLAP similarity (a
  Sørensen–Dice coefficient over case-folded word tokens) at or above a configurable
  threshold (`:memory_promotion_eval_match_threshold`, default 0.5).
  Matching is greedy best-first (each emitted nugget takes its highest-scoring
  still-unclaimed expected fact) and each expected fact is consumed at most once.

  Token-overlap — NOT exact string equality — is deliberate. In production the
  compiler runs a REAL LLM whose system prompt asks for a "concise standalone
  statement", i.e. a PARAPHRASE, so a correctly-extracted durable fact almost never
  reproduces its label character-for-character. Exact-equality matching would score a
  well-behaved production compiler at precision≈recall≈0 (every paraphrase a false
  positive AND its label a false negative), which would both peg the trend at zero and
  KILL the injection precision-drop signal AC-29.5.4 exists to produce (precision
  already floored at 0 cannot drop further). Token overlap is still fully deterministic
  and LABEL-DRIVEN — it is a similarity to FIXED ground-truth text, never a same-class
  LLM re-judging the output (that circularity is why auto-promotion was shelved).

  A compiler that returns `{:error, _}` for a session (e.g. a tenant with no LLM key)
  scores as "emitted nothing" — its expected facts become false negatives, dragging
  RECALL down (a health signal) without crashing the eval. When NOTHING is emitted
  across all sessions (`TP+FP == 0`, the total-outage shape), `precision` is `nil`
  (UNDEFINED — there were no predictions to be precise about), not `0.0`, so a
  precision-floor alert does not misfire on an infra outage; read `recall` instead.
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

  # The reserved subject the eval seeds its synthetic sessions under, shared from the
  # `Loopctl.Memory` context (single source of truth — the sweep worker and the
  # durable-promotion write path reference the same value).
  #
  # Isolation from real subjects is a VALIDATED invariant, not a naming convention — but
  # the mechanism is `Memory.subject_id_for/1` + a compile-time guard, NOT a column-type
  # rejection: `subject_id_for/1` always returns a UUID *value* (an agent key's `agent_id`,
  # else the key's own id), and `Memory`'s compile-time guard fails the build if this
  # sentinel is ever UUID-shaped. So every real subject_id is a UUID and this sentinel
  # deliberately is not — they provably cannot collide. (`subject_id` is actually a
  # `:string` column on both memory schemas, so Ecto does NOT reject a non-UUID at the DB
  # layer; that is precisely why the durable-promotion write path also refuses this
  # subject — see `Memory.persist_promotion/2`.)
  @eval_subject_id Memory.eval_subject_id()

  # Token-overlap similarity threshold at/above which an emitted nugget is counted a
  # match for an expected fact (see the "Matching rule" section of the moduledoc).
  @default_match_threshold 0.5

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

    # Pre-generate a session_id per labeled session so the try/after cleanup can delete
    # THIS run's seeded turns even when scoring blows up MID-map — a `Promoter.compile`
    # crash that is an UNEXPECTED exception (LLM adapter/parser fault), not the handled
    # `{:error, _}` tuple. Without pre-generated ids the cleanup couldn't name what was
    # already seeded, so a crash would strand synthetic turns until the TTL reaper runs
    # (up to `@seed_ttl_seconds`), widening the window an auto-promotion sweep could act on
    # them.
    sessions = Enum.map(dataset.sessions, fn session -> {new_session_id(), session} end)
    session_ids = Enum.map(sessions, fn {session_id, _session} -> session_id end)

    try do
      session_results =
        Enum.map(sessions, fn {sid, session} -> score_session(scope, sid, session) end)

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
        precision: precision(tp, fp),
        recall: recall(tp, fn_count),
        session_results: session_results
      }
    after
      # Clean up ONLY the synthetic turns THIS run seeded (scoped to its own per-run
      # session_ids), so a concurrent same-tenant run (a manual `run/1` mid-cron, an Oban
      # retry) can't wipe the other's in-flight seeds and record a spurious recall≈0
      # snapshot. In an `after` so cleanup runs on the happy path AND when scoring raises
      # — bounding exposure to the run's actual duration. Any turns stranded by a HARD
      # crash (VM exit) before this still carry a TTL (`@seed_ttl_seconds`) and are reaped
      # by `SessionMemoryPruneWorker` — the eval leaves no lasting residue either way.
      delete_eval_turns(tenant_id, session_ids)
    end
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

  # Seed a session's turns under the PRE-GENERATED `session_id`, compile via the Promoter,
  # and score emitted-vs-expected. The caller owns the id (so its try/after cleanup can
  # name this run's turns even if compile raises) and aggregates the returned result map.
  defp score_session(scope, session_id, %{id: id, turns: turns, expected_facts: expected}) do
    seed_session(scope, session_id, turns)

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

  # Greedy best-first, token-overlap, label-driven match. Each expected fact is consumed
  # at most once. NOT a live LLM judge (AC-29.5.1) — a deterministic similarity to FIXED
  # ground-truth text. Token overlap (not exact equality) tolerates the compiler's
  # paraphrase so a well-behaved production compiler scores near 1.0 and the injection
  # precision-drop signal (AC-29.5.4) stays alive. See the moduledoc "Matching rule".
  defp match(emitted, expected) do
    emitted_tokens = Enum.map(emitted, &tokenize(&1.text))
    expected_tokens = Enum.map(expected, &tokenize/1)

    {tp, remaining} =
      Enum.reduce(emitted_tokens, {0, expected_tokens}, fn tokens, {tp, remaining} ->
        case best_match_index(tokens, remaining) do
          nil -> {tp, remaining}
          idx -> {tp + 1, List.delete_at(remaining, idx)}
        end
      end)

    fp = length(emitted_tokens) - tp
    fn_count = length(remaining)
    {tp, fp, fn_count}
  end

  # Index of the still-unclaimed expected fact with the highest token-overlap similarity
  # to `tokens`, provided it clears the match threshold; `nil` when none qualifies.
  defp best_match_index(tokens, expected_tokens) do
    threshold = match_threshold()

    expected_tokens
    |> Enum.with_index()
    |> Enum.map(fn {etoks, idx} -> {similarity(tokens, etoks), idx} end)
    |> Enum.filter(fn {sim, _idx} -> sim >= threshold end)
    |> case do
      [] -> nil
      scored -> scored |> Enum.max_by(fn {sim, _idx} -> sim end) |> elem(1)
    end
  end

  # Sørensen–Dice coefficient over the two token SETS: 2·|A∩B| / (|A|+|B|). 1.0 for
  # identical token sets, 0.0 for disjoint. Empty-on-either-side scores 0.0.
  defp similarity(a, b) do
    total = MapSet.size(a) + MapSet.size(b)

    if total == 0 do
      0.0
    else
      2 * MapSet.size(MapSet.intersection(a, b)) / total
    end
  end

  # Case-folded word-token SET (letters/digits only; punctuation and whitespace split).
  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> MapSet.new()
  end

  # ===========================================================================
  # Synthetic session seeding + cleanup (out of the promotion write path)
  # ===========================================================================

  # A unique per-call session id (generated up front in `compute/2` so cleanup can name
  # this run's turns). Uniqueness avoids collisions across concurrent runs.
  defp new_session_id, do: "promeval-#{System.unique_integer([:positive])}"

  # Seed the session's turns as short-term memories under the reserved eval subject and
  # the caller-supplied `session_id`. The turns carry a TTL (`@seed_ttl_seconds`) so any
  # left stranded by a HARD crash before cleanup are reaped by `SessionMemoryPruneWorker`.
  defp seed_session(scope, session_id, turns) do
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

    :ok
  end

  # Delete only THIS run's synthetic eval turns — scoped to tenant + eval-subject AND
  # the run's own `session_ids` — so a concurrent same-tenant run's in-flight seeds are
  # never wiped. Stranded turns from a crashed run are TTL-reaped (see `compute/2`).
  defp delete_eval_turns(tenant_id, session_ids) do
    from(s in SessionMemory,
      where:
        s.tenant_id == ^tenant_id and s.subject_id == ^@eval_subject_id and
          s.session_id in ^session_ids
    )
    |> AdminRepo.delete_all()
  end

  defp sum_by(results, key), do: Enum.reduce(results, 0, &(&2 + Map.fetch!(&1, key)))

  # Precision is UNDEFINED (nil) when nothing was emitted (TP+FP == 0) — there were no
  # predictions to be precise about. Returning `nil` (not 0.0) keeps a precision-floor
  # alert from misfiring on a total LLM outage, where every session emits nothing.
  defp precision(0, 0), do: nil
  defp precision(tp, fp), do: tp / (tp + fp)

  # Recall is UNDEFINED (nil) only when there are no expected facts at all (TP+FN == 0);
  # a real outage has FN > 0, so recall is a well-defined 0.0 there (the health signal).
  defp recall(0, 0), do: nil
  defp recall(tp, fn_count), do: tp / (tp + fn_count)

  @doc "Token-overlap match threshold (`:memory_promotion_eval_match_threshold`)."
  @spec match_threshold() :: float()
  def match_threshold do
    Application.get_env(
      :loopctl,
      :memory_promotion_eval_match_threshold,
      @default_match_threshold
    )
  end
end
