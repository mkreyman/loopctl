defmodule Loopctl.Embeddings.LegacyIndexRetirementRunbookTest do
  @moduledoc """
  GH #578 (Fix step 3 / acceptance bullet 1): the change is justified ENTIRELY by a
  cold-read I/O measurement, so the repo must carry both halves of it — the recorded
  BEFORE figures, and a procedure an operator can follow to take the AFTER reading.
  Without the second half the operator drops 657 MB and never learns whether the win
  materialised.

  These are doc-structure assertions (no DB), so they run in the normal async suite.

  The baseline figures are deliberately repeated across four operator surfaces
  (CHANGELOG, migration header, the knowledge-wiki skill, and now the runbook) because
  each is read in isolation at a console. That duplication is a drift risk, so it is
  asserted here rather than left to review.
  """
  use ExUnit.Case, async: true

  @runbook "docs/runbooks/embedding-dimension-cutover.md"
  @scale_runbook "docs/runbooks/knowledge_scale_verification.md"
  @changelog "CHANGELOG.md"
  @migration "priv/repo/migrations/20260805120000_drop_legacy_articles_embedding_hnsw_index.exs"
  @skill ".claude/skills/knowledge-wiki/SKILL.md"

  @section "Retiring the legacy `articles` ANN index (GH #578)"

  # The measured facts, in the exact rendering every surface uses. Distinctive enough
  # that a substring match cannot pass by accident (a bare "26" would).
  @baseline_figures ["657 MB", "658 MB", "1,695", "8,044 ms", "7,926 ms"]

  defp read(path) do
    assert File.exists?(path), "#{path} must exist"
    File.read!(path)
  end

  # The `## `-level section body, up to the next `## ` heading.
  defp section(body, heading) do
    case String.split(body, "## " <> heading, parts: 2) do
      [_before, rest] -> rest |> String.split("\n## ", parts: 2) |> hd()
      [_only] -> nil
    end
  end

  describe "the retirement section exists and is actionable" do
    test "the runbook carries a non-empty retirement section" do
      content = section(read(@runbook), @section)

      refute is_nil(content), "#{@runbook} is missing the '## #{@section}' section"
      assert String.trim(content) != "", "the '## #{@section}' section is empty"
    end

    # Non-vacuity for every section-scoped assertion below: if `section/2` silently
    # returned the whole file, each of them would pass on text that lives under some
    # OTHER heading and the retirement section could be empty.
    test "the extracted section is genuinely bounded, not the whole file" do
      body = read(@runbook)
      content = section(body, @section)

      assert byte_size(content) < byte_size(body),
             "section/2 returned the whole document — every scoped assertion is vacuous"

      refute content =~ "mix loopctl.embeddings revert",
             "the section bled into Reverting — the boundary split is not working"

      refute content =~ "Standing reconciliation",
             "the section bled past the next heading"
    end

    test "it names the out-of-band drop AND its cut-over-installs-only qualifier" do
      content = section(read(@runbook), @section)

      assert content =~ "DROP INDEX CONCURRENTLY articles_embedding_hnsw_idx",
             "must give the out-of-band drop the operator actually runs"

      assert content =~ "embedding_side_table_reads",
             "must name the flag that decides whether the drop is safe"

      assert content =~ ~r/cut-over installs only/i,
             "the drop is one-way and destroys the live read path on a non-cut-over " <>
               "install — the qualifier must be stated, not implied"
    end

    test "it records the BEFORE reading as a fixed point to compare against" do
      content = section(read(@runbook), @section)

      for figure <- @baseline_figures do
        assert content =~ figure,
               "the retirement section must record the baseline figure #{figure}; " <>
                 "an after-reading with no before is not a comparison"
      end
    end

    test "it gives the pg_stat_statements query for the AFTER reading" do
      content = section(read(@runbook), @section)

      assert content =~ "pg_stat_statements",
             "the AC names pg_stat_statements as the measurement source"

      assert content =~ "shared_blks_read",
             "block counts are the cold-read proxy — a mean over warm calls is not one"

      # The PG 17 rename: a query written against the old name errors on a newer
      # instance, and one written against the new name errors on an older one. Both
      # names must be present so the operator can pick.
      assert content =~ "shared_blk_read_time" and content =~ "blk_read_time",
             "must name BOTH pg_stat_statements read-time columns and the PG 17 rename"

      assert content =~ "PG 17", "must say WHERE the column rename happened"

      # With track_io_timing off every read-time column is identically 0, which reads
      # exactly like a total win. The prerequisite is load-bearing, not hygiene.
      assert content =~ "track_io_timing",
             "must require track_io_timing on, or the measurement silently reads as 0"
    end

    test "it points at the structural half rather than restating it" do
      content = section(read(@runbook), @section)

      assert content =~ "indisvalid",
             "the I/O reading alone cannot tell a resident index from an absent one"

      assert content =~ "knowledge_scale_verification.md",
             "must point at the runbook that owns the indisvalid + EXPLAIN check"

      # Non-vacuity: the pointer only means something if the target still carries it.
      scale = read(@scale_runbook)

      assert scale =~ "indisvalid" and scale =~ "Index drift",
             "#{@scale_runbook} must still own the structural check being pointed at"
    end
  end

  describe "the baseline does not drift between operator surfaces" do
    test "every surface quoting the baseline quotes the same numbers" do
      refute @baseline_figures == [], "vacuous: no figures asserted"

      for path <- [@runbook, @changelog, @migration, @skill] do
        body = read(path)

        for figure <- @baseline_figures do
          assert body =~ figure,
                 "#{path} quotes the #{@section} baseline but is missing #{figure} — " <>
                   "the four surfaces are read in isolation and must not disagree"
        end
      end
    end
  end
end
