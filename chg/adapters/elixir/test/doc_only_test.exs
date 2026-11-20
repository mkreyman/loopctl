defmodule ChgAdapter.DocOnlyTest do
  use ExUnit.Case, async: false

  alias ChgAdapter.DocOnly

  @base """
  defmodule Sample.Billing do
    @moduledoc \"\"\"
    Bills a visit.
    \"\"\"

    # The rate in cents.
    @rate 100

    @doc "The total for `n` units."
    def total(n), do: n * @rate
  end
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "chg-doc-only-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # Judges `new` (the working tree's lib/billing.ex) against `@base` (or `base`).
  defp judge(ctx, new, opts \\ []) do
    files = Keyword.get(opts, :files, %{"lib/billing.ex" => new})
    base = Keyword.get(opts, :base, %{"lib/billing.ex" => @base})

    File.cd!(ctx.dir, fn ->
      for {path, src} <- files do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, src)
      end

      DocOnly.judge(
        Map.keys(files),
        &Map.fetch(base, &1),
        Keyword.get(opts, :external, %{}),
        Keyword.get(opts, :read, []),
        &String.starts_with?(&1, "test/")
      )
    end)
  end

  test "a moduledoc, doc and comment edit is doc-only", ctx do
    new =
      @base
      |> String.replace("Bills a visit.", "Bills a home care visit,\n  once.")
      |> String.replace("The total", "The billed total")
      |> String.replace("# The rate in cents.", "# The rate, in cents, per unit.")

    assert judge(ctx, new) == {:doc_only, ["lib/billing.ex"]}
  end

  test "a code line beside a doc edit is code", ctx do
    new =
      @base
      |> String.replace("Bills a visit.", "Bills a home care visit.")
      |> String.replace("@rate 100", "@rate 101")

    assert judge(ctx, new) == :code
  end

  test "a heredoc whose terminator was edited does not parse, so it is code", ctx do
    new = String.replace(@base, "  Bills a visit.\n  \"\"\"", "  Bills a visit.\n  \"\"")
    assert judge(ctx, new) == :code
  end

  test "a line shift from added comment lines is doc-only", ctx do
    new = String.replace(@base, "  # The rate", "  # one\n  # two\n  # The rate")
    assert judge(ctx, new) == {:doc_only, ["lib/billing.ex"]}
  end

  test "a changed doctest is code; an unchanged one beside a doc edit is not", ctx do
    with_doctest =
      String.replace(
        @base,
        ~S|@doc "The total for `n` units."|,
        ~S|@doc "iex> Sample.Billing.total(1)\n100"|
      )

    changed = String.replace(with_doctest, ~S|100"|, ~S|101"|)
    assert judge(ctx, changed, base: %{"lib/billing.ex" => with_doctest}) == :code

    moduledoc_only = String.replace(with_doctest, "Bills a visit.", "Bills one visit.")

    assert judge(ctx, moduledoc_only, base: %{"lib/billing.ex" => with_doctest}) ==
             {:doc_only, ["lib/billing.ex"]}
  end

  test "a doc whose value is evaluated is compared as code", ctx do
    base = String.replace(@base, ~S|@doc "The total for `n` units."|, ~S|@doc File.read!("a.md")|)
    new = String.replace(base, "a.md", "b.md")
    assert judge(ctx, new, base: %{"lib/billing.ex" => base}) == :code
  end

  test "a source that reads a doc attribute back is code", ctx do
    base =
      String.replace(
        @base,
        "def total(n)",
        "def doc, do: Module.get_attribute(__MODULE__, :doc)\n  def total(n)"
      )

    new = String.replace(base, "Bills a visit.", "Bills one visit.")
    assert judge(ctx, new, base: %{"lib/billing.ex" => base}) == :code
  end

  test "a new file, a template and an empty change are code", ctx do
    assert judge(ctx, @base, base: %{}) == :code

    assert judge(ctx, nil,
             files: %{"lib/page.html.heex" => "<%!-- a --%>\n"},
             base: %{"lib/page.html.heex" => "<%!-- b --%>\n"}
           ) == :code

    assert DocOnly.judge([], fn _ -> :error end, %{}, []) == :code
  end

  test "a docs file counts unless a module reads it or chg names it read at run time", ctx do
    files = %{
      "docs/guide.md" => "new\n",
      "lib/billing.ex" => String.replace(@base, "Bills", "Charges")
    }

    base = %{"lib/billing.ex" => @base}

    assert judge(ctx, nil, files: files, base: base) ==
             {:doc_only, ["docs/guide.md", "lib/billing.ex"]}

    # Under the test paths a docs file is test data.
    assert judge(ctx, nil, files: %{"test/fixtures/expected.txt" => "x"}, base: %{}) == :code

    assert judge(ctx, nil,
             files: files,
             base: base,
             external: %{"docs/guide.md" => ["lib/billing.ex"]}
           ) ==
             :code

    assert judge(ctx, nil, files: files, base: base, read: ["docs/guide.md"]) == :code
    assert judge(ctx, nil, files: %{"priv/notes.txt" => "x"}, base: %{}) == :code
  end

  test "a numbered doctest prompt counts as a doctest", ctx do
    base =
      String.replace(
        @base,
        ~S|@doc "The total for `n` units."|,
        ~S|@doc "iex(1)> Sample.Billing.total(1)\n100"|
      )

    new = String.replace(base, ~S|100"|, ~S|101"|)
    assert judge(ctx, new, base: %{"lib/billing.ex" => base}) == :code
  end

  test "an ignore file pins warnings by line when an entry holds a line number", ctx do
    File.cd!(ctx.dir, fn ->
      config = [dialyzer: [ignore_warnings: "ignore.exs"]]
      refute Mix.Tasks.Chg.Static.line_pinned_ignores?(config)

      File.write!("ignore.exs", ~S|[{"lib/a.ex", :pattern_match}, ~r/x/]|)
      refute Mix.Tasks.Chg.Static.line_pinned_ignores?(config)

      File.write!("ignore.exs", ~S|[{"lib/a.ex", :pattern_match, 42}]|)
      assert Mix.Tasks.Chg.Static.line_pinned_ignores?(config)

      File.write!("ignore.exs", ~S|["lib/a.ex:42:pattern_match"]|)
      assert Mix.Tasks.Chg.Static.line_pinned_ignores?(config)

      File.write!("ignore.exs", "[")
      assert Mix.Tasks.Chg.Static.line_pinned_ignores?(config)

      File.write!("ignore.txt", "lib/a.ex:42\n")
      assert Mix.Tasks.Chg.Static.line_pinned_ignores?(dialyzer: [ignore_warnings: "ignore.txt"])
    end)
  end

  test "the reason names the files treated as doc-only" do
    assert DocOnly.reason(["lib/a.ex", "lib/b.ex"]) ==
             "doc-only change (comments and docs only): lib/a.ex, lib/b.ex"
  end
end
