defmodule Mix.Tasks.Chg.StaticTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Chg.Static

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
