defmodule Loopctl.ReleaseTest do
  use ExUnit.Case, async: true

  alias Loopctl.Release

  describe "migrate/0" do
    test "calls Ecto.Migrator with AdminRepo (BYPASSRLS required for RLS migrations)" do
      # Ensure the module is loaded
      Code.ensure_loaded!(Release)

      # Verify the module function exists and is accessible
      assert function_exported?(Release, :migrate, 0)

      # Inspect the source to confirm AdminRepo is used, not Repo.
      # The migrate/0 function must use AdminRepo because:
      #   - RLS policy DDL requires BYPASSRLS privilege
      #   - The regular loopctl_app role cannot create/alter RLS policies
      {:docs_v1, _, _, _, module_doc, _, _} = Code.fetch_docs(Release)

      # Module doc references AdminRepo
      assert %{"en" => doc_text} = module_doc
      assert doc_text =~ "AdminRepo"

      # Verify the source code pattern: Release.migrate/0 must reference
      # Loopctl.AdminRepo, not iterate over all ecto_repos.
      {:ok, source} = File.read("lib/loopctl/release.ex")
      assert source =~ "Loopctl.AdminRepo"

      # Ensure it does NOT use the generic repos() pattern that would
      # iterate over ecto_repos config (which only lists Repo, not AdminRepo)
      refute source =~ "for repo <- repos()"
    end
  end

  describe "rollback/1" do
    test "accepts a version argument for targeted rollback" do
      Code.ensure_loaded!(Release)
      assert function_exported?(Release, :rollback, 1)
    end
  end
end
