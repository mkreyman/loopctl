defmodule Loopctl.AdminRepo do
  @moduledoc """
  Admin Ecto Repo with BYPASSRLS privilege.

  This Repo connects with a PostgreSQL role that has BYPASSRLS,
  allowing cross-tenant queries. It is used ONLY for:

  - Superadmin operations (system stats, cross-tenant queries)
  - Migrations and seeds
  - Admin operations that span multiple tenants

  **Never** use AdminRepo for regular tenant-scoped requests.
  The auth pipeline routes superadmin requests to this Repo
  and all other requests to the standard `Loopctl.Repo`.
  """

  use Ecto.Repo,
    otp_app: :loopctl,
    adapter: Ecto.Adapters.Postgres
end
