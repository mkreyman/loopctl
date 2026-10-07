defmodule Loopctl.AdminRepoRouteTest do
  @moduledoc """
  `Loopctl.AdminRepo` runs on `Loopctl.Repo`'s sandbox connection in test, never in
  production (`Loopctl.AdminRepo.Route`, `config :loopctl, :admin_repo_route`).

  Three things hold that up, one describe each: the compile-time guard that keeps the route
  out of a non-sandbox build, the route actually being live in this suite, and the source
  scans that keep `lib/` from reaching AdminRepo in a way the route does not follow.
  """

  use Loopctl.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias Loopctl.AdminRepo
  alias Loopctl.AdminRepo.Route
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant

  describe "Route.check!/2, the compile-time guard" do
    test "AdminRepo's own pool is allowed whatever Repo's pool is" do
      assert Route.check!(AdminRepo, DBConnection.ConnectionPool) == AdminRepo
      assert Route.check!(AdminRepo, nil) == AdminRepo
      assert Route.check!(AdminRepo, Ecto.Adapters.SQL.Sandbox) == AdminRepo
    end

    test "Repo's connection is allowed only while Repo's pool is the SQL sandbox" do
      assert Route.check!(Repo, Ecto.Adapters.SQL.Sandbox) == Repo

      for pool <- [nil, DBConnection.ConnectionPool] do
        assert_raise ArgumentError, ~r/only Loopctl.AdminRepo .* is allowed/i, fn ->
          Route.check!(Repo, pool)
        end
      end
    end

    test "any other route is refused" do
      assert_raise ArgumentError, fn ->
        Route.check!(Loopctl.HeavyReadRepo, Ecto.Adapters.SQL.Sandbox)
      end
    end
  end

  describe "the route in this suite" do
    test "AdminRepo and Repo run on one connection" do
      assert AdminRepo.shares_repo_connection?()
      assert backend_pid(AdminRepo) == backend_pid(Repo)
    end

    test "a row Repo writes inside the test's transaction is visible to AdminRepo" do
      # Written through Repo on purpose: `fixture(:tenant)` inserts through AdminRepo, which
      # would see its own row on a connection of its own too.
      tenant =
        %Tenant{}
        |> Tenant.create_changeset(build(:tenant, %{}))
        |> Repo.insert!()

      assert AdminRepo.get(Tenant, tenant.id)
    end

    test "each repo's in_transaction?/0 answers for its own transactions, as in production" do
      refute AdminRepo.in_transaction?()
      refute Repo.in_transaction?()

      assert {:ok, {true, false}} =
               AdminRepo.transaction(fn ->
                 {AdminRepo.in_transaction?(), Repo.in_transaction?()}
               end)

      assert {:ok, {false, true}} =
               Repo.transaction(fn -> {AdminRepo.in_transaction?(), Repo.in_transaction?()} end)

      assert {:ok, {:ok, {true, true}}} =
               Repo.transaction(fn ->
                 AdminRepo.transaction(fn ->
                   {AdminRepo.in_transaction?(), Repo.in_transaction?()}
                 end)
               end)

      # A raise and a rollback both close the count.
      assert_raise RuntimeError, fn -> AdminRepo.transaction(fn -> raise "boom" end) end
      assert {:error, :no} = AdminRepo.transaction(fn -> AdminRepo.rollback(:no) end)

      assert {:error, :step, :no, %{}} =
               Ecto.Multi.new()
               |> Ecto.Multi.run(:step, fn _repo, _ -> {:error, :no} end)
               |> AdminRepo.transaction()

      refute AdminRepo.in_transaction?()
      refute Repo.in_transaction?()
    end

    test "connection_in_transaction?/1 answers for the connection, whichever repo opened it" do
      refute Route.connection_in_transaction?(AdminRepo)

      assert {:ok, {true, false}} =
               Repo.transaction(fn ->
                 {Route.connection_in_transaction?(AdminRepo), AdminRepo.in_transaction?()}
               end)

      assert {:ok, {true, false}} =
               AdminRepo.transaction(fn ->
                 {Route.connection_in_transaction?(Repo), Repo.in_transaction?()}
               end)
    end

    test "a with_tenant raise inside an AdminRepo transaction fails that transaction, then nothing is left" do
      # Under the route the tenant transaction NESTS in the AdminRepo one (one connection), and
      # a raise through a nested transaction fails the whole of it: the AdminRepo transaction
      # cannot run another statement, so the tenant's SET LOCAL ROLE never reaches a
      # BYPASSRLS read, and the rollback reverts it. Production differs: there the tenant
      # transaction is on Repo's own connection and the AdminRepo one carries on
      # (`Loopctl.AdminRepo.Route`, "What the shared connection cannot show").
      tenant = fixture(:tenant)

      assert {:error, :rollback} =
               AdminRepo.transaction(fn ->
                 assert_raise RuntimeError, fn ->
                   Repo.with_tenant(tenant.id, fn -> raise "body failed" end)
                 end

                 assert_raise DBConnection.ConnectionError, ~r/transaction rolling back/, fn ->
                   AdminRepo.query!("SELECT 1")
                 end
               end)

      %{rows: [[user, tenant_setting]]} =
        AdminRepo.query!("SELECT current_user, current_setting('app.current_tenant_id', true)")

      refute user == Application.fetch_env!(:loopctl, :rls_role)
      assert tenant_setting in [nil, ""]
    end

    test "a module-atom call that skips the route fails on ownership instead of committing" do
      # test_helper.exs keeps AdminRepo's own pool in :manual; its default (:auto) would hand
      # this call an unsandboxed connection, and a write through it would commit.
      assert_raise DBConnection.OwnershipError, fn ->
        SQL.query!(AdminRepo, "SELECT 1")
      end
    end
  end

  describe "lib/ reaches AdminRepo only through the route" do
    test "every Ecto.Adapters.SQL call in lib/ names Loopctl.Repo, never a repo it is handed" do
      calls = sql_calls()

      # Not vacuous: the scan must see the calls it allows, or it is blind rather than clean.
      assert Enum.any?(calls, &match?({"lib/loopctl/repo.ex", _, "__MODULE__"}, &1))

      offenders =
        for {path, line, first} <- calls,
            not allowed_first_arg?(path, first),
            do: "#{path}:#{line} first argument #{first}"

      assert offenders == [],
             "Ecto.Adapters.SQL.query/stream/explain take the repo MODULE and look its pool up " <>
               "directly, skipping AdminRepo's test route onto Repo's connection (US-46.2). " <>
               "Call the repo's own function instead (`repo.query(sql, params, opts)`), which " <>
               "is identical in production:\n" <> Enum.join(offenders, "\n")
    end

    test "test/ names no AdminRepo in an Ecto.Adapters.SQL call either" do
      # Not a production risk, but in this suite such a call reaches AdminRepo's own pool,
      # which no test owns, and fails on ownership far from the reason. This module is exempt:
      # one of its tests makes the call on purpose.
      paths = Path.wildcard("test/**/*.{ex,exs}") -- ["test/loopctl/admin_repo_route_test.exs"]
      calls = sql_calls(paths)

      assert Enum.any?(calls, fn {_path, _line, first} -> first in ["Repo", "Loopctl.Repo"] end)

      offenders =
        for {path, line, first} <- calls,
            first in ["AdminRepo", "Loopctl.AdminRepo"],
            do: "#{path}:#{line}"

      assert offenders == [], "call `AdminRepo.query/3` instead:\n" <> Enum.join(offenders, "\n")
    end

    test "nothing in lib/ imports Ecto.Adapters.SQL or aliases it under another name" do
      # Either would hide a call from the scan above, which matches `SQL.<fun>` by name.
      offenders =
        for path <- lib_files(),
            {kind, line} <- sql_import_or_rename(path),
            do: "#{path}:#{line} #{kind}"

      assert offenders == []
    end

    test "nothing in lib/ sets a dynamic repo" do
      # The test route is a compile-time default. A runtime `put_dynamic_repo/1` would be a
      # per-process lever on which connection a custody read uses, reachable from production.
      offenders =
        for path <- lib_files(),
            line <- calls_named(Code.string_to_quoted!(File.read!(path)), :put_dynamic_repo),
            do: "#{path}:#{line}"

      assert offenders == []
    end

    test "no Sandbox call names AdminRepo outside Loopctl.Test.ProductionTopology" do
      # `Ecto.Adapters.SQL.Sandbox` resolves a repo atom through `get_dynamic_repo/0`, so a
      # call naming AdminRepo acts on REPO's pool under the route: `mode(AdminRepo, :auto)`
      # flips Repo's, a second `start_owner!` double-owns Repo's. Name Loopctl.Repo for that
      # pool; AdminRepo's own pool is reached through the topology helper.
      found =
        for path <- Path.wildcard("{lib,test}/**/*.{ex,exs}"),
            path != "test/support/production_topology.ex",
            line <- sandbox_admin_calls(Code.string_to_quoted!(File.read!(path))),
            do: "#{path}:#{line}"

      assert found == []
    end

    test "in test/, only Loopctl.Test.ProductionTopology moves AdminRepo off the route" do
      # Any other per-test swap is the manipulated global the DI rule forbids. The one other
      # call points AdminRepo at a repo that was never started, to make a read fail without
      # a database, and changes no connection.
      allowed = %{
        "test/support/production_topology.ex" => 1,
        "test/loopctl/telemetry/scale_metrics_test.exs" => 1
      }

      found =
        for path <- Path.wildcard("test/**/*.{ex,exs}"),
            path != "test/loopctl/admin_repo_route_test.exs",
            lines = calls_named(Code.string_to_quoted!(File.read!(path)), :put_dynamic_repo),
            lines != [],
            into: %{},
            do: {path, length(lines)}

      assert found == allowed
    end
  end

  defp backend_pid(repo) do
    %{rows: [[pid]]} = repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp lib_files, do: Path.wildcard("lib/**/*.ex")

  @admin_repo_names ["AdminRepo", "Loopctl.AdminRepo"]

  @sql_functions ~w(query query! query_many query_many! stream explain table_exists? disconnect_all)a

  # `{path, line, first_argument_source}` for every call to an `Ecto.Adapters.SQL` function, a
  # piped call's left-hand side counted as its first argument.
  defp sql_calls(paths \\ lib_files()) do
    for path <- paths,
        {line, first} <- sql_calls_in(Code.string_to_quoted!(File.read!(path))),
        do: {path, line, first}
  end

  defp sql_calls_in(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:|>, _, [lhs, {{:., _, [mod, fun]}, meta, _args}]} = node, acc ->
          if sql_call?(mod, fun),
            do: {skip_piped(node), [{meta[:line], Macro.to_string(lhs)} | acc]},
            else: {node, acc}

        {{:., _, [mod, fun]}, meta, [first | _]} = node, acc ->
          if sql_call?(mod, fun),
            do: {node, [{meta[:line], Macro.to_string(first)} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # The piped call is recorded with its left-hand side; walk on into both halves without
  # visiting the call node again (where its first ARGUMENT would be the second parameter).
  defp skip_piped({:|>, meta, [lhs, {call, call_meta, args}]}),
    do: {:|>, meta, [lhs, {:__piped__, call_meta, [call | args]}]}

  defp sql_call?({:__aliases__, _, parts}, fun),
    do: List.last(parts) == :SQL and fun in @sql_functions

  defp sql_call?(_mod, _fun), do: false

  defp allowed_first_arg?("lib/loopctl/repo.ex", "__MODULE__"), do: true
  defp allowed_first_arg?(_path, first), do: first in ["Loopctl.Repo", "Repo"]

  defp sql_import_or_rename(path) do
    {_, acc} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:import, meta, [{:__aliases__, _, [:Ecto, :Adapters, :SQL]} | _]} = node, acc ->
          {node, [{"import", meta[:line]} | acc]}

        {:alias, meta, [{:__aliases__, _, [:Ecto, :Adapters, :SQL]}, opts]} = node, acc
        when is_list(opts) ->
          if Keyword.has_key?(opts, :as),
            do: {node, [{"alias as", meta[:line]} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp sandbox_admin_calls(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, parts}, _fun]}, meta, [first | _]} = node, acc ->
          if List.last(parts) == :Sandbox and Macro.to_string(first) in @admin_repo_names,
            do: {node, [meta[:line] | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp calls_named(ast, name) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [_mod, ^name]}, meta, _args} = node, acc -> {node, [meta[:line] | acc]}
        {^name, meta, args} = node, acc when is_list(args) -> {node, [meta[:line] | acc]}
        node, acc -> {node, acc}
      end)

    acc
  end
end
