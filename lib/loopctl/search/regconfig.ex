defmodule Loopctl.Search.Regconfig do
  @moduledoc """
  #492 — the deployment's Postgres text-search configuration (`regconfig`) for
  keyword full-text search, resolved from config with a safe default.

  Keyword FTS was hardwired to `'english'` end to end — both the stored
  `search_vector`s (article generated column + the CR backing-table triggers) and
  every `websearch_to_tsquery` / `ts_headline` query site. For a non-English tenant
  the English Snowball stemmer never unifies inflected forms (Cyrillic «отчёт» ≠
  «отчёта») and English stop-words don't apply, so `combined`/keyword search silently
  degrades. This is the single source of truth for the per-DEPLOYMENT regconfig.

  Set it with `FTS_REGCONFIG` (see `config/runtime.exs`); the default is `"english"`,
  so the hosted instance and CI are byte-for-byte unchanged.

  ## Why validation matters

  The value is interpolated into DDL by the `apply_fts_regconfig` migration (a
  regconfig cannot be a bind parameter in a generated-column expression), and passed
  as a `?::text::regconfig` bind parameter at the query sites (the `::text` is required —
  a bare `?::regconfig` makes Postgrex demand the regconfig OID as an integer and reject
  the string name at encode time). An operator-supplied
  value therefore reaches SQL. `get/0` accepts ONLY a lowercase identifier
  (`^[a-z][a-z0-9_]*$`, ≤ 63 bytes — the Postgres identifier limit), which is exactly
  the shape of a real regconfig name and closes SQL-injection; anything else falls
  back to `"english"` with a loud log rather than risking a malformed/hostile literal.
  Whether the (well-formed) name actually EXISTS in `pg_ts_config` is a separate,
  deployment-time check the migration makes — a typo'd but well-formed config fails
  the migration loudly rather than silently keyword-degrading.
  """

  require Logger

  @default "english"
  @valid_name ~r/\A[a-z][a-z0-9_]{0,62}\z/

  @doc """
  The configured text-search regconfig name (`\"english\"` by default).

  Falls back to the default — never raises — on an absent or malformed value, so a
  bad `FTS_REGCONFIG` can never crash a hot search path; the migration is where a
  well-formed-but-nonexistent config is rejected loudly.
  """
  @spec get() :: String.t()
  def get, do: validate(Application.get_env(:loopctl, :fts_regconfig, @default))

  @doc """
  Validates a raw configured value into a safe regconfig identifier, falling back to
  the default on anything malformed. Pure (no config read), so the injection/fallback
  contract is unit-testable without mutating VM-global config.
  """
  @spec validate(term()) :: String.t()
  def validate(value) when is_binary(value) do
    if Regex.match?(@valid_name, value) do
      value
    else
      Logger.error(
        "FTS_REGCONFIG=#{inspect(value)} is not a valid regconfig identifier " <>
          "(lowercase [a-z][a-z0-9_]*, ≤63 chars); falling back to #{@default}."
      )

      @default
    end
  end

  def validate(other) do
    Logger.error(
      "fts_regconfig is #{inspect(other)}, expected a string; falling back to #{@default}."
    )

    @default
  end

  @doc "The shipped default regconfig (`\"english\"`)."
  @spec default() :: String.t()
  def default, do: @default
end
