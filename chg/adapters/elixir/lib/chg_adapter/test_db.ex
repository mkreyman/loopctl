defmodule ChgAdapter.TestDb do
  @moduledoc """
  Drops a product's Postgres test database when it holds migrations the tree does not.

  chg's build path checks commits from every branch in one tree, so one test database
  (one `MIX_TEST_PARTITION`) serves them all. A branch's migration runs there and stays
  when the next commit lacks it: `ecto.migrate` never rolls back what it cannot see, and
  the older commit's tests then fail on the newer schema (a `not_null_violation` on a
  column the tree has never heard of). Dropping the database lets the product's own
  setup, a task its `test` alias runs before `test`, build it again for this tree.

  For each repo in `:ecto_repos` whose compiled module names `Ecto.Adapters.Postgres`,
  the config comes from `config/*.exs`, then `config/runtime.exs`, then its `:url`. The
  tree's versions are the leading digits of every `.exs` file in `priv/**/*migrations/`,
  the repo's `priv` and its `migrations_paths`. A database version counts as ahead only
  when it is newer than the tree's oldest migration, so versions squashed into a
  structure dump are not. It talks to Postgres through the product's Postgrex and drops
  through ecto_sql's Postgres adapter, so a product without them is left alone. Nothing
  here changes a verdict: a check that cannot run is reported on stderr and the tests
  run as they would have.
  """

  @pg Ecto.Adapters.Postgres
  @timeout 15_000

  @doc "Drops every test database ahead of the tree. Returns the databases dropped."
  def reset_ahead do
    Mix.Task.run("deps.loadpaths")
    project = Mix.Project.config()
    app = project[:app]

    if Code.ensure_loaded?(Postgrex) and Code.ensure_loaded?(@pg) do
      repos = for r <- Application.get_env(app, :ecto_repos, []), do: {r, repo_config(app, r)}

      reset_ahead(repos, %{
        adapter: &adapter/1,
        tree: &tree_versions(".", &1),
        versions: &db_versions/1,
        drop: &drop/1,
        recreates?: recreates?(project[:aliases][:test])
      })
    else
      []
    end
  rescue
    e ->
      warn("test database not checked: #{Exception.message(e)}")
      []
  end

  @doc false
  # The decision, with every effect passed in `io`.
  def reset_ahead(repos, io), do: Enum.flat_map(repos, fn {repo, c} -> check(repo, c, io) end)

  defp check(repo, config, io) do
    db = config[:database]
    tree = if is_binary(db) and io.adapter.(repo) == @pg, do: io.tree.(config), else: MapSet.new()
    if Enum.empty?(tree), do: [], else: compare(db, config, tree, io)
  end

  defp compare(db, config, tree, io) do
    case io.versions.(config) do
      {:ok, versions} ->
        act(db, config, ahead(versions, tree), io)

      {:error, why} ->
        warn("#{db} not checked: #{why}")
        []
    end
  end

  defp act(_db, _config, [], _io), do: []

  defp act(db, _config, ahead, %{recreates?: false}) do
    warn(
      "#{db} holds migration(s) this tree lacks (#{Enum.join(ahead, ", ")}), and the " <>
        "project's test alias runs nothing before `test` to build it again: not dropped"
    )

    []
  end

  defp act(db, config, ahead, io) do
    warn(
      "#{db} holds migration(s) this tree lacks (#{Enum.join(ahead, ", ")}): " <>
        "dropping it so the product's setup builds it again"
    )

    case io.drop.(config) do
      :ok ->
        [db]

      {:error, why} ->
        warn("#{db} not dropped: #{why}")
        []
    end
  end

  @doc false
  # Migration versions present in the tree.
  def tree_versions(root, config) do
    dirs =
      [Path.join(config[:priv] || "priv", "migrations") | List.wrap(config[:migrations_paths])]
      |> Enum.map(&Path.join(root, &1))

    (Path.wildcard(Path.join(root, "priv/**/*migrations")) ++ dirs)
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.exs")))
    |> Enum.flat_map(fn f ->
      case Regex.run(~r/^(\d+)_/, Path.basename(f)) do
        [_, v] -> [String.to_integer(v)]
        nil -> []
      end
    end)
    |> MapSet.new()
  end

  @doc false
  # The database's versions no tree migration has and newer than the tree's oldest, sorted.
  def ahead(db, tree) do
    oldest = Enum.min(tree, fn -> nil end)
    db |> Enum.reject(&(MapSet.member?(tree, &1) or &1 < oldest)) |> Enum.sort()
  end

  @doc false
  # True when the `test` alias runs a task before `test`: the product's database setup.
  def recreates?(steps) do
    steps
    |> List.wrap()
    |> Enum.take_while(&(not (is_binary(&1) and hd(String.split(&1)) == "test")))
    |> Enum.any?()
  end

  defp repo_config(app, repo) do
    config = Keyword.merge(Application.get_env(app, repo, []), runtime(app, repo))

    case config[:url] do
      url when is_binary(url) ->
        Keyword.merge(config, apply(Ecto.Repo.Supervisor, :parse_url, [url]))

      _ ->
        config
    end
  end

  # The repo's part of config/runtime.exs, read without applying it.
  defp runtime(app, repo) do
    if File.regular?("config/runtime.exs") do
      "config/runtime.exs"
      |> Config.Reader.read!(env: Mix.env(), target: Mix.target())
      |> get_in([app, repo])
      |> List.wrap()
    else
      []
    end
  rescue
    e ->
      warn("config/runtime.exs not read for #{inspect(repo)}: #{Exception.message(e)}")
      []
  end

  # The repo module is not compiled yet in this run, so its adapter is read from the
  # beam the build path holds, which is unloaded again before `mix test` compiles.
  defp adapter(repo) do
    beam = Path.join(Mix.Project.compile_path(), "#{repo}.beam")

    cond do
      :code.is_loaded(repo) != false ->
        repo.__adapter__()

      File.regular?(beam) ->
        {:module, ^repo} = :code.load_binary(repo, to_charlist(beam), File.read!(beam))

        try do
          repo.__adapter__()
        after
          :code.purge(repo)
          :code.delete(repo)
          :code.purge(repo)
        end

      true ->
        nil
    end
  end

  # In a process of its own: a connection that fails takes down only that process, and
  # a server that does not answer is given up on after @timeout.
  defp db_versions(config) do
    {pid, ref} = spawn_monitor(fn -> exit({:versions, query_versions(config)}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:versions, result}} -> result
      {:DOWN, ^ref, :process, ^pid, reason} -> {:error, Exception.format_exit(reason)}
    after
      @timeout ->
        Process.exit(pid, :kill)
        {:error, "no answer in #{div(@timeout, 1000)} s"}
    end
  end

  defp query_versions(config) do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    case apply(@pg, :storage_status, [config]) do
      :down ->
        {:ok, []}

      :up ->
        opts =
          config
          |> Keyword.drop([:pool, :pool_size, :name])
          |> Keyword.merge(pool_size: 1, backoff_type: :stop)

        {:ok, conn} = apply(Postgrex, :start_link, [opts])

        case apply(Postgrex, :query, [conn, "SELECT version FROM #{table(config)}", []]) do
          {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &hd/1)}
          {:error, %{postgres: %{code: :undefined_table}}} -> {:ok, []}
          {:error, e} -> {:error, Exception.message(e)}
        end

      {:error, why} ->
        {:error, inspect(why)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp table(config) do
    source = ~s("#{config[:migration_source] || "schema_migrations"}")

    case config[:migration_default_prefix] do
      nil -> source
      prefix -> ~s("#{prefix}".#{source})
    end
  end

  # Without force: a database another run is using is that run's, and is left alone.
  defp drop(config) do
    case apply(@pg, :storage_down, [config]) do
      :ok -> :ok
      {:error, :already_down} -> :ok
      {:error, why} -> {:error, "drop failed: #{inspect(why)}"}
    end
  end

  defp warn(text), do: IO.puts(:standard_error, "chg: " <> text)
end
