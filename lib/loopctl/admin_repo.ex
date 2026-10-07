defmodule Loopctl.AdminRepo do
  @moduledoc """
  Admin Ecto Repo with BYPASSRLS privilege.

  This Repo connects with a PostgreSQL role that has BYPASSRLS,
  allowing cross-tenant queries. It is used ONLY for:

  - Superadmin operations (system stats, cross-tenant queries)
  - Migrations and seeds
  - Admin operations that span multiple tenants
  - GLOBAL, non-tenant tables that must be reached cross-tenant — e.g.
    `system_configs` and the `rate_limit_counters` store behind
    `Loopctl.RateLimiter.Postgres`.

  **Never** use AdminRepo for regular tenant-scoped requests.
  The auth pipeline routes superadmin requests to this Repo
  and all other requests to the standard `Loopctl.Repo`.

  ## Hot-path caveat (US-38.2)

  One exception to "off the request hot path": when `RATE_LIMITER=postgres` is
  selected, `Loopctl.RateLimiter.Postgres.check_rate/3` issues a single
  parameterized upsert through this Repo on EVERY authenticated API request and
  every outbound provider-admission check. That is safe (the table holds no
  tenant data), but it means this pool now carries per-request load under that
  config — size and monitor it accordingly, since pool exhaustion here degrades
  the limiter to its fail-open path. Do not assume AdminRepo is off the request
  path when changing its pool sizing or connection budget.

  ## Test route: one sandbox connection with Loopctl.Repo

  `config/test.exs` sets `:admin_repo_route` to `Loopctl.Repo`, so every AdminRepo call in
  test runs on Repo's sandbox connection (`Loopctl.AdminRepo.Route`). Production is
  unrouted. Call AdminRepo's own `query/3` (or `repo.query/3` on a variable) rather than
  `Ecto.Adapters.SQL.query(Loopctl.AdminRepo, ...)`: the module-atom form looks the pool up
  directly and skips the route (`test/loopctl/admin_repo_route_test.exs` scans for it). What
  the one connection cannot show, and how a test shows it: `Loopctl.AdminRepo.Route`.
  """

  alias Loopctl.AdminRepo.Route

  @route Route.check!(
           Application.compile_env(:loopctl, :admin_repo_route, Loopctl.AdminRepo),
           Application.compile_env(:loopctl, [Loopctl.Repo, :pool])
         )

  use Ecto.Repo,
    otp_app: :loopctl,
    adapter: Ecto.Adapters.Postgres,
    prepare: :unnamed,
    default_dynamic_repo: @route

  @shares_repo_connection @route == Loopctl.Repo

  @doc """
  True when AdminRepo's calls run on `Loopctl.Repo`'s connection (the test route, see the
  moduledoc), false in production.
  """
  @spec shares_repo_connection?() :: boolean()
  def shares_repo_connection?, do: @shares_repo_connection

  # Under the route: the per-repo transaction answer, and AdminRepo's own telemetry event on
  # every call, raw `query/3` included (`Loopctl.AdminRepo.Route.__using__/1`).
  if @shares_repo_connection,
    do: use(Route, telemetry_event: [:loopctl, :admin_repo, :query])
end
