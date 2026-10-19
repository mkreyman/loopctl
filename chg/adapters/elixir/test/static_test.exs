defmodule Mix.Tasks.Chg.StaticTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Chg.Static

  setup do
    dir = Path.join(System.tmp_dir!(), "chg-static-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write!(dir, files) do
    for {path, body} <- files do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), body)
    end
  end

  test "only files among .formatter.exs's inputs, its subdirectories' included, are formatted",
       %{dir: dir} do
    write!(dir, %{
      ".formatter.exs" =>
        ~s([inputs: ["{lib,test}/**/*.{ex,exs}", ".credo/**/*.ex"], subdirectories: ["priv/*/migrations"]]),
      "priv/repo/migrations/.formatter.exs" => ~s([inputs: ["*.exs"]]),
      "lib/a.ex" => "",
      ".credo/c.ex" => "",
      "priv/repo/migrations/1_m.exs" => "",
      ".claude/skills/x/run.exs" => "",
      "mix.exs" => ""
    })

    files = [
      "lib/a.ex",
      ".credo/c.ex",
      "priv/repo/migrations/1_m.exs",
      ".claude/skills/x/run.exs",
      "mix.exs"
    ]

    assert Static.format_inputs(files, dir) ==
             ["lib/a.ex", ".credo/c.ex", "priv/repo/migrations/1_m.exs"]
  end

  test "without a .formatter.exs, the files are formatted as given", %{dir: dir} do
    assert Static.format_inputs(["lib/a.ex"], dir) == ["lib/a.ex"]
  end

  test "only files the default credo config includes and does not exclude are linted",
       %{dir: dir} do
    write!(dir, %{
      ".credo.exs" =>
        ~s(%{configs: [%{name: "other", files: %{included: [".claude/"]}}, %{name: "default", files: %{included: ["lib/", "mix.exs", "apps/*/lib/"], excluded: [~r"/gen/"]}}]}),
      "apps/w/lib/w.ex" => ""
    })

    files = [
      "lib/a.ex",
      "lib/gen/b.ex",
      "mix.exs",
      "apps/w/lib/w.ex",
      ".claude/skills/x/run.exs",
      "libx/c.ex"
    ]

    assert Static.credo_inputs(files, dir) == ["lib/a.ex", "mix.exs", "apps/w/lib/w.ex"]
  end

  test "without a .credo.exs, credo's own default files apply", %{dir: dir} do
    assert Static.credo_inputs(["lib/a.ex", "test/a_test.exs", ".claude/run.exs"], dir) ==
             ["lib/a.ex", "test/a_test.exs"]
  end

  test "an unreadable .formatter.exs, at the root or in a subdirectory, leaves the files as given",
       %{dir: dir} do
    write!(dir, %{
      ".formatter.exs" => "[inputs: [\"lib/**/*.ex\"], subdirectories: [\"sub\"]]",
      "sub/.formatter.exs" => "[inputs:"
    })

    files = ["lib/a.ex", "other/b.exs"]
    assert Static.format_inputs(files, dir) == files

    write!(dir, %{".formatter.exs" => "raise \"no\""})
    assert Static.format_inputs(files, dir) == files
  end

  test "a subdirectory without its own .formatter.exs adds no files", %{dir: dir} do
    write!(dir, %{
      ".formatter.exs" => ~s([inputs: ["lib/**/*.ex"], subdirectories: ["sub"]]),
      "sub/x.exs" => "",
      "lib/a.ex" => ""
    })

    assert Static.format_inputs(["lib/a.ex", "sub/x.exs"], dir) == ["lib/a.ex"]
  end

  test "an unreadable .credo.exs, or an entry credo's shape does not allow, leaves the files as given",
       %{dir: dir} do
    files = ["lib/a.ex", ".claude/run.exs"]
    write!(dir, %{".credo.exs" => "%{configs: ["})
    assert Static.credo_inputs(files, dir) == files

    write!(dir, %{
      ".credo.exs" => ~s(%{configs: [%{name: "default", files: %{included: [:lib]}}]})
    })

    assert Static.credo_inputs(files, dir) == files
  end

  test "config/.credo.exs is read, and a config not named default leaves credo's defaults",
       %{dir: dir} do
    write!(dir, %{
      "config/.credo.exs" =>
        ~s(%{configs: [%{name: "default", files: %{included: ["scripts/"]}}]})
    })

    assert Static.credo_inputs(["lib/a.ex", "scripts/s.exs"], dir) == ["scripts/s.exs"]

    write!(dir, %{
      "config/.credo.exs" => ~s(%{configs: [%{name: "strict", files: %{included: ["scripts/"]}}]})
    })

    assert Static.credo_inputs(["lib/a.ex", "scripts/s.exs"], dir) == ["lib/a.ex"]
  end

  test "both .credo.exs and config/.credo.exs present leaves the files as given", %{dir: dir} do
    write!(dir, %{".credo.exs" => "%{configs: []}", "config/.credo.exs" => "%{configs: []}"})
    assert Static.credo_inputs([".claude/run.exs"], dir) == [".claude/run.exs"]
  end

  test "unformatted files are read from mix format's report" do
    out = """
    ** (Mix) mix format failed due to --check-formatted.
    The following files are not formatted:

      * lib/a.ex
      * test/b_test.exs
    """

    assert Static.unformatted(out, ["lib/a.ex", "test/b_test.exs", "lib/c.ex"]) ==
             ["lib/a.ex", "test/b_test.exs"]
  end

  test "Elixir 1.20's coloured absolute paths are matched to the files checked" do
    out =
      "** (Mix) mix format failed due to --check-formatted.\nThe following files are not formatted:\n\n" <>
        "\e[1m\e[31m/private/tmp/w/lib/x.ex\n\e[0m\n1 1  |defmodule X do\n"

    assert Static.unformatted(out, ["lib/x.ex", "lib/y.ex"]) == ["lib/x.ex"]
  end

  test "compile warnings carry the file and line Elixir prints under them" do
    out = """
    Compiling 1 file (.ex)
        warning: variable "x" is unused (if the variable is not meant to be used, prefix it with an underscore)
        │
      3 │   def f(x), do: 1
        │         ~
        │
        └─ lib/a.ex:3:9: A.f/1

    Compilation failed due to warnings while using the --warnings-as-errors option
    """

    assert [
             %{
               check: "compile",
               file: "lib/a.ex",
               line: 3,
               message: "variable \"x\" is unused" <> _
             }
           ] =
             Static.compile_failures(out)
  end

  test "compile output without a location still fails, with the tail as the message" do
    assert [%{check: "compile", message: "boom"}] = Static.compile_failures("boom")
  end

  test "dialyzer short format lines become failures" do
    out = "done\nlib/a.ex:12:no_return Function f/0 has no local return.\nlib/b.ex:3:7:call bad\n"

    assert [
             %{
               check: "dialyzer",
               file: "lib/a.ex",
               line: 12,
               message: "no_return Function f/0 has no local return."
             },
             %{check: "dialyzer", file: "lib/b.ex", line: 3, message: "call bad"}
           ] = Static.dialyzer_failures(out)
  end

  test "credo's JSON issues become failures, after any noise before the document" do
    json =
      ~s({"issues":[{"filename":"lib/a.ex","line_no":4,"check":"Credo.Check.Readability.X","message":"m"}]})

    assert [%{check: "credo", file: "lib/a.ex", line: 4, message: "Credo.Check.Readability.X: m"}] =
             Static.credo_failures("Checking 1 file\n" <> json, 1)

    assert Static.credo_failures("", 0) == []
    assert [%{check: "credo", message: "garbage"}] = Static.credo_failures("garbage", 1)
  end
end
