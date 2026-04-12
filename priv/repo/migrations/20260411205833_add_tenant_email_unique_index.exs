defmodule Loopctl.Repo.Migrations.AddTenantEmailUniqueIndex do
  @moduledoc """
  US-26.0.1 — enforces unique tenant contact emails.

  The signup ceremony requires a stable `email_taken` error code when a
  would-be tenant reuses an email already on file.
  """

  use Ecto.Migration

  def change do
    create unique_index(:tenants, [:email], name: :tenants_email_index)
  end
end
