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
  """

  use Ecto.Repo,
    otp_app: :loopctl,
    adapter: Ecto.Adapters.Postgres,
    prepare: :unnamed
end
