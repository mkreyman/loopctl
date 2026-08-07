defmodule Loopctl.Repo.Migrations.CreateCustodyViolations do
  use Ecto.Migration
  import Loopctl.Repo.RlsHelpers

  # L6 byzantine detection input. One row per custody-gate refusal, so the halt
  # decision is made from a PATTERN over a window rather than from a single event
  # (see Loopctl.Custody.ViolationMonitor). Durable rather than in-memory: a
  # counter that resets on every deploy would let a slow drip never accumulate,
  # and an operator investigating a halt needs the evidence that produced it.
  def change do
    create table(:custody_violations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :violation_type, :string, null: false
      add :story_id, :binary_id
      add :api_key_id, :binary_id
      add :agent_id, :binary_id
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # The detection query is always "this tenant's violations since T", so the
    # composite is the one that matters; it also keeps the count from degrading
    # into a scan as the table grows.
    create index(:custody_violations, [:tenant_id, :occurred_at])
    create index(:custody_violations, [:tenant_id, :violation_type, :occurred_at])

    enable_rls(:custody_violations)
  end
end
