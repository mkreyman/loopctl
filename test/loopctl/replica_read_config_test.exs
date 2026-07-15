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

  test "TC-38.1.4: the HeavyRead wrapper (sole path to the replica DSN) exposes NO write ops" do
    # The replica DSN can only be reached through Loopctl.HeavyRead (heavy_read_guard_test.exs).
    # HeavyRead's public surface is read-only — all/one/stream/transaction reads — so no write
    # can be routed to the replica by construction. A write path must go via Repo/AdminRepo.
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
           "Loopctl.HeavyRead must expose no write operations (it backs the replica DSN); found: " <>
             inspect(write_ops)
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
