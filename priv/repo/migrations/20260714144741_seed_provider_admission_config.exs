defmodule Loopctl.Repo.Migrations.SeedProviderAdmissionConfig do
  use Ecto.Migration

  # US-37.1 (#352): per-(tenant, provider) token-bucket admission gate knobs.
  #
  # These rows make the node-local admission ceilings operator-visible and
  # live-tunable (no deploy). A missing row makes SystemConfig.get_int/2 fall back
  # to the in-code default in Loopctl.Provider.Admission (safe degrade), so seeding
  # here only mirrors those defaults into the DB from day one:
  #
  #   * provider_admission_embedding_rpm  -> 600 req/node/min (default)
  #   * provider_admission_anthropic_rpm  -> 300 req/node/min (default)
  #   * provider_admission_snooze_seconds ->   5 s base snooze for gated embed jobs
  #
  # Node-local by design (cluster-wide bucket is Epic 38); the effective fleet
  # ceiling is rpm * node_count. `now() AT TIME ZONE 'UTC'` matches the
  # :utc_datetime_usec columns; ON CONFLICT keeps re-runs safe.

  def change do
    execute(
      """
      INSERT INTO system_configs (id, key, value, description, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 'provider_admission_embedding_rpm', 600,
          'Node-local per-tenant embedding-provider admission ceiling (requests/min)',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC'),
        (gen_random_uuid(), 'provider_admission_anthropic_rpm', 300,
          'Node-local per-tenant Anthropic-provider admission ceiling (requests/min)',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC'),
        (gen_random_uuid(), 'provider_admission_snooze_seconds', 5,
          'Base snooze (s) for embed jobs gated by the node-local admission bucket',
          now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC')
      ON CONFLICT (key) DO NOTHING
      """,
      """
      DELETE FROM system_configs
      WHERE key IN (
        'provider_admission_embedding_rpm',
        'provider_admission_anthropic_rpm',
        'provider_admission_snooze_seconds'
      )
      """
    )
  end
end
