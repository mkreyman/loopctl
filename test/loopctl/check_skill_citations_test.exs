defmodule Loopctl.CheckSkillCitationsTest do
  @moduledoc """
  Drift guard for the `file:line` citations in CLAUDE.md and the domain skills.

  Only the FIRST test is coupled to live source (that coupling is the point).
  Every mechanics test cites a synthetic `.ex` fixture written into `tmp_dir` and
  referenced by full path, so a refactor of (or a second file named) `progress.ex`
  can never fail these for the wrong reason.

  Pure file reads — no DB, no app state — so this stays `async: true`.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Loopctl.CheckSkillCitations

  @tmp_doc "citations_doc.md"
  @fixture_source """
  defmodule Fixture do
    def alpha(x), do: x

    defp beta(x), do: x
  end
  """

  test "every cited file:line in CLAUDE.md and the domain skills still resolves" do
    assert CheckSkillCitations.check(CheckSkillCitations.sources()) == []
  end

  test "sources include CLAUDE.md and every domain skill" do
    sources = CheckSkillCitations.sources()

    assert "CLAUDE.md" in sources
    assert ".claude/skills/chain-of-custody/SKILL.md" in sources
    assert Enum.all?(sources, &File.exists?/1)
  end

  @tag :tmp_dir
  test "flags a citation whose line is past the end of the file", %{tmp_dir: tmp_dir} do
    src = write_fixture(tmp_dir)
    doc = write_doc(tmp_dir, "See `#{src}:9999999` for details.")

    assert [problem] = CheckSkillCitations.check([doc])
    assert problem =~ "has only"
  end

  @tag :tmp_dir
  test "flags a citation whose named symbol is not defined in the cited range", %{
    tmp_dir: tmp_dir
  } do
    src = write_fixture(tmp_dir)
    doc = write_doc(tmp_dir, "`alpha/1` lives at `#{src}:4`.")

    assert [problem] = CheckSkillCitations.check([doc])
    assert problem =~ "alpha"
  end

  @tag :tmp_dir
  test "flags a citation to a file that does not exist", %{tmp_dir: tmp_dir} do
    doc = write_doc(tmp_dir, "See `no_such_module_here.ex:1`.")

    assert [problem] = CheckSkillCitations.check([doc])
    assert problem =~ "no such file"
  end

  @tag :tmp_dir
  test "accepts a citation whose named symbol is defined in the cited range", %{tmp_dir: tmp_dir} do
    src = write_fixture(tmp_dir)
    doc = write_doc(tmp_dir, "`alpha/1` `#{src}:2-3` is the entry point.")

    assert CheckSkillCitations.check([doc]) == []
  end

  @tag :tmp_dir
  test "finds a symbol named on the PRECEDING line when markdown wraps", %{tmp_dir: tmp_dir} do
    src = write_fixture(tmp_dir)
    doc = write_doc(tmp_dir, "The private `beta/1`\n(`#{src}:2-3`) is the guard.")

    assert [problem] = CheckSkillCitations.check([doc])
    assert problem =~ "beta"
  end

  @tag :tmp_dir
  test "checks a BARE citation against the file of the last qualified citation", %{
    tmp_dir: tmp_dir
  } do
    src = write_fixture(tmp_dir)
    doc = write_doc(tmp_dir, "See `#{src}:2` and also (`:9999999`).")

    assert [problem] = CheckSkillCitations.check([doc])
    assert problem =~ "has only"
  end

  @tag :tmp_dir
  test "rejects an invalid citation range instead of slicing from the end", %{tmp_dir: tmp_dir} do
    src = write_fixture(tmp_dir)

    for citation <- ["#{src}:0", "#{src}:5-2"] do
      doc = write_doc(tmp_dir, "`alpha/1` at `#{citation}`.")

      assert [problem] = CheckSkillCitations.check([doc])
      assert problem =~ "invalid citation range"
    end
  end

  @tag :tmp_dir
  test "reports a MISSING source document instead of silently skipping it", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "gone.md")

    assert [problem] = CheckSkillCitations.check([missing])
    assert problem =~ "source document not found"
  end

  @tag :tmp_dir
  test "reports checked/skipped coverage counts", %{tmp_dir: tmp_dir} do
    src = write_fixture(tmp_dir)
    doc = write_doc(tmp_dir, "(`:12`) then `#{src}:2` and (`:3`).")

    assert {[], %{checked: 2, skipped: 1}} = CheckSkillCitations.check_with_stats([doc])
  end

  @tag :tmp_dir
  test "resolves a root-level basename such as mix.exs", %{tmp_dir: tmp_dir} do
    doc = write_doc(tmp_dir, "The precommit alias lives in `mix.exs:1`.")

    assert CheckSkillCitations.check([doc]) == []
  end

  @tag :tmp_dir
  test "does not read a clock time or host port as a bare citation", %{
    tmp_dir: tmp_dir
  } do
    src = write_fixture(tmp_dir)

    doc =
      write_doc(tmp_dir, """
      The daily fan-outs run at 04:00, 04:30 and 05:00 UTC, after the 02:00 rollup.
      Proxy with `flyctl proxy 15432:5432` then connect to 127.0.0.1:15432.
      The real citation is `#{src}:2`.
      """)

    # Without the `(?<!\w)` guard each of those `:NN` fragments matched the BARE
    # citation form, resolved to line 0, and reported ":0: invalid citation range"
    # against prose containing no citation at all.
    assert {[], %{checked: 1, skipped: 0}} = CheckSkillCitations.check_with_stats([doc])
  end

  @tag :tmp_dir
  test "still reads a genuine bare citation after a backtick or paren", %{
    tmp_dir: tmp_dir
  } do
    src = write_fixture(tmp_dir)
    doc = write_doc(tmp_dir, "See `#{src}:2`, also (`:4`) and `:2`.")

    assert {[], %{checked: 3, skipped: 0}} = CheckSkillCitations.check_with_stats([doc])
  end

  defp write_doc(tmp_dir, body) do
    path = Path.join(tmp_dir, @tmp_doc)
    File.write!(path, body <> "\n")
    path
  end

  defp write_fixture(tmp_dir) do
    path = Path.join(tmp_dir, "citations_fixture.ex")
    File.write!(path, @fixture_source)
    path
  end
end
