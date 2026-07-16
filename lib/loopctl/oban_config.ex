defmodule Loopctl.ObanConfig do
  @moduledoc """
  Env-driven Oban queue widths (US-32.2).

  Queue concurrency is retuned during an incident via `OBAN_QUEUE_<NAME>` env vars
  (e.g. `fly secrets set OBAN_QUEUE_DEFAULT=20` + restart) WITHOUT a code change or
  deploy — the substrate for Epic 4 per-tenant fairness (#351).

  `config/runtime.exs` sets `config :loopctl, Oban, queues: Loopctl.ObanConfig.queues()`
  at the top level (outside any prod-only guard) so every queue is re-listed from
  env-or-default in every environment. Elixir `Config` DEEP-MERGES (rather than
  replaces) the `queues:` value, so a queue key present in config.exs but omitted here
  would actually be PRESERVED, not dropped — `queues/0` still always returns the full
  keyword list, one entry per default queue, so every queue stays env-tunable rather
  than silently falling back to its compile-time (non-tunable) width.

  ## Plugins / cron (US-35.3)

  `plugins/0` OWNS the full Oban `:plugins` list (Cron crontab + Lifeline + Pruner +
  Reindexer), and `config/runtime.exs` sets
  `config :loopctl, Oban, plugins: Loopctl.ObanConfig.plugins()` alongside `queues:`.
  Unlike `queues:`, the `:plugins` value is a plain list of bare atoms/tuples (NOT a
  keyword list), so Elixir `Config` REPLACES it wholesale rather than merging
  element-wise — whichever layer sets `plugins:` LAST wins. Therefore the crontab
  lives here (read at runtime) and `config/config.exs` no longer sets `plugins:`.

  This exists so the all-tenants `ComputeSthWorker` safety-sweep cron is runtime-tunable
  via `STH_SWEEP_CRON` (see `sth_sweep_cron/0`): an operator can slow/revert the sweep
  with `fly secrets set STH_SWEEP_CRON=... && restart`, no deploy. Every per-tenant job
  the sweep fans out still self-gates on `Loopctl.AuditChain.sth_needed?/1`, so the
  interval is a load/latency knob only — it can never produce a wrong STH.
  """

  alias Oban.Cron.Expression

  # Default widths are a literal, hand-maintained mirror of config/config.exs's
  # compile-time `config :loopctl, Oban, queues: [...]` (AC-32.2.3). Sum = 38
  # (9+5+2+3+2+5+3+2+3+3+1). Keep the two lists in sync when adding/removing/resizing
  # a queue (`TC-32.2.1` in oban_config_test.exs asserts they match).
  #
  # US-36.1: the long (~6-min) LLM `ContentIngestionWorker` moved to its own
  # `:ingestion` queue so a burst of ingests can no longer head-of-line-block the
  # sub-second linking/lint/MOC/metrics/reclassify/review `:knowledge` workers
  # (GH #351). `:verification` is registered (env-driven width) because it is a LIVE
  # feature: `Loopctl.Verification.create_run_and_enqueue/3` enqueues
  # `VerificationRunnerWorker` on `queue: :verification`; leaving it unregistered meant
  # those jobs enqueued but never ran. Widths stay env-tunable via
  # `OBAN_QUEUE_INGESTION` / `OBAN_QUEUE_VERIFICATION` (auto-derived from the atom name
  # — no extra code).
  #
  # Funding the two new lanes (a REBALANCE, NOT new capacity — the pool sum stays 38):
  # the `ingestion: 2` + `verification: 1` = 3 new-lane slots come from `:knowledge`
  # 5 -> 3 (2 slots) PLUS `:default` 10 -> 9 (1 slot). `:default` is a generously-
  # sized catch-all for periodic cleanup crons (Idempotency/BulkDeleteToken/Reauth/
  # AuditPartition/CostRollup/Webhook/TokenArchival/PendingEnrollment/Revoke/
  # SystemConfigRefresh/MemoryPromotionSweep — see `plugins/0`), none latency-
  # sensitive, so it absorbs the 1-slot draw without harm.
  #
  # Why keep `:knowledge` at 3 (not the mechanical 2) — review, medium: SEVEN workers
  # target `:knowledge` (ArticleLinking, KnowledgeLint, KnowledgeMoc, RetrievalMetrics,
  # KnowledgeReclassify, ReviewKnowledge, PromotionEval). Several of the nominally
  # "sub-second" workers ALSO have a heavy `all_tenants` cron variant that FANS OUT one
  # per-tenant job each (KnowledgeLint 4:00, RetrievalMetrics 4:30, PromotionEval 4:45
  # UTC daily; KnowledgeMoc weekly — see `plugins/0`'s crontab). Each per-tenant child
  # is wall-clock-bounded (~10 min timeout), NOT sub-second. At width 2, a mere TWO
  # overlapping per-tenant passes could occupy both slots and briefly delay the
  # genuinely sub-second `ArticleLinkingWorker` (fires on every knowledge_create) — a
  # milder re-run of the exact head-of-line blocking this story removes for ingestion.
  # Restoring `:knowledge` to 3 (funded from over-provisioned `:default`, budget-
  # neutral) means it now takes THREE concurrent heavy per-tenant passes to saturate
  # the fast lane, and the cron schedules are staggered so a 3-way overlap is far less
  # likely than a 2-way one. Still env-retunable UP via `OBAN_QUEUE_KNOWLEDGE` with no
  # deploy if the fast lane ever proves tight; the AC-36.1.3 workers stay ON
  # `:knowledge` (per-event invocations are short), so no worker moved off the lane.
  #
  # MUST NOT be `Application.compile_env(:loopctl, Oban)[:queues]`. That recorded a
  # compile-time consistency dependency on the WHOLE `[:loopctl, Oban]` app-env key,
  # and `config/runtime.exs` reassigns that exact key to `Loopctl.ObanConfig.queues()`
  # (deep-merged). At release boot, `Config.Provider.validate_compile_env/1` (on by
  # default; not disabled in `mix.exs` `releases/0`) compares the compile-time and
  # runtime values for every recorded key and ABORTS the node when they differ —
  # i.e. the instant an operator sets ANY `OBAN_QUEUE_*` env var (exactly the lever
  # this module exists to provide), the release refuses to boot. Reading a
  # runtime-overridden key at compile time defeats the entire feature; hardcoding
  # (or reading via `Application.get_env/2` at call time) avoids recording that
  # dependency in the first place.
  @default_queues [
    default: 9,
    webhooks: 5,
    cleanup: 2,
    analytics: 3,
    maintenance: 2,
    embeddings: 5,
    knowledge: 3,
    ingestion: 2,
    memory: 3,
    audit: 3,
    verification: 1
  ]

  @doc """
  Resolves the full Oban `queues` keyword list from `OBAN_QUEUE_<NAME>` env vars,
  falling back to the compile-time default for any queue whose env var is unset.
  """
  @spec queues() :: keyword(pos_integer())
  def queues do
    Enum.map(@default_queues, fn {queue, default} ->
      env_var = "OBAN_QUEUE_" <> String.upcase(Atom.to_string(queue))
      {queue, queue_size(System.get_env(env_var), default)}
    end)
  end

  @doc """
  Parses a queue-width env value, falling back to `default` when `value` is `nil`.

  Raises `ArgumentError` (never silently returns `0` or the default) when `value` is
  present but not a positive integer — invalid config must fail loud at boot, not
  produce a starved (0-concurrency) or silently-defaulted queue.
  """
  @spec queue_size(String.t() | nil, pos_integer()) :: pos_integer()
  def queue_size(nil, default) when is_integer(default) and default > 0, do: default

  def queue_size(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {size, ""} when size > 0 ->
        size

      _ ->
        raise ArgumentError,
              "OBAN queue size must be a positive integer, got: #{inspect(value)} (default: #{default})"
    end
  end

  # --- US-36.2: per-tenant in-flight fair-share caps + snooze backoff ---
  #
  # The contended-queue workers (ArticleEmbeddingWorker AND MemoryEmbeddingWorker on
  # :embeddings — BOTH tenant-scoped per-item fan-out producers must gate or one can
  # still monopolize the shared queue — ContentIngestionWorker on :ingestion, the
  # :knowledge relationship/cron-child workers) yield `{:snooze, n}` at the top of
  # their tenant-scoped perform/1 when
  # the tenant already occupies at/above its fair share of that queue's EXECUTING
  # slots (see `Loopctl.Oban.FairShare`). Cap K is DERIVED from the queue width so it
  # scales automatically when a width is retuned via `OBAN_QUEUE_<NAME>`.
  #
  # Default cap = `ceil(width / 2)`, floored at 1 — a single tenant may hold at most
  # ~half a contended queue's concurrency, leaving the rest for other tenants, e.g.
  # embeddings(5)->3, knowledge(3)->2, ingestion(2)->1. The floor of 1 is CRITICAL:
  # the cap must ALWAYS admit at least one slot per tenant so the gate can never wedge
  # a queue (all jobs snoozing forever) — see the US-36.2 SECURITY note.
  #
  # Live-tunable per queue via `OBAN_TENANT_FAIRSHARE_<NAME>` (e.g. loosen fairness
  # during an incident with `fly secrets set OBAN_TENANT_FAIRSHARE_EMBEDDINGS=5` +
  # restart — no deploy). Snooze backoff (default 5s base + 0..5s jitter → 5–10s) is
  # tunable via `OBAN_TENANT_FAIRSHARE_SNOOZE_SECONDS` / `_SNOOZE_JITTER`. Config-based
  # DI (read via `System.get_env/1` at call time), same as `queues/0` — NEVER
  # `Application.compile_env`, which would record a boot-aborting compile-env
  # dependency (see the @default_queues note above).
  @default_fair_share_snooze_base_seconds 5
  @default_fair_share_snooze_jitter_seconds 5

  @doc """
  The per-tenant fair-share cap (K) for `queue`: the number of that queue's EXECUTING
  slots one tenant may occupy before its next job snoozes (US-36.2).

  Resolves `OBAN_TENANT_FAIRSHARE_<QUEUE>` if set (positive integer, else raises like
  `queue_size/2`), otherwise DERIVES `ceil(width / 2)` from the current queue width,
  floored at 1. Always `>= 1` so the gate can never wedge the queue.
  """
  @spec tenant_fair_share_cap(atom()) :: pos_integer()
  def tenant_fair_share_cap(queue) when is_atom(queue) do
    width = Keyword.get(queues(), queue, 1)
    # div(width + 1, 2) == ceil(width / 2) for positive widths; max(_, 1) is defensive
    # (a width of 1 already yields 1) and encodes the "always >= 1 slot" invariant.
    derived = max(div(width + 1, 2), 1)
    env_var = "OBAN_TENANT_FAIRSHARE_" <> String.upcase(Atom.to_string(queue))
    queue_size(System.get_env(env_var), derived)
  end

  @doc """
  Force-validates EVERY fair-share knob at BOOT and returns their resolved values.

  Invoked from `config/runtime.exs` (which runs before the system starts, in every
  env) alongside `queues/0`, so a malformed `OBAN_TENANT_FAIRSHARE_<QUEUE>` cap,
  `OBAN_TENANT_FAIRSHARE_SNOOZE_SECONDS`, or `OBAN_TENANT_FAIRSHARE_SNOOZE_JITTER`
  aborts the node LOUD at boot — exactly like a malformed `OBAN_QUEUE_*` (which
  `queues/0` already validates at boot). Without this, a fat-fingered cap var would
  only surface at CALL time inside `Loopctl.Oban.FairShare.over_cap?/4`, whose count
  path FAILS OPEN and would SILENTLY disable fairness on that queue — during the exact
  incident an operator is trying to tune. Reading each knob here calls its parser
  (`queue_size/2` / `non_neg_size/2`), which raises `ArgumentError` on a
  present-but-malformed value, so evaluating this function IS the validation.

  Returns a map of the resolved caps (one per configured queue) plus the snooze
  base/jitter, purely so the boot config is introspectable; the gate re-reads env at
  call time (config-based DI), so the returned values are a boot-time snapshot, not a
  cache the gate consults.
  """
  @spec fair_share_config() :: %{
          caps: keyword(pos_integer()),
          snooze_base_seconds: pos_integer(),
          snooze_jitter_seconds: non_neg_integer()
        }
  def fair_share_config do
    caps = Enum.map(queues(), fn {queue, _width} -> {queue, tenant_fair_share_cap(queue)} end)

    %{
      caps: caps,
      snooze_base_seconds: fair_share_snooze_base_seconds(),
      snooze_jitter_seconds: fair_share_snooze_jitter_seconds()
    }
  end

  @doc """
  The base (minimum) fair-share snooze interval in seconds (US-36.2), from
  `OBAN_TENANT_FAIRSHARE_SNOOZE_SECONDS` (positive integer, else raises), default
  #{@default_fair_share_snooze_base_seconds}.
  """
  @spec fair_share_snooze_base_seconds() :: pos_integer()
  def fair_share_snooze_base_seconds do
    queue_size(
      System.get_env("OBAN_TENANT_FAIRSHARE_SNOOZE_SECONDS"),
      @default_fair_share_snooze_base_seconds
    )
  end

  @doc """
  The fair-share snooze JITTER span in seconds (US-36.2): the snooze is
  `base + rand(0..jitter)`. From `OBAN_TENANT_FAIRSHARE_SNOOZE_JITTER` (NON-negative
  integer — 0 disables jitter — else raises), default
  #{@default_fair_share_snooze_jitter_seconds}.
  """
  @spec fair_share_snooze_jitter_seconds() :: non_neg_integer()
  def fair_share_snooze_jitter_seconds do
    non_neg_size(
      System.get_env("OBAN_TENANT_FAIRSHARE_SNOOZE_JITTER"),
      @default_fair_share_snooze_jitter_seconds
    )
  end

  # --- US-36.3: batch-ingest backlog backpressure (429) ---
  #
  # Max in-flight :ingestion backlog (the broad non-terminal set —
  # available/scheduled/executing/retryable, via the worker-scoped, index-backed
  # `Loopctl.Oban.FairShare.in_flight_ingestion_backlog/1`) a SINGLE tenant may have
  # accumulated before the ingest endpoints (POST /api/v1/knowledge/ingest and
  # /ingest/batch) reject a NEW request with 429.
  #
  # This bounds ACCUMULATION, complementing US-36.2's fair-share gate (which bounds
  # per-tenant CONCURRENCY of executing slots). A 50-item batch fans each item out to
  # a ~6-min LLM ContentIngestionWorker job on the `:ingestion` queue (default width 2,
  # env OBAN_QUEUE_INGESTION). Default 500 lets a normal caller loop the 50-item
  # endpoint ~10 times before backpressure kicks in — generous headroom for legitimate
  # bulk work, while still stopping a runaway loop from piling up an unbounded backlog
  # that would starve the queue's drain and inflate memory/DB footprint. Ops retune
  # live via OBAN_INGEST_BACKLOG_MAX (no deploy) to loosen/tighten during an incident.
  @default_ingest_backlog_max 500

  @doc """
  In-flight `:ingestion` backlog (non-terminal jobs) at/above which a single tenant's
  ingest requests start being rejected with 429 (US-36.3).

  SOFT admission FLOOR, not a hard cap. The gate is a lock-free read-then-enqueue, so
  concurrent same-tenant requests can each pass the check and overshoot this value by up
  to the in-flight request concurrency (a benign TOCTOU). Read it as "start shedding
  around here", not "the backlog can never exceed this" — it is a backpressure valve to
  stop runaway monopolization, not an enforced ceiling. Gated on BOTH the batch and the
  single-item ingest paths so neither can be looped to bypass the other.

  From `OBAN_INGEST_BACKLOG_MAX` (positive integer, else raises `ArgumentError` like
  `queue_size/2`), default #{@default_ingest_backlog_max}.

  Validated at BOOT: `config/runtime.exs` evaluates this function (via
  `config :loopctl, :ingest_backlog_max, ...`), so a malformed value aborts the node
  LOUD at startup — like `OBAN_QUEUE_*` / `OBAN_TENANT_FAIRSHARE_*` — instead of
  surfacing only at call time as per-request 500s on the batch endpoint.

  Config-based DI: read via `System.get_env/1` at call time (NEVER
  `Application.compile_env`, which would record a boot-aborting compile-env
  dependency — see the `@default_queues` note above), so an operator can loosen/tighten
  the threshold during an incident with `fly secrets set OBAN_INGEST_BACKLOG_MAX=... &&
  restart`, no deploy.
  """
  @spec ingest_backlog_max() :: pos_integer()
  def ingest_backlog_max do
    queue_size(System.get_env("OBAN_INGEST_BACKLOG_MAX"), @default_ingest_backlog_max)
  end

  # Retry-After hint (seconds) advised to a client 429'd by the ingest backlog gate.
  # Deliberately tied to the :ingestion queue's DRAIN cadence, NOT the sub-second
  # fair-share snooze base: ContentIngestionWorker jobs are ~6-min LLM calls on a
  # width-2 queue, so a backlog drains over minutes-to-hours. A 5s hint would hot-loop a
  # compliant client into a steady stream of 429s (each re-running the admission count);
  # a ~1-min default keeps a Retry-After-honoring client off the endpoint between real
  # drains while staying a bounded, sensible "back off for a while" value.
  @default_ingest_backlog_retry_after_seconds 60

  @doc """
  Retry-After (seconds) advised to a client rejected by the batch/single-item ingest
  backlog gate (US-36.3). Scaled to the `:ingestion` queue's drain cadence rather than
  the fair-share snooze base, so a compliant client does not hot-loop retry->429.

  From `OBAN_INGEST_BACKLOG_RETRY_AFTER` (positive integer, else raises `ArgumentError`
  like `queue_size/2`), default #{@default_ingest_backlog_retry_after_seconds}.

  Validated at BOOT (via `config/runtime.exs`), so a malformed value aborts the node
  LOUD at startup instead of surfacing only at call time. Config-based DI: read via
  `System.get_env/1` at call time so ops can retune live with no deploy.
  """
  @spec ingest_backlog_retry_after_seconds() :: pos_integer()
  def ingest_backlog_retry_after_seconds do
    queue_size(
      System.get_env("OBAN_INGEST_BACKLOG_RETRY_AFTER"),
      @default_ingest_backlog_retry_after_seconds
    )
  end

  # Like `queue_size/2` but admits 0 (a valid "no jitter" value). Still fails loud on
  # a present-but-malformed / negative value rather than silently defaulting.
  @spec non_neg_size(String.t() | nil, non_neg_integer()) :: non_neg_integer()
  defp non_neg_size(nil, default) when is_integer(default) and default >= 0, do: default

  defp non_neg_size(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {size, ""} when size >= 0 ->
        size

      _ ->
        raise ArgumentError,
              "OBAN_TENANT_FAIRSHARE_SNOOZE_JITTER must be a non-negative integer, " <>
                "got: #{inspect(value)} (default: #{default})"
    end
  end

  # US-35.3: default safety-sweep interval for the all-tenants ComputeSthWorker cron.
  # Every 5 minutes — a low-frequency backstop that only catches appends the
  # event-driven enqueuer (US-35.2) missed. Down from the old `"* * * * *"` per-minute
  # poll, which fanned out one no-op job per active tenant every minute.
  @default_sth_sweep_cron "*/5 * * * *"

  @doc """
  Resolves the all-tenants `ComputeSthWorker` sweep cron expression from
  `STH_SWEEP_CRON`, falling back to `#{@default_sth_sweep_cron}` (every 5 minutes)
  when unset.

  Runtime-tunable (read via `System.get_env/1` at call time, invoked from
  `config/runtime.exs`) so an operator can slow/revert the safety sweep with
  `fly secrets set STH_SWEEP_CRON=... && restart`, no deploy. Because every
  per-tenant job the sweep fans out self-gates on `AuditChain.sth_needed?/1`, the
  interval is a load/latency knob only — worst case it delays (never corrupts) an STH
  for a tenant the event path also missed, by up to one sweep interval.

  Raises `ArgumentError` (like `queue_size/2`) when the env var is present but not an
  expression Oban itself accepts — a malformed non-nil value must fail loud at boot,
  not silently fall back to the default. Validation delegates to Oban's own parser
  (`Oban.Cron.Expression.parse/1`), so any form Oban's Cron plugin would accept is
  accepted here: a standard 5-field expression (`*/30 * * * *`), the extended
  step/range syntax, OR an `@`-nickname (`@hourly`, `@daily`, `@weekly`, `@monthly`,
  `@yearly`, `@annually`, `@midnight`, `@reboot`). Semantically-invalid values that
  happen to have 5 fields (e.g. `99 99 99 99 99`) are rejected too, because the parser
  range-checks each field. The validator can never be stricter than its consumer.
  """
  @spec sth_sweep_cron() :: String.t()
  def sth_sweep_cron do
    validate_cron(System.get_env("STH_SWEEP_CRON"), @default_sth_sweep_cron)
  end

  defp validate_cron(nil, default), do: default

  defp validate_cron(value, _default) when is_binary(value) do
    trimmed = String.trim(value)

    case Expression.parse(trimmed) do
      {:ok, _expression} ->
        # Return the TRIMMED value — Oban's Cron plugin re-parses whatever we hand it,
        # and it rejects trailing whitespace/newlines. Returning the raw `value` would
        # pass validation here but crash the plugin at boot with an unattributed
        # "unrecognized cron expression" error. Hand Oban exactly what we validated.
        trimmed

      {:error, %{message: message}} ->
        raise ArgumentError,
              "STH_SWEEP_CRON must be a cron expression Oban accepts " <>
                "(5-field or @nickname), got: #{inspect(value)} (#{message})"
    end
  end

  @doc """
  Returns the full Oban `:plugins` list (US-35.3).

  Owns the crontab so the all-tenants `ComputeSthWorker` safety-sweep schedule is
  driven by `sth_sweep_cron/0` (runtime-tunable via `STH_SWEEP_CRON`). All other
  crontab entries and the Lifeline/Pruner/Reindexer plugins are moved here VERBATIM
  from the former `config/config.exs` block — no schedule or option changed except the
  ComputeSthWorker entry, which went from `"* * * * *"` (every minute) to
  `sth_sweep_cron/0` (default `#{@default_sth_sweep_cron}`).
  """
  @spec plugins() :: list()
  def plugins do
    [
      {Oban.Plugins.Cron,
       crontab: [
         {"0 * * * *", Loopctl.Workers.IdempotencyCleanupWorker},
         {"0 * * * *", Loopctl.Workers.BulkDeleteTokenCleanupWorker},
         {"0 * * * *", Loopctl.Workers.ReauthChallengeCleanupWorker},
         {"0 2 * * *", Loopctl.Workers.AuditPartitionWorker},
         {"0 2 * * *", Loopctl.Workers.CostRollupWorker},
         {"0 3 * * *", Loopctl.Workers.WebhookCleanupWorker},
         {"0 3 * * 0", Loopctl.Workers.TokenDataArchivalWorker},
         {"0 4 * * *", Loopctl.Workers.KnowledgeLintWorker, args: %{"mode" => "all_tenants"}},
         {"0 5 * * 0", Loopctl.Workers.KnowledgeMocWorker, args: %{"mode" => "all_tenants"}},
         {"30 4 * * *", Loopctl.Workers.RetrievalMetricsWorker, args: %{"mode" => "all_tenants"}},
         # Daily promotion-compile-quality eval (Epic 29 / US-29.5): precision/recall of
         # Loopctl.Memory.Promoter against the committed labeled dataset. Calibration/
         # observability only — never gates promotion.
         {"45 4 * * *", Loopctl.Workers.PromotionEvalWorker, args: %{"mode" => "all_tenants"}},
         {"*/5 * * * *", Loopctl.Workers.PendingEnrollmentCleanupWorker},
         {"*/5 * * * *", Loopctl.Workers.SessionMemoryPruneWorker},
         # US-38.2: prune expired windows from the cluster-global Postgres rate
         # limiter's counter table. A cheap index-range delete; a no-op when the
         # Postgres limiter is unselected (table empty). Keep in sync with the
         # crontab assertion in oban_plugins_config_test.exs.
         {"*/10 * * * *", Loopctl.Workers.RateLimitCounterCleanupWorker},
         # Cross-tenant memory-promotion sweep (Epic 29 / US-29.2). Runs every 10 min —
         # KEEP this in sync with :memory_promotion_sweep_interval_seconds (600) below,
         # which is the data form of this schedule that the boot invariant reasons over.
         # The expiry floor MUST exceed this interval and stay shorter than
         # :session_memory_ttl_seconds (both asserted at boot) so session turns are
         # promoted before SessionMemoryPruneWorker can delete them (no silent
         # golden-nugget loss).
         {"*/10 * * * *", Loopctl.Workers.MemoryPromotionSweepWorker},
         # #411 Gap 3: HOURLY graduation of HOT long-term memories (recall_count >=
         # :memory_graduation_recall_threshold) into durable knowledge articles, deduped
         # via the novelty gate. DELIBERATELY slower than the 10-min promotion sweep —
         # graduation is not latency-sensitive and an hourly cadence keeps the
         # novelty-gate embedding spend low. Bounded per run by
         # :memory_graduation_max_per_run. Keep in sync with the crontab assertion in
         # oban_plugins_config_test.exs.
         {"0 * * * *", Loopctl.Workers.MemoryGraduationSweepWorker},
         # US-35.3: all-tenants STH safety sweep. Reduced from `"* * * * *"` (every
         # minute) to a low-frequency, config-driven backstop (default `*/5 * * * *`)
         # that only catches appends the event-driven enqueuer (US-35.2) missed. Each
         # fanned-out per-tenant job still self-gates on `AuditChain.sth_needed?/1`, so
         # slowing the poll can never produce a wrong STH — worst case it delays an STH
         # (for a tenant the event path also missed) by up to one sweep interval. Driven
         # by `sth_sweep_cron/0` (env `STH_SWEEP_CRON`) so it's tunable/revertible per
         # environment without a deploy.
         {sth_sweep_cron(), Loopctl.Workers.ComputeSthWorker, args: %{"mode" => "all_tenants"}},
         {"* * * * *", Loopctl.Workers.RevokeExpiredDispatchesWorker},
         {"* * * * *", Loopctl.Workers.SystemConfigRefreshWorker}
       ]},
      # Rescue jobs orphaned in :executing when a node dies mid-run (e.g. a deploy).
      # Without Lifeline these rows stay `executing` forever — 110 such orphans (from
      # 2026-06-22) were found still clogging the queues on 2026-07-10. Reset a stuck
      # job back to `available` (or discard if attempts are exhausted) after 30 min so
      # the slot frees and it re-runs instead of leaking.
      {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
      # Prune terminal (completed/discarded/cancelled) jobs older than 7 days so the
      # oban_jobs table doesn't grow unbounded.
      {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
      # US-34.1 (AC-34.1.4): periodically REINDEX CONCURRENTLY the oban_jobs indexes
      # (default: oban_jobs_args_index + oban_jobs_meta_index, once daily at midnight
      # UTC) so index bloat from this table's high churn (state transitions on every
      # job) doesn't silently degrade the queries the new US-34.1 gauges themselves
      # depend on. Purely additive — no job semantics change.
      Oban.Plugins.Reindexer
    ]
  end
end
