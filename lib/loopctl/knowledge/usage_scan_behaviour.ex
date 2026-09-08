defmodule Loopctl.Knowledge.UsageScanBehaviour do
  @moduledoc """
  Injectable contract for the ONE heavy read `Loopctl.Knowledge.Importance` makes — the
  nightly distinct-read-day aggregate over `article_access_events` (#790).

  ## Why this behaviour exists

  `Importance.stamp/2` is FAIL-SOFT: it never raises, and it reports HOW a run ended on the
  tally's `gate` field (`:open | :heavy_read_overloaded | :scan_failed | :write_failed`).
  Three of those four are produced by the aggregate failing, and each maps a DIFFERENT
  failure shape:

    * `{:error, :heavy_read_overloaded}` — the `Loopctl.HeavyRead.TenantGate` SHED the read
      (the module asks for it as a tagged return with `on_overload: :tag`);
    * a RAISE inside the read — `:scan_failed`;
    * a non-local EXIT inside the read (a wedged or unstarted pool, which DBConnection
      reports as an exit, not an exception) — also `:scan_failed`.

  Reached through the concrete `Loopctl.HeavyRead.all/3` those three were UNTESTABLE: the
  shed needs the tenant gate over its cost cap (an `Application.get_env` the repo's test
  conventions forbid mutating), and neither a raise nor an exit can be provoked from a
  healthy sandbox connection. So the gate values existed, were logged, and were asserted
  nowhere — a fail-soft classification nothing proved was wired up.

  Injecting the read behind this behaviour lets those tests hand `measure/3` each failure
  shape directly and assert the gate value it produces, without a fake DB and without the
  suite ever entering the timed heavy-read path. This is the same seam
  `Loopctl.Knowledge.SimilaritySearchBehaviour` cuts for `ArticleLinkingWorker`, for the
  same reason.

  ## Implementations

    * Production/dev — `Loopctl.Knowledge.UsageScan` (delegates to `Loopctl.HeavyRead`;
      the default, so no config key is required to run the real thing).
    * Test — `Loopctl.MockKnowledgeUsageScan` (a Mox mock; wired via `config/test.exs`).
      The `Loopctl.DataCase` default stub DELEGATES to `Loopctl.Knowledge.UsageScan`, so
      every existing test still runs the real aggregate against real event rows and only
      the gate tests override it.

  Resolved by `Importance` with config-based DI:
  `Application.get_env(:loopctl, :knowledge_usage_scan, Loopctl.Knowledge.UsageScan)`.
  """

  @doc """
  Runs `queryable` as a heavy read scoped to `tenant_id`, exactly as
  `Loopctl.HeavyRead.all/3` does — same guard, same per-read `SET LOCAL statement_timeout`,
  same `Loopctl.HeavyRead.TenantGate`.

  Returns the rows, or `{:error, :heavy_read_overloaded}` when the caller passed
  `on_overload: :tag` and the gate shed the read. It may also RAISE or EXIT: the caller's
  `rescue`/`catch` is what turns those into `:scan_failed`, and an implementation must not
  swallow them into an empty list — an empty list is "nobody read anything", which
  `Importance` acts on by CLEARING the whole tenant's counts.
  """
  @callback all(
              tenant_id :: binary(),
              queryable :: Ecto.Queryable.t(),
              opts :: keyword()
            ) :: [term()] | {:error, :heavy_read_overloaded}
end
