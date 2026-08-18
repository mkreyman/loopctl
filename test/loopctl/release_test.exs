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
    test "is an after_connect SET, not an option Ecto.Migrator would discard" do
      # `Ecto.Migrator.with_repo/3` reads only `:mode` and `:pool_size` out of its opts and
      # starts the repo with `repo.start_link(pool_size: pool_size)`, so a `parameters:`
      # keyword handed to it never reaches Postgrex. The setting therefore lives on the repo
      # CONFIG the migrator starts from, applied as a plain `SET` once the connection is up
      # (which is also what pgbouncer accepts — it refuses unknown STARTUP parameters with
      # 08P01).
      assert [after_connect: {Postgrex, :query!, [sql, []]}] =
               Release.migration_connection_opts()

      assert sql =~ ~r/^SET idle_in_transaction_session_timeout = 0$/
    end

    test "the merge puts it where the migrator reads the repo config from" do
      # The delivery, which asserting on `migration_connection_opts/0` alone cannot see:
      # `Ecto.Migrator.with_repo/3` starts the repo from its APPLICATION CONFIG, so the
      # option has to survive the merge onto AdminRepo's own config — and must not drop the
      # keys (url, pool_size) without which the migrator cannot connect at all.
      merged = Release.migration_repo_config(url: "postgres://example", pool_size: 2)

      assert merged[:url] == "postgres://example"
      assert merged[:pool_size] == 2
      assert merged[:after_connect] == Release.migration_connection_opts()[:after_connect]
    end

    test "the option it carries actually clears the timeout on a real connection" do
      # End-to-end against the server, THROUGH the delivery mechanism: the opts are handed
      # to the connection as `after_connect` (what a repo started from this config does)
      # rather than run by hand, so a shape Postgrex would not honour fails here.
      #
      # Non-vacuity is bought by the second connection: it runs the same mechanism with a
      # non-zero probe, so `after_connect` being ignored entirely would show the server
      # default (0 on a developer box, 60000ms on the hosted instance) instead of 12345 and
      # fail. Without it, an ignored `after_connect` on a box whose default is already 0
      # would read as a pass.
      config = Application.get_env(:loopctl, Loopctl.AdminRepo)

      conn_opts = [
        hostname: config[:hostname] || "127.0.0.1",
        port: config[:port] || 5432,
        username: config[:username],
        password: config[:password],
        database: config[:database],
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
      after_connect = Keyword.fetch!(Release.migration_repo_config(conn_opts), :after_connect)

      assert %{rows: [["0"]]} =
               show_timeout_with_retry(Keyword.put(conn_opts, :after_connect, after_connect), 5)

      probe = {Postgrex, :query!, ["SET idle_in_transaction_session_timeout = 12345", []]}

      assert %{rows: [["12345ms"]]} =
               show_timeout_with_retry(Keyword.put(conn_opts, :after_connect, probe), 5)
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

    test "both migrate/0 and rollback/1 apply it, so a long DOWN cannot fail the same way" do
      source = File.read!("lib/loopctl/release.ex")

      # `Ecto.Migrator` holds its advisory lock idle-in-transaction for the whole run in
      # either direction. Migration 20260817212906's UP took 59.8s against a 60000ms
      # timeout and killed the release command 0.2s from the finish; its DOWN rebuilds the
      # same generated column and would do exactly the same thing.
      # Two CALL sites (the definition is arity-0 and written without parens), so the split
      # has three parts.
      assert source
             |> String.split("configure_migration_connections()")
             |> length() >= 3,
             "migrate/0 and rollback/1 must both call configure_migration_connections/0"
    end
  end

  describe "rollback/1" do
    test "accepts a version argument for targeted rollback" do
      Code.ensure_loaded!(Release)
      assert function_exported?(Release, :rollback, 1)
    end
  end
end
