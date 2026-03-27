defmodule Loopctl.Repo.RlsTestRecord do
  @moduledoc """
  Schema for the rls_test_records table, used exclusively in integration tests
  to verify RLS policy enforcement.

  This table has RLS enabled with a tenant_isolation policy. It exists
  so tests can insert records via different tenant contexts and verify isolation.
  """

  use Loopctl.Schema, soft_delete: true

  schema "rls_test_records" do
    tenant_field()
    field :name, :string
    field :deleted_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> Ecto.Changeset.cast(attrs, [:name])
    |> Ecto.Changeset.validate_required([:name])
  end
end
