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

  describe "migration_connection_opts/0" do
    test "sets a Postgres runtime parameter the server actually honours" do
      assert [parameters: [idle_in_transaction_session_timeout: "0"]] =
               Release.migration_connection_opts()
    end

    test "the parameter name and shape reach the server (not just the keyword list)" do
      # The failure this guards is a WRONG OPTION rather than a wrong value: a misspelled
      # parameter, or `parameters:` nested at the wrong level, is silently ignored by
      # Postgrex and the migrator keeps dying on long migrations exactly as before. So the
      # assertion is end-to-end against a real connection.
      #
      # A PROBE value is used rather than the shipped "0" because the server's own default
      # differs by environment — 0 on a developer box, 60000ms on the hosted instance — so
      # asserting "0" would pass vacuously wherever the default is already 0.
      config = Application.get_env(:loopctl, Loopctl.AdminRepo)

      conn_opts = [
        hostname: config[:hostname] || "127.0.0.1",
        port: config[:port] || 5432,
        username: config[:username],
        password: config[:password],
        database: config[:database],
        parameters: [idle_in_transaction_session_timeout: "12345"],
        queue_target: 2_000,
        queue_interval: 5_000,
        connect_timeout: 10_000,
        timeout: 10_000
      ]

      # RETRIED, because this test opens its OWN connection outside the sandbox pools and
      # therefore asks the server for one more at the exact moment the suite is holding the
      # most: three repos' pools plus Oban's notifier, and on this box a second project's
      # suite besides. `too_many_clients` there is a property of when the test runs, not of
      # what it asserts — it passed alone and failed in `mix precommit` repeatedly, which is
      # the worst shape of flake because the failure names a change that did not cause it.
      #
      # Waiting longer alone did NOT fix it (30s deadlines still expired), so the retry is
      # the fix: the pressure is transient and a few seconds later there is room.
      #
      # `start_link` LINKS the connection to this test process, so it is torn down when the
      # test ends — no `on_exit` teardown, and no leaked connection making the next run's
      # exhaustion slightly likelier.
      assert %{rows: [["12345ms"]]} = show_timeout_with_retry(conn_opts, 5)
    end

    defp show_timeout_with_retry(conn_opts, attempts_left) do
      {:ok, conn} = Postgrex.start_link(conn_opts)
      Postgrex.query!(conn, "SHOW idle_in_transaction_session_timeout", [], timeout: 10_000)
    rescue
      error in [DBConnection.ConnectionError, Postgrex.Error] ->
        if attempts_left > 1 do
          Process.sleep(1_000)
          show_timeout_with_retry(conn_opts, attempts_left - 1)
        else
          reraise error, __STACKTRACE__
        end
    end

    test "both migrate/0 and rollback/1 pass it, so a long DOWN cannot fail the same way" do
      source = File.read!("lib/loopctl/release.ex")

      # `Ecto.Migrator` holds its advisory lock idle-in-transaction for the whole run in
      # either direction. Migration 20260817212906's UP took 59.8s against a 60000ms
      # timeout and killed the release command 0.2s from the finish; its DOWN rebuilds the
      # same generated column and would do exactly the same thing.
      assert source
             |> String.split("migration_connection_opts()")
             |> length() >= 4,
             "migrate/0 and rollback/1 must both pass migration_connection_opts/0"
    end
  end

  describe "rollback/1" do
    test "accepts a version argument for targeted rollback" do
      Code.ensure_loaded!(Release)
      assert function_exported?(Release, :rollback, 1)
    end
  end
end
