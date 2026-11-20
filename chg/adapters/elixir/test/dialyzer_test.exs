defmodule ChgAdapter.DialyzerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Chg.Dialyzer

  @moduletag :tmp_dir

  test "the incremental PLT is per env, under the state dir the snapshot clones" do
    assert Dialyzer.iplt("test") == "_build/chg/dialyzer-test.iplt"
    assert Dialyzer.iplt("dev") == "_build/chg/dialyzer-dev.iplt"
  end

  describe "unavailable/4" do
    test "runs when OTP has incremental mode, the PLT exists and dialyxir has every function",
         %{tmp_dir: dir} do
      plt = Path.join(dir, "x.iplt")
      File.write!(plt, "")
      assert Dialyzer.unavailable(false, plt, 28, fn _ -> true end) == nil
    end

    test "an OTP before 26 has no incremental mode", %{tmp_dir: dir} do
      assert Dialyzer.unavailable(true, Path.join(dir, "x.iplt"), 25, fn _ -> true end) =~
               "OTP 25"
    end

    test "a check never builds the PLT; the snapshot does", %{tmp_dir: dir} do
      plt = Path.join(dir, "missing.iplt")
      assert Dialyzer.unavailable(false, plt, 28, fn _ -> true end) =~ "no incremental PLT"
      assert Dialyzer.unavailable(true, plt, 28, fn _ -> true end) == nil
    end

    test "a dialyxir without a function this calls is named", %{tmp_dir: dir} do
      missing = {Dialyxir.Formatter, :format_and_filter, 5}

      assert Dialyzer.unavailable(true, Path.join(dir, "x.iplt"), 28, &(&1 != missing)) =~
               "format_and_filter"
    end
  end

  describe "report/1, as mix dialyzer exits" do
    test "no warnings passes, unused filters or not" do
      assert Dialyzer.report({:ok, [], :no_unused_filters}) == 0
      assert Dialyzer.report({:warn, [], {:unused_filters_present, "skips"}}) == 0
    end

    test "warnings are printed one per line and exit 2" do
      out =
        capture_io(fn ->
          assert Dialyzer.report({:ok, ["lib/a.ex:3:no_return x"], :no_unused_filters}) == 2
        end)

      assert out == "lib/a.ex:3:no_return x\n"
    end

    test "unused filters the ignore file fails on exit 1, warnings or not" do
      out =
        capture_io(fn ->
          assert Dialyzer.report({:error, [], {:unused_filters_present, "{\"lib/a.ex\"}"}}) == 1
        end)

      assert out =~ "unused filters present"
    end
  end

  test "plt_dirs/3 takes each app's ebin once, skipping unknown apps and the project's own",
       %{tmp_dir: dir} do
    for app <- ~w(a b project), do: File.mkdir_p!(Path.join([dir, app, "ebin"]))

    lib_dir = fn
      :a -> String.to_charlist(Path.join(dir, "a"))
      :b -> Path.join(dir, "b")
      :project -> Path.join(dir, "project")
      :gone -> {:error, :bad_name}
    end

    assert Dialyzer.plt_dirs(
             [:a, :b, :a, :gone, :project],
             lib_dir,
             Path.join(dir, "project/ebin")
           ) ==
             Enum.map([Path.join(dir, "a/ebin"), Path.join(dir, "b/ebin")], &String.to_charlist/1)
  end

  test "warnings/2 is dialyxir's: flags as atoms, then the defaults not removed" do
    assert Dialyzer.warnings([:error_handling, "-Wunmatched_returns", "--extra"], []) ==
             [:error_handling, :unmatched_returns, :extra, :unknown]

    assert Dialyzer.warnings([:underspecs], [:unknown]) == [:underspecs]
  end
end
