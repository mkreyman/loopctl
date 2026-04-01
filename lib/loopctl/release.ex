defmodule Loopctl.Release do
  @moduledoc """
  Release tasks for running migrations in production.

  Uses `Loopctl.AdminRepo` (BYPASSRLS role) because RLS policy
  migrations require elevated privileges that the regular app role
  does not have.

  Used by the release migrate script:

      bin/loopctl eval "Loopctl.Release.migrate()"

  Or via Fly.io release_command:

      /app/bin/migrate
  """

  @app :loopctl

  @doc """
  Runs all pending Ecto migrations using AdminRepo.

  AdminRepo connects with the BYPASSRLS role, which is required
  because RLS policy DDL statements fail under a restricted role.
  """
  def migrate do
    load_app()

    # Run migrations from priv/repo/migrations/ using AdminRepo.
    # AdminRepo has BYPASSRLS privilege needed for RLS policy DDL.
    # We specify the path explicitly because AdminRepo defaults to
    # priv/admin_repo/migrations/ but all migrations live in priv/repo/.
    {:ok, _, _} =
      Ecto.Migrator.with_repo(Loopctl.AdminRepo, fn repo ->
        path = Ecto.Migrator.migrations_path(Loopctl.Repo)
        Ecto.Migrator.run(repo, path, :up, all: true)
      end)
  end

  @doc """
  Rolls back the last migration using AdminRepo.
  """
  def rollback(version) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Loopctl.AdminRepo, fn repo ->
        path = Ecto.Migrator.migrations_path(Loopctl.Repo)
        Ecto.Migrator.run(repo, path, :down, to: version)
      end)
  end

  defp load_app do
    Application.load(@app)
  end
end
