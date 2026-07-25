defmodule Loopctl.Search.RegconfigTest do
  @moduledoc """
  #492 — `Loopctl.Search.Regconfig` is the single source of truth for the deployment's
  Postgres text-search configuration (`FTS_REGCONFIG`). Its value reaches SQL two ways —
  interpolated into DDL by the `apply_fts_regconfig` migration (a regconfig can't be a
  bind param in a generated-column expression) and as a `?::text::regconfig` bind parameter
  at every query site — so `validate/1` closing SQL-injection is the security-critical
  contract, tested here as a pure function (no VM-global config mutation).

  The integration test proves the END-TO-END mechanism the migration + query sites rely
  on: a STORED generated vector built with a non-English regconfig, queried back through
  the exact `websearch_to_tsquery($n::text::regconfig, $m)` shape, stems per that config.
  """
  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog

  alias Loopctl.Search.Regconfig

  describe "validate/1 — accepts real regconfig identifiers" do
    test "passes lowercase identifier names through unchanged" do
      for name <- ~w(english simple russian french german spanish norwegian_nynorsk cfg_1) do
        assert Regconfig.validate(name) == name
      end
    end

    test "the shipped default is english" do
      assert Regconfig.default() == "english"
      assert Regconfig.validate("english") == "english"
    end
  end

  describe "validate/1 — falls back to english (never raises) on anything malformed" do
    test "rejects SQL-injection payloads and hostile literals" do
      payloads = [
        "english'; DROP TABLE articles; --",
        "english OR 1=1",
        "english)",
        "'; SELECT 1; --",
        "english regconfig",
        "en\nglish"
      ]

      for payload <- payloads do
        assert capture_log(fn ->
                 assert Regconfig.validate(payload) == "english"
               end) =~ "not a valid regconfig identifier"
      end
    end

    test "rejects uppercase, leading digit, empty, whitespace, and over-length names" do
      bad = [
        "English",
        "ENGLISH",
        "1english",
        "",
        " english",
        "english ",
        String.duplicate("a", 64)
      ]

      for value <- bad do
        capture_log(fn -> assert Regconfig.validate(value) == "english" end)
      end
    end

    test "accepts a 63-char name but rejects a 64-char name (identifier limit)" do
      assert Regconfig.validate(String.duplicate("a", 63)) == String.duplicate("a", 63)
      capture_log(fn -> assert Regconfig.validate(String.duplicate("a", 64)) == "english" end)
    end

    test "rejects non-string values" do
      for value <- [nil, :english, 123, ["english"], %{}] do
        assert capture_log(fn -> assert Regconfig.validate(value) == "english" end) =~
                 "expected a string"
      end
    end
  end

  describe "get/0" do
    test "returns english by default (no FTS_REGCONFIG configured in test)" do
      assert Regconfig.get() == "english"
    end
  end

  describe "end-to-end regconfig mechanism (stored generated vector + ::text::regconfig query)" do
    # Proves the two SQL touch points the feature depends on agree: the migration builds a
    # STORED generated `search_vector` with the configured regconfig, and every query site
    # passes that same regconfig as a `$n::text::regconfig` bind param. Uses a TEMP table (a
    # real generated column, exactly the migration's shape) so no shared schema is mutated;
    # temp tables are connection-scoped, so this is async-safe.
    #
    # The `::text::regconfig` (not a bare `::regconfig`) is itself under test: Postgrex
    # describes a bare `$1::regconfig` param as the regconfig OID type and demands an
    # integer, so passing the string name would raise at encode time — the `::text` keeps
    # the param a string and lets PG cast it. This test would fail loudly on a regression
    # back to `::regconfig`.

    # {regconfig, document, inflected form (stems to a query term), a content word present
    # verbatim (NOT a stop word — english drops "the"/"are")}. A LANGUAGE config unifies the
    # inflected form with its stem; `simple` never does.
    @stemming_cases [
      {"english", "the servers are running fast", "run", "servers"},
      # Russian is installed in stock Postgres; Alex's Cyrillic corpus is the motivating
      # case for #492. «отчёты» (reports, pl.) must unify with the query «отчёт» (report).
      {"russian", "отчёты по проектам сделаны", "отчёт", "проектам"}
    ]

    for {config, doc, stem_query, exact} <- @stemming_cases do
      test "#{config}: the language regconfig stems, simple does not — for storage AND query" do
        config = unquote(config)
        doc = unquote(doc)
        stem_query = unquote(stem_query)
        exact = unquote(exact)

        # The language config: the inflected form in `doc` stems to `stem_query` → match.
        assert probe_match?(config, doc, stem_query) == 1,
               "#{config} should stem-match #{stem_query} in #{inspect(doc)}"

        # The SAME corpus under `simple` does no stemming → the stem query misses. Config
        # alone flips the result, which is the entire point of the FTS_REGCONFIG knob.
        assert probe_match?("simple", doc, stem_query) == 0,
               "simple should NOT stem-match #{stem_query} in #{inspect(doc)}"

        # A content word present verbatim matches under BOTH configs — sanity that the row and
        # vector are wired up, so the `simple` miss above is a real negative, not empty data.
        assert probe_match?(config, doc, exact) == 1
        assert probe_match?("simple", doc, exact) == 1
      end
    end

    test "ukrainian: a valid-shape but UNINSTALLED config passes validate/1 but the migration guard rejects it" do
      # Ukrainian is NOT a stock Postgres text-search config. Two-layer defense for #492:
      #   1. shape gate (Regconfig.validate/1) — a well-formed identifier, so it passes and
      #      never silently falls back to english (which would hide the operator's mistake);
      assert Regconfig.validate("ukrainian") == "ukrainian"

      #   2. existence gate (the apply_fts_regconfig migration's assert_regconfig_exists!) —
      #      the same pg_ts_config lookup the migration runs returns 0, so the migration
      #      RAISES loudly rather than building an unusable all-simple vector.
      %{rows: [[count]]} =
        Repo.query!("SELECT count(*) FROM pg_ts_config WHERE cfgname = $1", ["ukrainian"])

      assert count == 0,
             "if a stock Postgres gains a ukrainian config, swap this case for a real " <>
               "uninstalled name — the point is a valid-shape config absent from pg_ts_config"
    end
  end

  # Builds a STORED generated vector with `config` (the migration's shape) and queries it
  # back through the exact `?::text::regconfig` bind-param shape used at every query site.
  defp probe_match?(config, doc, query_term) do
    Repo.query!("DROP TABLE IF EXISTS fts_probe")

    Repo.query!("""
    CREATE TEMP TABLE fts_probe (
      body text,
      search_vector tsvector
        GENERATED ALWAYS AS (to_tsvector('#{config}', coalesce(body, ''))) STORED
    )
    """)

    Repo.query!("INSERT INTO fts_probe (body) VALUES ($1)", [doc])

    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM fts_probe " <>
          "WHERE search_vector @@ websearch_to_tsquery($1::text::regconfig, $2)",
        [config, query_term]
      )

    count
  end
end
