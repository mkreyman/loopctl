# Runbook: Promotion-compile quality eval (Epic 29 / US-29.5)

> **What this is.** An offline, deterministic EVALUATION of the memory-promotion
> compiler (`Loopctl.Memory.Promoter`). It feeds the compiler a **committed labeled
> synthetic dataset** — sessions whose expected durable facts (and expected
> noise/injection strippings) are KNOWN — and computes **precision & recall** of the
> emitted nuggets against those ground-truth labels. The score is snapshotted per
> tenant/day and emitted as `:telemetry`, so promotion-compile quality is observable
> over time.
>
> **What this is NOT.** It is **not** a promotion gate and **not** a live LLM judge.
> It never gates promotion (the gate stays the US-29.1 confidence threshold) and it
> never re-judges production memories with an LLM. A same-class LLM judge is fooled by
> the same prompt injection as the compiler — that circularity is the whole reason
> auto-promotion was shelved, so the eval matches against fixed labels, not a model.

---

## Where the data comes from

- **The dataset** is a committed, versioned data file:
  [`priv/promotion_eval/dataset_v1.json`](../../priv/promotion_eval/dataset_v1.json),
  loaded by [`Loopctl.Memory.PromotionEval.Dataset`](../../lib/loopctl/memory/promotion_eval/dataset.ex).
  Each session carries `turns` (fed to the compiler), `expected_facts` (the ground
  truth), and a reference `llm_output` (used only to drive the deterministic
  `MockPromoterLLM` in tests — production uses the tenant's real LLM). The dataset
  MUST include at least one **injection** case whose `expected_facts` is empty
  (AC-29.5.4).
- **The eval** is [`Loopctl.Memory.PromotionEval`](../../lib/loopctl/memory/promotion_eval.ex).
  `run/1` seeds each session's turns under a **reserved eval subject**
  (`__promotion_eval__`), compiles them via `Promoter.compile/2`, scores, deletes the
  synthetic turns, upserts a snapshot, and emits telemetry. It writes **no promoted
  memories** and touches **no other tenant's data** (the dataset is synthetic, so it
  never samples any tenant's promoted memories at all).
- **The snapshot** is the `promotion_eval_snapshots` table
  ([schema](../../lib/loopctl/memory/promotion_eval_snapshot.ex),
  [migration](../../priv/repo/migrations/20260710120000_create_promotion_eval_snapshots.exs)) —
  one RLS-enabled row per `(tenant_id, dataset_version, day)`, upserted on recompute.
  It stores `true_positives`, `false_positives`, `false_negatives`, `precision`,
  `recall`, and `session_count`. Modeled 1:1 on `retrieval_metric_snapshots`
  (US-27.15).
- **The worker** is [`Loopctl.Workers.PromotionEvalWorker`](../../lib/loopctl/workers/promotion_eval_worker.ex)
  on the `:knowledge` queue, scheduled daily (`45 4 * * *`) via the Oban Cron plugin. A
  `{"mode" => "all_tenants"}` tick fans out one `{"tenant_id" => ...}` job per active
  tenant, each of which snapshots + logs a line.

## The metric

For each labeled session we match the compiler's emitted nuggets against the ground
truth by **token-overlap similarity** (a Sørensen–Dice coefficient over case-folded
word tokens) at/above a configurable threshold
(`:memory_promotion_eval_match_threshold`, default `0.5`) — greedy best-first,
label-driven, **never an LLM**:

| Count | Meaning |
| --- | --- |
| `true_positives`  | emitted nuggets that match an expected durable fact |
| `false_positives` | emitted nuggets with NO expected match (**an emitted injection nugget lands here**) |
| `false_negatives` | expected durable facts the compiler failed to emit |

- `precision = TP / (TP + FP)` — did the compiler emit only durable facts?
- `recall = TP / (TP + FN)` — did it emit all the durable facts?

**Why token-overlap, not exact equality.** In production the compiler runs a real LLM
whose prompt asks for a "concise standalone statement" — i.e. a **paraphrase** — so a
correctly-extracted fact almost never reproduces its label character-for-character.
Exact-string matching would score a *well-behaved* compiler at precision≈recall≈0
(every paraphrase a false positive AND its label a false negative) and, worse, would
**kill the injection precision-drop signal** (precision already pegged at 0 cannot drop
further). Token overlap tolerates paraphrase while staying fully deterministic and
comparing only to FIXED ground-truth text — it is not a same-class LLM re-judging the
output. When a session's facts are semantically distinct (they are, by construction),
unrelated/injected text scores near 0 and does not spuriously match.

**Undefined precision (`nil`, not `0.0`).** When the compiler emits nothing at all
(`TP + FP == 0` — the total-LLM-outage shape), `precision` is **`nil`** (undefined —
there were no predictions to be precise about), not `0.0`. This is what keeps a
precision-floor alert from misfiring on an infra outage; on an outage read `recall`
(which is a well-defined `0.0`, since the expected facts all become false negatives).

The **injection case** is the load-bearing one: its `expected_facts` is empty, so a
compiler regression that emits an injected instruction as a "durable fact" shows up as
a **false positive → precision drop**, closing the loop with US-29.1 AC-29.1.5.

## The telemetry event

`[:loopctl, :memory_promotion, :eval]` (via
[`Loopctl.Memory.PromotionTelemetry`](../../lib/loopctl/memory/promotion_telemetry.ex)):

- **measurements**: `%{precision, recall, true_positives, false_positives, false_negatives, session_count}`
- **metadata**: `%{tenant_id, dataset_version, day}`

Attach a `Telemetry.Metrics` `last_value`/`distribution` on `precision`/`recall` to
chart the trend, or alert if precision drops below a floor on the injection-bearing
dataset.

## Honest caveats

- **Synthetic, not production.** The eval scores the compiler on a fixed synthetic
  dataset, not on live sessions. It answers "is the compiler still behaving on cases we
  understand", not "is it good on this tenant's real traffic". That is deliberate — the
  alternative (an LLM re-judging real memories) is the circular design we rejected.
- **Compile errors drag recall, not precision.** If a tenant has no LLM key,
  `Promoter.compile/2` returns `{:error, _}`; the eval scores that session as "emitted
  nothing", so its expected facts become false negatives (recall drops) without a crash.
  On a *total* outage every session emits nothing, so `precision` is **`nil`**
  (undefined) and `recall` is `0.0` — a nil precision with recall at/near 0 means "the
  tenant's LLM is unavailable", not "the compiler is wrong". (Precision is `nil`, not a
  low number, precisely so a precision-floor alert does not misfire on an outage.)
- **The daily worker only scores tenants with an extraction key, and the spend is
  bounded + attributed.** Scoring the real compiler runs a real extraction LLM call per
  labeled session on the tenant's BYO key, so the `all_tenants` fan-out only enqueues
  tenants that have a usable extraction key — selected in one round-trip by joining
  `tenant_llm_settings` on a non-null `api_key` (no per-tenant N+1 settings read) — so
  there is no wasted job on a keyless tenant. For a keyed tenant the cost is a handful of short synthetic sessions
  once/day, the extraction call records per-tenant token usage best-effort, and the eval
  emits a per-tenant telemetry event — so the calibration spend is observable.
- **The reference `llm_output` is a test aid, not the score.** Production runs use the
  tenant's real LLM; the committed `llm_output` only makes the test path deterministic.
  The score always compares the compiler's REAL output to `expected_facts`.
- **Bump `dataset_version` when you change labels.** The natural key is
  `(tenant_id, dataset_version, day)`, so a new dataset version starts a fresh series
  rather than overwriting the old one — keep the trend honest across dataset changes.
