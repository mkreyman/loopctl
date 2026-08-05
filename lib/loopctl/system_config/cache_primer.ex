defmodule Loopctl.SystemConfig.CachePrimer do
  @moduledoc """
  Supervised ONE-SHOT child that primes the `Loopctl.SystemConfig`
  `:persistent_term` cache from the DB at boot, BEFORE any consumer of that cache
  is started (GH #588).

  ## Why a supervision child and not a post-boot call

  A supervisor starts its children synchronously, in list order, so a child's
  position in `Loopctl.Application.children/0` IS the ordering guarantee. Priming
  after `Supervisor.start_link/2` returns (what this replaced) left a window in
  which `LoopctlWeb.Endpoint` and `Oban` already served work against an EMPTY
  cache — and `SystemConfig.get_int/2` answers a miss with the caller's in-code
  default, which for the embeddings read-routing flag is the RETIRED legacy
  column. Every boot silently reverted a completed cutover for the length of that
  window.

  The prime therefore runs to completion INSIDE `start_link/1`. It must NOT be a
  `Task` child or a `handle_continue/2`: both return to the supervisor
  immediately, so the next child (the consumer) starts while the prime is still
  in flight — which is exactly the bug this module closes.

  Having primed, `start_link/1` returns `:ignore` — no process is left running.
  The per-minute `Loopctl.Workers.SystemConfigRefreshWorker` owns the ongoing
  refresh cadence; this child must never poll or re-prime on a timer, because a
  `:persistent_term.put/2` triggers a global GC scan across all processes. The
  child spec declares `restart: :transient` (NOT `:temporary`) so the supervisor
  RETAINS the spec after `:ignore` and the child stays visible in
  `Supervisor.which_children/1` with pid `:undefined`.

  ## Failure is loud, never fatal

  A failed prime is logged at `:error` and emitted as
  `[:loopctl, :system_config, :prime_failed]` telemetry — which
  `Loopctl.Telemetry.ScaleMetrics.scale_metrics/0` consumes as the
  `loopctl.system_config.prime_failed.count` Prometheus counter (metric 25), keyed by
  the classified `error_class`. An emitted event with no metric definition would be a
  handler-less no-op, leaving the log line as the only trace — not alertable, and easy
  to miss on a rolling deploy. Telemetry is claimed here because a silently empty
  cache is what turns a bounded startup window into an unbounded one (a node that
  missed its prime keeps serving in-code defaults until a cron tick happens to
  land on it — and the cron enqueues one job per tick CLUSTER-WIDE).

  It does NOT raise. Every other boot-time check in `Loopctl.Application` is
  log-only, and crashing every deploy on a transient DB blip is a worse failure
  than the one being fixed: boot proceeds on the in-code defaults, exactly as it
  did before this child existed.

  That guarantee rests entirely on `SystemConfig.refresh/0` returning rather than
  escaping, for EVERY fault shape — which is why its guard catches exits and
  throws as well as raises. A DB pool that is unstarted, wedged, or dying
  mid-query EXITS; a `rescue`-only guard would let that exit escape into
  `start_link/1`, and a supervisor converts an exiting child start into
  `{:error, {:shutdown, {:failed_to_start_child, ...}}}` — so the node would fail
  to boot on precisely the "DB blip at boot" scenario this section promises to
  survive.
  """

  require Logger

  alias Loopctl.ExitClass
  alias Loopctl.SystemConfig

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      # NOT :temporary — a :temporary child that returns :ignore has its spec
      # DISCARDED, which would hide this child from Supervisor.which_children/1.
      restart: :transient
    }
  end

  @doc """
  Primes the `SystemConfig` cache synchronously and returns `:ignore`.

  Always returns `:ignore` — including when the prime fails, which is reported
  via `Logger.error/1` and `[:loopctl, :system_config, :prime_failed]` telemetry
  rather than by aborting boot.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(_opts \\ []) do
    case SystemConfig.refresh() do
      :ok ->
        :ignore

      {:error, reason} ->
        class = error_class(reason)

        Logger.error(
          "Loopctl.SystemConfig.CachePrimer: boot prime FAILED; this node serves in-code " <>
            "defaults (for the embeddings read flag that is the LEGACY column) until a " <>
            "SystemConfigRefreshWorker tick lands on it: error_class=#{class}"
        )

        :telemetry.execute(
          [:loopctl, :system_config, :prime_failed],
          %{count: 1},
          %{error_class: class}
        )

        :ignore
    end
  end

  @doc false
  # Public ONLY as a seam for this classifier's own tests (the same reason
  # `SystemConfig.refresh_from/1` is): the test database always answers `AdminRepo.all/1`,
  # so the EXIT shape — the one whose raw reason actually carries a payload — cannot be
  # driven through `start_link/1` at all, and left private the clause that sanitizes it
  # would be unexercised.
  #
  # `refresh_from/1` returns TWO error shapes, and BOTH reach a log line and telemetry
  # metadata here, so both are reduced to the bounded class first: an exit reason carries
  # the DBConnection checkout tuple, which on the crash-propagation shape carries the
  # failing statement and its bound parameters (#562), and an inspected Postgrex /
  # DBConnection struct names the backend host, database and role (`ExitTag`). Emitting
  # the raw term one frame up would undo the sanitization `refresh_from/1`'s guard exists
  # to perform.
  @spec error_class(term()) :: String.t()
  def error_class({kind, reason}) when kind in [:exit, :throw],
    do: ExitClass.classify(kind, reason)

  def error_class(e) when is_exception(e), do: ExitClass.classify(:raise, e)

  # An unforeseen shape must not raise: a FunctionClauseError here would escape
  # `start_link/1`, and a supervisor converts an exiting child start into a failed boot —
  # the exact outcome "a failed prime NEVER blocks boot" promises to avoid.
  def error_class(_reason), do: "unclassified"
end
