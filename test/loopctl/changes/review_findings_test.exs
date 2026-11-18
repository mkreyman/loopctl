defmodule Loopctl.Changes.ReviewFindingsTest do
  @moduledoc """
  US-50.4 TC-50.4.1: the port of claude-config's `bin/review-dispositions.py` parser. Both real
  sections below are taken verbatim from merged loopctl PR bodies, and each expectation is what
  the Python parser printed for that PR on 2026-11-18 (`--pr 1041`, `--pr 1037`).
  """

  use ExUnit.Case, async: true

  alias Loopctl.Changes.ReviewFindings

  # mkreyman/loopctl#1041, rendered by `review-dispositions.py --render`.
  @pr_1041 """
  ## How to revert

  Revert the squash commit.

  ## Review findings

  1. fixed critical mix.lock:56 — The commit does not include mix.lock: at the reviewed head plug is still 1.20.3, cowboy 2.20.0, cowlib 2.21.0 (and ranch 2.3.0, telemetry 1.4.2), while the same commit removes the CVE-2026-43966, CVE-2026-115701 and CVE-2026-113431 ignores from mix.exs.
  2. fixed low mix.exs:34 — The ignore_advisories header comment still says the list holds advisories whose fix is DECLINED and that the mint pin keeps the declined fix from arriving silently, but no declined-fix ignore remains.
  """

  # mkreyman/loopctl#1037: a section written as prose, which the Python parser rejects.
  @pr_1037 """
  ## Review findings

  1. medium, fixed: the route sweep could not see `orchestratorPinnedApiCall("PATCH", ...)`.
  2. medium, fixed: the request shape was inline in `index.js`, against the repo's `lib/` rule.
  3. low, fixed: the test only matched source text.

  ## Risk

  The new tool is additive.
  """

  test "the vocabulary matches review-dispositions.py" do
    assert ReviewFindings.dispositions() ==
             ~w(fixed wrong intentional didnt-matter deferred routed)

    assert ReviewFindings.severities() == ~w(critical high medium low)
  end

  test "a rendered section parses to one finding per line (PR 1041)" do
    assert %{section?: true, unparsed: [], findings: [first, second]} =
             ReviewFindings.parse(@pr_1041)

    assert %{n: 1, disposition: "fixed", severity: "critical", file: "mix.lock", line: 56} =
             first

    assert first.summary =~ "The commit does not include mix.lock"
    assert first.summary =~ "ignores from mix.exs."
    assert is_nil(first.reason)

    assert %{n: 2, disposition: "fixed", severity: "low", file: "mix.exs", line: 34} = second
  end

  test "a prose section is a section with every line unparsed (PR 1037)" do
    assert %{section?: true, findings: [], unparsed: unparsed} = ReviewFindings.parse(@pr_1037)
    assert length(unparsed) == 3
    assert hd(unparsed) =~ "1. medium, fixed:"
  end

  test "three dispositions with reasons, swapped order, markup and a wrapped line" do
    body = """
    ### Review findings

    1. **wrong** high `lib/a.ex:10` — it leaks — wrong because the guard at a.ex:4 returns first
    2. medium deferred lib/b.ex:20-24 — slow path
       still slow under load — deferred to #77
    3. routed low lib/c.ex:3:9 — pre-existing — routed to mkreyman/loopctl#88
    """

    assert %{section?: true, unparsed: [], findings: [a, b, c]} = ReviewFindings.parse(body)

    assert %{disposition: "wrong", severity: "high", file: "lib/a.ex", line: 10} = a
    assert a.summary == "it leaks"
    assert a.reason == "wrong because the guard at a.ex:4 returns first"

    assert %{disposition: "deferred", severity: "medium", file: "lib/b.ex", line: 20} = b
    assert b.summary == "slow path still slow under load"
    assert b.reason == "deferred to #77"

    assert %{disposition: "routed", severity: "low", file: "lib/c.ex", line: 3} = c
  end

  test "a reason the disposition demands but the line lacks is unparsed" do
    body = """
    ## Review findings

    1. wrong high lib/a.ex:1 — it leaks — because I said so
    2. deferred low lib/a.ex:2 — later — eventually
    3. intentional low lib/a.ex:3 — no reason given
    4. fixed low lib/a.ex:4 — fine — with a dash in it
    """

    assert %{findings: [fixed], unparsed: unparsed} = ReviewFindings.parse(body)
    assert length(unparsed) == 3
    assert fixed.summary == "fine — with a dash in it"
  end

  test "no section, 0 findings, a fenced example, and a non-binary body" do
    assert %{section?: false, findings: [], unparsed: []} =
             ReviewFindings.parse("## Risk\n\nnone")

    assert %{section?: false} = ReviewFindings.parse(nil)

    assert %{section?: true, findings: [], unparsed: []} =
             ReviewFindings.parse("## Review findings\n\n0 findings.\n")

    fenced = "```\n## Review findings\n1. fixed low a.ex:1 — x\n```\n"
    assert %{section?: false, findings: []} = ReviewFindings.parse(fenced)
  end

  test "a section that ends at a same-level heading does not swallow what follows" do
    body =
      "## Review findings\n\n1. fixed low a.ex:1 — x\n\n## Notes\n\n2. fixed low b.ex:1 — y\n"

    assert %{findings: [%{file: "a.ex"}], unparsed: []} = ReviewFindings.parse(body)
  end
end
