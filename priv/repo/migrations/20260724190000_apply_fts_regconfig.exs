defmodule Loopctl.Repo.Migrations.ApplyFtsRegconfig do
  @moduledoc """
  #492 — align the STORED keyword `search_vector`s with the deployment's configured
  text-search regconfig (`FTS_REGCONFIG` → `Loopctl.Search.Regconfig`).

  Keyword FTS shipped hardwired to `'english'`: the `articles.search_vector` GENERATED
  column (`20260410021836`) and the `stories`/`projects`/`epics` trigger functions
  (`20260712000000`). A generated column cannot reference runtime config (it must be
  IMMUTABLE with a literal regconfig), so a per-deployment regconfig has to be baked in
  by a migration. This migration reads the configured regconfig and, WHEN IT DIFFERS
  from the `"english"` default, rebuilds:

    * `articles.search_vector` — DROP + re-ADD the generated column (+ its GIN index)
      with the configured regconfig;
    * the `stories`/`projects`/`epics` trigger functions — `CREATE OR REPLACE` with the
      configured regconfig, then recompute existing rows so stored lexemes match.

  It is a **NO-OP on the shipped `"english"` default**, so the hosted instance and CI
  are unchanged (this migration records as a no-op there). It runs on a FRESH
  non-English self-host, where the tables are empty — so the DROP/re-ADD and recompute
  are instant. Query sites pass the same regconfig as a `::regconfig` bind param
  (`Loopctl.Knowledge` / `Loopctl.ContextRetriever.Executor`), so stored and queried
  stemmers match.

  ## Changing the regconfig on an EXISTING corpus

  Once this migration has run, changing `FTS_REGCONFIG` does NOT re-run it. Rebuilding
  a populated corpus's vectors (a table rewrite of `articles` + a full recompute of the
  CR tables — potentially a write outage) is a deliberate operator action, out of scope
  here; a dedicated online rebuild task is the follow-up for that path.
  """

  use Ecto.Migration

  alias Loopctl.Search.Regconfig

  # Mirrors `20260712000000`'s @configs — the weighted column set each CR vector covers.
  @cr_configs [
    %{table: "stories", columns: [{"title", "A"}, {"description", "B"}]},
    %{table: "projects", columns: [{"name", "A"}, {"description", "B"}, {"mission", "C"}]},
    %{table: "epics", columns: [{"title", "A"}, {"description", "B"}]}
  ]

  def up do
    regconfig = Regconfig.get()

    if regconfig == Regconfig.default() do
      # Shipped default: the stored vectors are already 'english'. Nothing to do.
      :ok
    else
      assert_regconfig_exists!(regconfig)
      rebuild_articles(regconfig)
      Enum.each(@cr_configs, &rebuild_cr_table(&1, regconfig))
    end
  end

  # Irreversible by design: `down` would need to know the prior regconfig to rebuild to,
  # and the shipped baseline is 'english' which the `20260410021836`/`20260712000000`
  # migrations already own. A no-op avoids fighting that ownership / losing data.
  def down, do: :ok

  # A well-formed but NON-EXISTENT regconfig (e.g. a typo) must fail the migration LOUDLY
  # rather than silently building an unusable vector. `Regconfig.get/0` already guaranteed
  # the identifier SHAPE (injection-safe); this checks it is a real pg_ts_config.
  defp assert_regconfig_exists!(regconfig) do
    %{rows: [[count]]} =
      repo().query!("SELECT count(*) FROM pg_ts_config WHERE cfgname = $1", [regconfig])

    if count == 0 do
      raise "FTS_REGCONFIG=#{inspect(regconfig)} is not an installed Postgres text search " <>
              "configuration (not in pg_ts_config). Install it or pick a valid one."
    end
  end

  defp rebuild_articles(regconfig) do
    execute("DROP INDEX IF EXISTS articles_search_vector_idx")
    execute("ALTER TABLE articles DROP COLUMN IF EXISTS search_vector")

    execute("""
    ALTER TABLE articles ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('#{regconfig}', coalesce(title, '')), 'A') ||
      setweight(to_tsvector('#{regconfig}', coalesce(body, '')), 'B')
    ) STORED
    """)

    execute("CREATE INDEX articles_search_vector_idx ON articles USING GIN (search_vector)")
  end

  defp rebuild_cr_table(%{table: table, columns: columns}, regconfig) do
    # Re-point the self-maintaining trigger at the new regconfig (columns qualified NEW.
    # in the trigger body, which runs with no table in scope).
    execute("""
    CREATE OR REPLACE FUNCTION #{table}_search_vector_update() RETURNS trigger AS $$
    BEGIN
      NEW.search_vector := #{tsvector_expr(columns, "NEW.", regconfig)};
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    # Recompute existing rows so their stored lexemes use the new regconfig (bare column
    # refs — the expression evaluates against the updated row). On a fresh install this
    # touches zero rows; the GIN index is maintained by the UPDATE.
    execute("UPDATE #{table} SET search_vector = #{tsvector_expr(columns, "", regconfig)}")
  end

  defp tsvector_expr(columns, prefix, regconfig) do
    columns
    |> Enum.map(fn {col, weight} ->
      "setweight(to_tsvector('#{regconfig}', coalesce(#{prefix}#{col}, '')), '#{weight}')"
    end)
    |> Enum.join(" || ")
  end
end
