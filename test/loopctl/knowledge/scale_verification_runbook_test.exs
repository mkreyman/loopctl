defmodule Loopctl.Knowledge.ScaleVerificationRunbookTest do
  @moduledoc """
  US-27.5: guards that the scale-verification RUNBOOK and the CI scale GATE exist and
  stay wired. These are doc/CI-structure assertions (no DB), so they run in the normal
  async suite — the runbook is the institutionalized process and must not silently rot.

  TC-27.5.1: the runbook has the required sections, each non-empty.
  TC-27.5.2: the CI scale gate runs the plan-assertion suite at scale (no path filter
  that would skip it), and the default suite is unaffected (scale tags excluded).
  """
  use ExUnit.Case, async: true

  @runbook "docs/runbooks/knowledge_scale_verification.md"
  @ci ".github/workflows/ci.yml"

  # Heading text asserted by CONTENT, not exact command strings (TC-27.5.1): a benign
  # command edit must not break the test, but a missing section must.
  @required_sections [
    "Retrieving the prod error",
    "Verifying at scale",
    "Closing checklist",
    "Index drift"
  ]

  describe "runbook structure (TC-27.5.1 / AC-27.5.1)" do
    test "the runbook exists" do
      assert File.exists?(@runbook), "#{@runbook} must exist (US-27.5 deliverable)"
    end

    test "every required section is present and non-empty" do
      body = File.read!(@runbook)
      sections = split_sections(body)

      for heading <- @required_sections do
        assert Map.has_key?(sections, heading),
               "runbook is missing the '## #{heading}' section"

        content = Map.fetch!(sections, heading)

        assert String.trim(content) != "",
               "runbook section '## #{heading}' is empty"
      end
    end

    test "documents the concrete prod-verification commands (AC-27.5.1)" do
      body = File.read!(@runbook)

      # The prod error is read via `fly logs` (under "## Retrieving the prod error").
      prod = Map.fetch!(split_sections(body), "Retrieving the prod error")
      assert prod =~ "fly logs", "must show how to read the prod error via fly logs"

      # The live EXPLAIN commands live under a `###` subsection of "Verifying at scale"
      # (split_sections keys `###` separately), so assert them at body level.
      assert body =~ ~r/AdminRepo\.explain/,
             "must show the live EXPLAIN via AdminRepo.explain"

      assert body =~ ~r/fly ssh console/,
             "must show running the EXPLAIN against the live build via fly ssh console rpc"

      assert body =~ ~r/ScaleSeed/,
             "must reference the US-27.1 scale fixture (ScaleSeed) for the at-scale corpus"
    end

    test "states explicitly that loopctl has NO Sentry (AC-27.5.2)" do
      body = File.read!(@runbook)
      assert body =~ ~r/no\s+sentry/i, "runbook must state loopctl uses no Sentry (AC-27.5.2)"
      assert body =~ "fly logs", "runbook must point to `fly logs` for prod errors"
    end

    test "captures the HNSW index-name drift and the DROP IF EXISTS no-op hazard (AC-27.5.5)" do
      body = File.read!(@runbook)
      assert body =~ "articles_embedding_hnsw_idx"
      assert body =~ "articles_embedding_idx"
      assert body =~ ~r/amname\s*=\s*'hnsw'/, "must show the capability-based detection snippet"

      assert body =~ ~r/DROP INDEX IF EXISTS articles_embedding_idx/,
             "must warn the name-based DROP silently no-ops against the live _hnsw_idx"
    end

    test "defines the closing checklist with the live-build confirmation (AC-27.5.4)" do
      body = File.read!(@runbook)
      checklist = Map.fetch!(split_sections(body), "Closing checklist")
      # The three non-negotiable gates: scale plan, live EXPLAIN under timeout, live 200.
      assert checklist =~ ~r/EXPLAIN ANALYZE/i
      assert checklist =~ ~r/live/i
      assert checklist =~ ~r/200/, "must require the live endpoint returns 200 on the repro ids"
    end
  end

  describe "CI scale gate wiring (TC-27.5.2 / AC-27.5.3)" do
    test "the gate invokes `mix test --only scale_nightly` (runs the plan assertions)" do
      ci = File.read!(@ci)

      assert ci =~ ~r/mix test --only scale_nightly/,
             "CI must run `mix test --only scale_nightly` (the scale gate)"
    end

    # The whole point of US-27.5 is a NON-ERODING gate. The gate runs as a matrix, one
    # job per scale file (isolated DB, no cross-file pollution). This is the guard that
    # makes coverage un-erodable: EVERY `:scale_nightly`-tagged test file under
    # test/loopctl/knowledge/ MUST be listed in the CI matrix, or it would silently
    # never run in CI (the exact bug US-27.5 fixes — the plan-assertion scale tests
    # were tagged :scale_nightly but no job ran them). Add a scale test → wire it here.
    test "every :scale_nightly test file is wired into the CI matrix (no silent gaps)" do
      ci = File.read!(@ci)

      # Scan the WHOLE test tree, not one dir — a :scale_nightly test added anywhere
      # must be wired into the matrix or it silently never runs in CI.
      # Full relative paths (the matrix lists full paths, so a scale test anywhere in
      # the tree is wireable without a dir assumption).
      tagged_files =
        "test/**/*_test.exs"
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ ~r/@moduletag\s+:scale_nightly/))

      assert tagged_files != [], "expected to find :scale_nightly-tagged test files"

      for f <- tagged_files do
        assert ci =~ f,
               "scale_nightly test #{f} is NOT listed in the CI scale matrix — it would " <>
                 "never run in CI. Add it to strategy.matrix.scale_file in ci.yml."
      end
    end

    test "the default `mix test` suite excludes scale tags (gate never slows it)" do
      helper = File.read!("test/test_helper.exs")
      assert helper =~ ":scale", "test_helper must exclude :scale by default"
      assert helper =~ ":scale_nightly", "test_helper must exclude :scale_nightly by default"
    end
  end

  # Split a markdown doc into %{"Heading" => content} for `##`/`###` headings.
  # NB: fence-blind — assumes the runbook never starts a line with `## `/`### ` INSIDE
  # a fenced code block (which would create a phantom section). That invariant holds
  # for knowledge_scale_verification.md (its code blocks use `#`/`--` single-line
  # comments, never `## `). Keep it that way when editing the runbook.
  defp split_sections(body) do
    body
    |> String.split(~r/^#{"#"}{2,3}\s+/m, trim: false)
    |> Enum.reduce(%{}, fn chunk, acc ->
      case String.split(chunk, "\n", parts: 2) do
        [heading, rest] -> Map.put(acc, String.trim(heading), rest)
        [_only] -> acc
      end
    end)
  end
end
