defmodule Loopctl.ReplicaReadConfigTest do
  @moduledoc """
  US-38.1 write-safety wiring guard (AC-38.1.2): the `REPLICA_DATABASE_URL` read DSN may
  ONLY back `Loopctl.HeavyReadRepo`. It must NEVER be routed to a WRITE repo
  (`Loopctl.Repo` / `Loopctl.AdminRepo`).

  ## Why an AST scan of runtime.exs

  `config/runtime.exs` is prod-only and is NOT reflected by `Application.get_env` during
  `mix test`, so we assert the WIRING by parsing the config source (same approach as the
  pgbouncer-safety guard). This proves, without a live replica, that:

    * HeavyReadRepo's `url:` is `replica_database_url` (the resolved read DSN), and
    * Repo's `url:` is `database_url` and AdminRepo's `url:` is `admin_database_url`
      (both PRIMARY — the replica DSN never reaches a write repo), and
    * `replica_database_url` is resolved through `Loopctl.DbCapacity.resolve_replica_url/2`
      (REPLICA_DATABASE_URL || admin_database_url — defaults off).

  "No write ever reaches HeavyReadRepo/the replica" is covered structurally by
  `heavy_read_guard_test.exs` (only `Loopctl.HeavyRead` may touch HeavyReadRepo, and it is
  read-only) — this guard is the complementary half: the replica DSN never backs a writer.
  """
  use ExUnit.Case, async: true

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)

  setup_all do
    {:ok, ast} = @runtime_config |> File.read!() |> Code.string_to_quoted()
    %{ast: ast, url_vars: repo_url_vars(ast)}
  end

  test "HeavyReadRepo's url is the resolved replica_database_url", %{url_vars: vars} do
    assert vars[Loopctl.HeavyReadRepo] == :replica_database_url
  end

  test "Repo and AdminRepo urls are PRIMARY DSNs (replica DSN never backs a writer)", %{
    url_vars: vars
  } do
    assert vars[Loopctl.Repo] == :database_url
    assert vars[Loopctl.AdminRepo] == :admin_database_url
    # The replica DSN variable is bound to no write repo.
    refute vars[Loopctl.Repo] == :replica_database_url
    refute vars[Loopctl.AdminRepo] == :replica_database_url
  end

  test "replica_database_url is resolved via DbCapacity.resolve_replica_url/2 (defaults off)",
       %{ast: ast} do
    assert resolves_replica_url_via_dbcapacity?(ast),
           "expected `replica_database_url = Loopctl.DbCapacity.resolve_replica_url(...)` in runtime.exs"
  end

  test "TC-38.1.4: HeavyRead's public surface exposes no DIRECT write functions" do
    # The replica DSN can only be reached through Loopctl.HeavyRead (heavy_read_guard_test.exs).
    # HeavyRead exposes no direct write function (insert/update/delete/...), so a caller cannot
    # name a write on the wrapper. A write path must go via Repo/AdminRepo (the primary).
    exported = Loopctl.HeavyRead.__info__(:functions) |> Keyword.keys() |> Enum.uniq()

    write_ops =
      Enum.filter(exported, fn name ->
        name in [
          :insert,
          :insert!,
          :update,
          :update!,
          :delete,
          :delete!,
          :insert_all,
          :insert_or_update
        ]
      end)

    assert write_ops == [],
           "Loopctl.HeavyRead must expose no direct write operations (it backs the replica DSN); found: " <>
             inspect(write_ops)
  end

  test "TC-38.1.4: replica write-safety is TWO-LAYERED — honest about the transaction/2 lever" do
    # HONEST SCOPE (review finding): the direct-write-name check above does NOT prove "no write
    # can EVER reach the replica by construction." `Loopctl.HeavyRead.transaction/2` is a generic
    # lever whose caller-supplied body is handed the resolved repo (`invoke/1` -> `fun.(repo())`)
    # and could, in principle, call `repo.insert!/1` — a write not in the name list, and one that
    # also evades the static heavy_read_guard (the body uses the PASSED repo, not a literal
    # `Loopctl.HeavyReadRepo` reference). Replica write-safety therefore rests on TWO layers,
    # both pinned by this suite/guards + docs:
    #   L1 (code): no such writing caller exists — `heavy_read_guard_test.exs` proves only
    #      `Loopctl.HeavyRead` may reach `HeavyReadRepo`, and there is no request-path
    #      `transaction/2` caller (it is reserved for a future off-request export/read job).
    #   L2 (infra): `REPLICA_DATABASE_URL` MUST be a PHYSICALLY read-only replica (documented in
    #      `HeavyReadRepo`'s moduledoc + `HeavyRead.transaction/2`), which rejects any write.
    # Assert the lever exists and is acknowledged, so this caveat can't be silently forgotten.
    exported = Loopctl.HeavyRead.__info__(:functions)

    assert Keyword.has_key?(exported, :transaction),
           "transaction/2 is the write-capable lever this two-layer caveat is about; if it is " <>
             "removed, delete this test — do not let the caveat go stale."
  end

  describe "US-38.1 primary-pinned reads (STH must not read a lagging replica)" do
    test "the audit-chain STH read endpoint is PRIMARY-PINNED (never the replica)" do
      # Regression guard for the high-severity review finding: sign_and_store_tree_head/1 reads
      # the chain head + checkpoint from the PRIMARY (AdminRepo) but the entry-hash tail via
      # HeavyRead. If that tail ran on a lagging async replica the signer would fold an
      # INCOMPLETE tail and emit a WRONG signed root labeled at the primary head position.
      # Pinning :sth_incremental to the primary keeps head/checkpoint/tail on one snapshot.
      assert :sth_incremental in Loopctl.HeavyRead.primary_pinned_endpoints()
    end

    test "repo_for is byte-identical (STH stays on the heavy-read pool) with NO replica configured" do
      # In the test env no replica is configured, so the pin is INERT: EVERY endpoint — the
      # primary-pinned STH included — resolves to the heavy-read pool (`repo/0`), never
      # AdminRepo's write pool. This is the byte-identical-to-pre-US-38.1 guarantee.
      refute Loopctl.DbCapacity.replica_configured?()
      assert Loopctl.HeavyRead.repo_for(:sth_incremental) == Loopctl.HeavyRead.repo()
      assert Loopctl.HeavyRead.repo_for(:semantic_search) == Loopctl.HeavyRead.repo()
      # A bare/unknown endpoint (nil) is replica-eligible (not consistency-coupled).
      assert Loopctl.HeavyRead.repo_for(nil) == Loopctl.HeavyRead.repo()
    end

    test "route_repo pins STH to the primary ONLY when a replica is configured (distinct sentinels)" do
      # NON-TAUTOLOGICAL regression for the prod AdminRepo/HeavyReadRepo divergence: under
      # `mix test` `repo() == primary_repo() == AdminRepo`, so a `repo_for/1` equality can't
      # tell the two apart. Exercise the pure DI seam with DISTINCT sentinel modules (no
      # Application.put_env) to prove the pin gates on `replica_configured?` and never diverts
      # a consistency-coupled read onto the primary pool when no replica exists.
      # Distinct sentinel modules (HeavyReadRepo != AdminRepo) so the two branches are
      # observably different — unlike the resolved test-env repos, which are the same module.
      repo = Loopctl.HeavyReadRepo
      primary = Loopctl.AdminRepo

      # No replica: STH (and everything) stays on the heavy-read pool — byte-identical to today.
      assert Loopctl.HeavyRead.route_repo(:sth_incremental, false, repo, primary) == repo
      assert Loopctl.HeavyRead.route_repo(:semantic_search, false, repo, primary) == repo
      assert Loopctl.HeavyRead.route_repo(nil, false, repo, primary) == repo

      # Replica configured: only the consistency-coupled STH endpoint pins to the primary pool.
      assert Loopctl.HeavyRead.route_repo(:sth_incremental, true, repo, primary) == primary
      assert Loopctl.HeavyRead.route_repo(:semantic_search, true, repo, primary) == repo
      assert Loopctl.HeavyRead.route_repo(nil, true, repo, primary) == repo
    end
  end

  # ── AST helpers ──────────────────────────────────────────────────────────────────────

  # Map each `config :loopctl, <Repo>, url: <var>, ...` in runtime.exs to the bare variable
  # name bound to `url:`. Only captures the three Ecto repos we care about.
  @repos [Loopctl.Repo, Loopctl.AdminRepo, Loopctl.HeavyReadRepo]

  defp repo_url_vars(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, %{}, fn
        {:config, _, [:loopctl, {:__aliases__, _, parts}, opts]} = node, acc
        when is_list(opts) ->
          repo = Module.concat(parts)

          if repo in @repos do
            {node, Map.put(acc, repo, url_var(opts))}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # The bare variable atom bound to `url:` in a config opts list, or nil.
  defp url_var(opts) do
    case Keyword.get(opts, :url) do
      {var, _meta, ctx} when is_atom(var) and is_atom(ctx) -> var
      _ -> nil
    end
  end

  # Detect `replica_database_url = Loopctl.DbCapacity.resolve_replica_url(...)`.
  defp resolves_replica_url_via_dbcapacity?(ast) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {:=, _, [{:replica_database_url, _, ctx}, rhs]} = node, _acc when is_atom(ctx) ->
          {node, calls_resolve_replica_url?(rhs)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp calls_resolve_replica_url?(
         {{:., _, [{:__aliases__, _, [:Loopctl, :DbCapacity]}, :resolve_replica_url]}, _, _args}
       ),
       do: true

  defp calls_resolve_replica_url?(_), do: false
end
