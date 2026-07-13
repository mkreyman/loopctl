defmodule Loopctl.HealthCheck.Default do
  @moduledoc """
  Default health check implementation.

  Checks database connectivity (SELECT 1), Oban process status, and the US-32.4
  scale-alerts config-guard. Returns the application version from the mix project
  config.

  ## Liveness (`status`) vs readiness (`ready`) — US-32.4 post-review correction

  `fly.toml` wires plain `GET /health` as the CONTINUOUS `http_service` load-balancer
  check (10s interval, `min_machines_running: 1`, `strategy: rolling`) — it is not a
  deploy-only smoke probe, it decides whether a running node stays in traffic rotation
  RIGHT NOW. A benign, purely observational misconfiguration (scale alerts enabled but
  no webhook URL) must never depool an otherwise-healthy node on that continuous check.

  So `status` — the field `LoopctlWeb.HealthController.check/2` uses for `/health`'s
  HTTP code, i.e. the one Fly's proxy acts on — reflects ONLY `database` and `oban`:
  the things that mean this node genuinely cannot serve traffic. `scale_alerts` is
  still surfaced in `checks` (and `reasons` on failure) for visibility, but it does
  NOT flip `status`.

  A separate `ready` boolean additionally folds in `scale_alerts` and (US-34.2)
  `oban_orphans`, and is acted on ONLY by `GET /health/ready`
  (`LoopctlWeb.HealthController.ready/2`) — a genuine deploy-time smoke gate an
  operator or deploy pipeline can poll explicitly, distinct from the endpoint Fly's
  proxy continuously checks. This satisfies AC-32.4.1's "flip a readiness flag so
  /health (or the readiness endpoint) reports NOT-ready" via the readiness-endpoint
  branch of that disjunction.

  ## Oban orphan backlog is a READINESS signal, not a liveness one (US-34.2)

  `check_oban/0` below is a GenServer liveness ping (`Oban.check_queue/1`) — it stays
  "ok" even when the `:default` queue is full of jobs wedged in `:executing` (the real
  17-day/110-orphan stall this story addresses). `check_oban_orphans/0` closes that
  gap by comparing the `:executing`-older-than-N-minutes orphan count against a
  configurable COUNT threshold (`:oban_orphan_health_threshold`, AC-34.2.4). Per
  AC-34.2.2, a queue backlog must NOT depool a node from Fly's LB — a node with a
  backlog can still serve HTTP requests — so `oban_orphans` is folded into `ready`
  (readiness) ONLY, exactly mirroring how `scale_alerts` was wired in US-32.4.
  `status` (liveness) is UNCHANGED by this story: still database/oban only.

  Post-review (request-amplification finding): `check_oban_orphans/0` does NOT run
  its own DB query. Both `/health` (continuous, unauthenticated, hit by Fly's LB
  every 10s AND reachable at any rate from the internet) and `/health/ready` share
  this SAME `check/0`, so an unauthenticated caller flooding `/health` would
  otherwise force a fresh `SELECT count(*) FROM oban_jobs` on every hit — pool
  pressure that only ever benefits `ready`, which liveness `status` doesn't even
  consult. Instead it reads the count US-34.1's `poll_oban_executing_orphans/0`
  (a `telemetry_poller` measurement, already ticking every 10s) cached in
  `:persistent_term` on its last successful poll
  (`Loopctl.Telemetry.ScaleMetrics.cached_executing_orphan_count/0`) — exactly the
  reuse this story's technical_notes preferred over a second bounded query. The
  cached count and the configured threshold are never disclosed verbatim in the
  public `reasons.oban_orphans` string (both endpoints are unauthenticated); the
  exact figures are available via the `loopctl.oban.jobs.executing_orphan.count`
  Prometheus gauge on the internal, non-public metrics port instead.
  """

  @behaviour Loopctl.HealthCheck.Behaviour

  alias Ecto.Adapters.SQL
  alias Loopctl.Telemetry.ScaleAlerts
  alias Loopctl.Telemetry.ScaleMetrics

  # US-34.2 (AC-34.2.4): default COUNT threshold for `check_oban_orphans/0`, distinct
  # from `ScaleMetrics`'s 45-minute AGE threshold (which decides WHICH jobs count as
  # orphans in the first place). Safe even though modest — see the config.exs comment
  # for the full rationale.
  @default_oban_orphan_health_threshold 10

  @impl true
  def check do
    db_check = check_database()
    oban_check = check_oban()
    scale_alerts_check = check_scale_alerts()
    oban_orphans_check = check_oban_orphans()

    checks = %{
      database: elem(db_check, 0),
      oban: elem(oban_check, 0),
      scale_alerts: elem(scale_alerts_check, 0),
      oban_orphans: elem(oban_orphans_check, 0)
    }

    # Liveness: database/oban only — see the moduledoc on why scale_alerts/oban_orphans
    # must NOT participate here (either would let a benign or backlog-only issue depool
    # a healthy node on Fly's continuous load-balancer check).
    status =
      if checks.database == "ok" and checks.oban == "ok",
        do: "ok",
        else: "degraded"

    # Readiness: liveness AND the scale-alerts config-guard AND the oban-orphans
    # backlog guard. Only `/health/ready` acts on this — it is the deploy-time smoke
    # signal, not the traffic-routing one.
    ready =
      status == "ok" and checks.scale_alerts == "ok" and checks.oban_orphans == "ok"

    result = %{status: status, ready: ready, version: app_version(), checks: checks}

    result =
      result
      |> maybe_put_reason(:scale_alerts, scale_alerts_check)
      |> maybe_put_reason(:oban_orphans, oban_orphans_check)

    {:ok, result}
  end

  defp check_database do
    case SQL.query(Loopctl.Repo, "SELECT 1", [], timeout: 5_000) do
      {:ok, _} -> {"ok"}
      {:error, _} -> {"error"}
    end
  rescue
    _ -> {"error"}
  end

  defp check_oban do
    case Oban.check_queue(queue: :default) do
      %{paused: _} -> {"ok"}
      _ -> {"error"}
    end
  rescue
    _ -> {"error"}
  end

  # US-32.4 config-guard: surfaces `ScaleAlerts.config_status/0` (scale alerts enabled
  # but no webhook URL configured) so a misconfigured deploy fails its readiness check
  # (`/health/ready`) instead of silently going inert. Does not affect alert DELIVERY
  # behavior for the healthy case, and — per the moduledoc — never flips the liveness
  # `status` that Fly's continuous load-balancer check acts on.
  #
  # Self-rescuing like its `check_database`/`check_oban` siblings: an unexpected raise
  # (e.g. a non-string config value reaching `ScaleAlerts.config_status/0`) must degrade
  # cleanly to an "error" check, never crash the whole endpoint into a 500.
  defp check_scale_alerts do
    case scale_alerts_config_checker().config_status() do
      :ok -> {"ok"}
      {:error, reason} -> {"error", reason}
    end
  rescue
    _ -> {"error", "scale alerts config check raised unexpectedly"}
  end

  # DI seam (Loopctl.Telemetry.ScaleAlerts.ConfigStatusBehaviour) so the degraded
  # branch above is exercisable in tests via Mox.expect/3 without `Application.put_env`.
  # Defaults to the real `ScaleAlerts` module (unchanged behavior in dev/prod).
  defp scale_alerts_config_checker,
    do: Application.get_env(:loopctl, :scale_alerts_config_checker, ScaleAlerts)

  # US-34.2 (AC-34.2.1/.3): reads the same `:executing`-older-than-N-minutes orphan
  # SIGNAL US-34.1 already polls, from the CACHED value
  # `ScaleMetrics.poll_oban_executing_orphans/0` writes to `:persistent_term` on its
  # last successful 10s poll (`ScaleMetrics.cached_executing_orphan_count/0`) —
  # NOT a fresh `Repo.transaction` + `SELECT count(*)` per call. Post-review
  # (request-amplification finding): this `check/0` backs BOTH the continuous,
  # unauthenticated `/health` liveness probe and `/health/ready`; an unauthenticated
  # caller can hit `/health` at any rate, so a per-call DB round-trip here would be
  # unbounded request-amplification pressure on the Ecto pool for a value that
  # only ever feeds `ready` (liveness `status` never consults it — see the
  # moduledoc). This mirrors the story's technical_notes, which explicitly prefer
  # reuse ("avoid a second query") over a bounded query of its own.
  #
  # `:not_yet_polled` (the brief window between app boot and the poller's first
  # tick — sub-second in practice, see `cached_executing_orphan_count/0`'s doc) is
  # treated as "ok": there is no evidence of a backlog yet, and flapping readiness
  # for that sub-second boot window would be worse than a brief false-healthy read
  # the very next poll corrects.
  #
  # Reports "degraded" when the cached count exceeds the configurable COUNT
  # threshold; below threshold it stays "ok". Folded into `ready` (readiness) ONLY
  # — see the moduledoc's "Oban orphan backlog is a READINESS signal" section on
  # why this must never flip liveness `status`.
  #
  # The reason string deliberately omits the exact count/threshold (review
  # finding: both endpoints are unauthenticated, so any internet caller could
  # otherwise read the live stuck-job count and the configured trip point off a
  # 200 OR 503 body). Operators who need the exact figures already have them via
  # the `loopctl.oban.jobs.executing_orphan.count` Prometheus gauge (metric 19,
  # `ScaleMetrics`), scraped off the internal, non-public `:9568/metrics` port —
  # not this public endpoint.
  #
  # Self-rescuing like its `check_database`/`check_oban`/`check_scale_alerts` siblings:
  # any unexpected raise (an unavailable checker) must degrade cleanly to an "error"
  # check, never crash the whole endpoint into a 500 (AC-34.2.3).
  defp check_oban_orphans do
    threshold = oban_orphan_health_threshold()

    case orphan_count_checker().cached_executing_orphan_count() do
      {:ok, count} when count > threshold ->
        {"error", "oban executing-orphan count exceeds configured threshold"}

      {:ok, _count} ->
        {"ok"}

      :not_yet_polled ->
        {"ok"}
    end
  rescue
    _ -> {"error", "oban orphan count check raised unexpectedly"}
  end

  # DI seam (Loopctl.Telemetry.ScaleMetrics.OrphanCountBehaviour) so the degraded
  # branch above is exercisable in tests via Mox.expect/3 without inserting real
  # `oban_jobs` rows or the forbidden `Application.put_env`. Defaults to the real
  # `ScaleMetrics` module (unchanged behavior in dev/prod) — the SAME process that
  # already runs `poll_oban_executing_orphans/0`, so the cache it reads is always
  # its own poller's output.
  defp orphan_count_checker,
    do: Application.get_env(:loopctl, :oban_orphan_count_checker, ScaleMetrics)

  # US-34.2 (AC-34.2.4): the configured COUNT threshold — distinct from
  # `ScaleMetrics.oban_metrics_orphan_threshold_minutes/0`'s AGE threshold, which
  # decides WHICH jobs count as orphans in the first place. This one decides HOW MANY
  # of those orphans must pile up before readiness degrades.
  defp oban_orphan_health_threshold,
    do:
      Application.get_env(
        :loopctl,
        :oban_orphan_health_threshold,
        @default_oban_orphan_health_threshold
      )

  defp app_version do
    Application.spec(:loopctl, :vsn) |> to_string()
  end

  # Only attach a `reasons.<key>` entry when a check actually failed with a reason —
  # keeps the healthy-path response shape unchanged (AC-32.4.2/3). Generalized (US-34.2)
  # to merge ANY failing check's reason under its own key without dropping a
  # previously-added one (e.g. both scale_alerts and oban_orphans can fail at once). No
  # secret is included: reason strings name only the env var (scale_alerts) or the
  # orphan count/threshold (oban_orphans).
  defp maybe_put_reason(result, key, {"error", reason}) do
    Map.update(result, :reasons, %{key => reason}, &Map.put(&1, key, reason))
  end

  defp maybe_put_reason(result, _key, _check), do: result
end
