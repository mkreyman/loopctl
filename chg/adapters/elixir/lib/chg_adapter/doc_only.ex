defmodule ChgAdapter.DocOnly do
  @moduledoc """
  Whether a change touches only comments and documentation (#92), so `mix chg.affected`
  selects no tests for it and `mix chg.static` skips dialyzer.

  A changed `.ex`/`.exs` file is doc-only when its source at the base and in the working
  tree parse to the same code once comments (the parser drops them), line and column
  metadata, and the literal values of `@moduledoc`, `@doc` and `@typedoc` are set aside.
  A change made only of such files, plus documentation files (`.md`, `.txt`, `.rst`,
  `.adoc`) outside `priv/` and the test paths that no module reads as an
  `@external_resource` and `chg` does not name as read at run time, is a doc-only change.
  `mix chg.affected` asks this of the base and of the commit its selection compares with
  (the coverage record's, the snapshot's), so code changed since that commit is never
  hidden behind a doc-only diff.

  It fails closed: anything it cannot show to be documentation counts as code, and the
  caller falls back to its normal selection. That covers a file that does not parse at
  either side (an edited heredoc terminator), a new or deleted file, a template
  (`.heex`/`.eex`, whose comments render), a doc whose value is not a literal (`@moduledoc
  File.read!(...)`, an interpolated string), a doc holding a doctest (`iex>`) whose text
  changed, a source that reads a doc attribute back (`@doc` with no value,
  `Module.get_attribute(__MODULE__, :doc)`), and any change in a project whose code reads
  docs at run time (`Code.fetch_docs`).
  """

  @doc_attrs [:moduledoc, :doc, :typedoc]
  @doc_exts [".md", ".txt", ".rst", ".adoc"]

  @doc """
  `{:doc_only, changed}` when every path in `changed` (relative to the project, as
  `ChgAdapter.changed_paths/1` returns them) is documentation; otherwise `:code`.
  `base_source` returns a path's source at the base, or `:error` when it is not there;
  `external` is the module graph's `external` map; `read` the paths `chg` names as read
  at run time; `test_path?` whether a path is under the test paths, where a docs file is
  test data.
  """
  def judge(changed, base_source, external, read, test_path? \\ fn _ -> false end) do
    read = MapSet.new(read)

    if changed != [] and
         Enum.all?(changed, &doc_path?(&1, base_source, external, read, test_path?)) do
      {:doc_only, changed}
    else
      :code
    end
  end

  @doc """
  `judge/5` for the working tree against `base`, reading the base from git. A project
  whose own code reads docs back at run time (`Code.fetch_docs`, the `:docs_v1` chunk)
  has no doc-only change: a doc edit can change what its tests see.
  """
  def judge_tree(changed, base, external) do
    if reads_docs_at_run_time?(),
      do: :code,
      else:
        judge(
          changed,
          &source_at(base, &1),
          external,
          ChgAdapter.read_paths(),
          &ChgAdapter.test_path?/1
        )
  end

  defp reads_docs_at_run_time? do
    {_, status} =
      System.cmd("git", ["grep", "-q", "-E", "fetch_docs|docs_v1", "--", "*.ex", "*.exs"],
        stderr_to_stdout: true
      )

    # 1 is "no match"; anything else (a match, or git failing) fails closed.
    status != 1
  end

  @doc "A one-line description of a doc-only change for a selection reason."
  def reason(files), do: "doc-only change (comments and docs only): #{Enum.join(files, ", ")}"

  defp doc_path?(path, base_source, external, read, test_path?) do
    cond do
      MapSet.member?(read, path) ->
        false

      elixir?(path) ->
        same_code?(base_source.(path), File.read(path), path)

      Path.extname(path) in @doc_exts ->
        not Map.has_key?(external, path) and not priv?(path) and not test_path?.(path)

      true ->
        false
    end
  end

  defp elixir?(path), do: Path.extname(path) in [".ex", ".exs"]

  defp priv?(path), do: "priv" in Path.split(path)

  defp same_code?({:ok, old}, {:ok, new}, path) do
    with {:ok, a} <- strip(old, path), {:ok, b} <- strip(new, path) do
      a.code == b.code and a.doctests == b.doctests
    else
      _ -> false
    end
  end

  defp same_code?(_, _, _), do: false

  @doc """
  The code of `source` with comments, positions and literal doc values set aside, and the
  doc values that hold a doctest, in order: `{:ok, %{code: ast, doctests: [doc]}}`, or
  `:error` when it does not parse or reads a doc attribute back.
  """
  def strip(source, path \\ "nofile") do
    case Code.string_to_quoted(source, file: path, columns: false, emit_warnings: false) do
      {:ok, ast} ->
        {code, doctests} = Macro.prewalk(ast, [], &set_aside/2)

        if reads_doc?(code),
          do: :error,
          else: {:ok, %{code: code, doctests: Enum.reverse(doctests)}}

      {:error, _} ->
        :error
    end
  end

  defp set_aside({:@, _, [{attr, _, [value]}]} = node, acc) when attr in @doc_attrs do
    if literal?(value) do
      doctests = if doctest?(value), do: [value |> unmeta() | acc], else: acc
      # The attribute as a string: as an atom, reads_doc?/1 would take it for a read.
      {{:__chg_doc__, [], [Atom.to_string(attr)]}, doctests}
    else
      {unmeta_node(node), acc}
    end
  end

  defp set_aside(node, acc), do: {unmeta_node(node), acc}

  defp unmeta_node({form, meta, args}) when is_list(meta), do: {form, [], args}
  defp unmeta_node(node), do: node

  defp unmeta(ast), do: Macro.prewalk(ast, &unmeta_node/1)

  # A value nothing is evaluated for: a string, `false`/`nil`, a sigil over plain text, or
  # a keyword list of those (`@doc since: "1.2"`).
  defp literal?(v) when is_binary(v) or is_boolean(v) or is_nil(v) or is_number(v), do: true

  defp literal?({sigil, _, [{:<<>>, _, parts}, mods]})
       when is_atom(sigil) and is_list(parts) and is_list(mods),
       do: String.starts_with?(Atom.to_string(sigil), "sigil_") and Enum.all?(parts, &is_binary/1)

  defp literal?(list) when is_list(list),
    do:
      Enum.all?(list, fn
        {k, v} when is_atom(k) -> literal?(v)
        _ -> false
      end)

  defp literal?(_), do: false

  # ExUnit.DocTest's prompts: `iex>` and the numbered `iex(1)>`.
  defp doctest?(value), do: Macro.to_string(value) =~ ~r/iex(\(\d+\))?>/

  # A doc attribute read back (`@doc` alone) or named as an atom anywhere else, which
  # `Module.get_attribute/2` and friends need: the code could depend on the doc's text.
  defp reads_doc?(code) do
    {_, found} =
      Macro.prewalk(code, false, fn
        {:@, _, [{attr, _, ctx}]} = n, _ when attr in @doc_attrs and is_atom(ctx) -> {n, true}
        a, _ when a in @doc_attrs -> {a, true}
        n, acc -> {n, acc}
      end)

    found
  end

  defp source_at(base, path) do
    case System.cmd("git", ["show", "#{base}:./#{path}"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      _ -> :error
    end
  end
end
