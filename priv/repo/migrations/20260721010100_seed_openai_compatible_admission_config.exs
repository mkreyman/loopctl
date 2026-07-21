defmodule Loopctl.Repo.Migrations.SeedOpenaiCompatibleAdmissionConfig do
  use Ecto.Migration

  # US-41.3 (AC-41.3.5): adding a provider to `Loopctl.Provider.Admission` is TWO
  # coordinated edits plus this seed. The atom joins the fixed `@providers` list AND
  # gets a `limit_for/1` clause; without the clause the `check_rate` call raises a
  # FunctionClauseError inside the try body and the fail-open rescue converts it to
  # `:ok` — a provider with NO rate limit at exactly the call site the US-41.4
  # egress guard sits beside.
  #
  # A missing row makes SystemConfig.get_int/2 fall back to the in-code default
  # (safe degrade), so seeding only mirrors that default into the DB from day one.
  #
  # The limit is a SINGLE GLOBAL value shared by every tenant-supplied local
  # endpoint (the bucket KEY still isolates each tenant's count). That is
  # INTENTIONAL for v1 and documented in `Loopctl.Provider.Admission`: tenants with
  # very different local hardware share one RPM ceiling.

  def change do
    execute(
      """
      INSERT INTO system_configs (id, key, value, description, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 'provider_admission_openai_compatible_rpm', 300,
          'Node-local per-tenant OpenAI-compatible chat admission ceiling (requests/min)',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC')
      ON CONFLICT (key) DO NOTHING
      """,
      """
      DELETE FROM system_configs
      WHERE key = 'provider_admission_openai_compatible_rpm'
      """
    )
  end
end
