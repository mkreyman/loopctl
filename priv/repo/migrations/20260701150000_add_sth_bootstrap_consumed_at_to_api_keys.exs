defmodule Loopctl.Repo.Migrations.AddSthBootstrapConsumedAtToApiKeys do
  use Ecto.Migration

  # US-26.5.2 / custody-03 (GHSA-36g5-mcrh-rcrm): the STH witness bootstrap grace
  # must be one-time per API key. Record when a key consumed its grace so the
  # ValidateWitnessHeader plug can reject a second bootstrap request.
  #
  # `api_keys` already has RLS (ENABLE + FORCE) with a tenant_isolation policy;
  # adding a nullable column does not alter that, and we intentionally leave the
  # existing policy untouched.
  def change do
    alter table(:api_keys) do
      add :sth_bootstrap_consumed_at, :utc_datetime_usec
    end
  end
end
