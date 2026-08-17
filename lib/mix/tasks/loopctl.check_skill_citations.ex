defmodule Mix.Tasks.Loopctl.CheckSkillCitations do
  @moduledoc """
  Guards the hardcoded `file:line` citations in the domain skills and CLAUDE.md
  against code drift.

  The `.claude/skills/*/SKILL.md` skills (and the trust-model sections of
  `CLAUDE.md`) instruct readers to "read the cited code before changing it". A
  citation that rots after a refactor points an agent at an unrelated function,
  which is worse than no citation at all. This is the same guardrail idea as
  `mix loopctl.check_wiki_links`, applied to source citations.

  ## What is checked

  Both citation forms are checked:

    * QUALIFIED — `some_file.ex:123` / `some_file.ex:123-145`;
    * BARE — `:123` / `:123-145`, which inherits its file from the most recent
      QUALIFIED citation earlier in the same document. (A bare citation before
      any qualified one has no file to resolve against and is skipped; the
      summary reports how many were skipped so a green line is never mistaken
      for full coverage.)

  For every resolvable citation:

    1. the file resolves (a repo-relative path, or a unique basename under
       `lib/`, `test/`, `config/`, `priv/`, or the repo root);
    2. the range is well formed (`1 <= start <= end <= file length`).

  QUALIFIED citations additionally get a SYMBOL check: when the citation's line
  — or the PRECEDING line, since markdown prose wraps freely and often puts the
  symbol just before its citation — names one or more `symbol/arity` functions in
  backticks, at least one of those symbols must be DEFINED inside one of the
  ranges cited on that line (a small forward window is allowed for single-line
  citations). Bare citations are deliberately exempt from the symbol check: they
  normally point at a CLAUSE or branch inside a function rather than at its
  `def`, so requiring a definition there would be noise.

  ## Usage

      mix loopctl.check_skill_citations

  Exits non-zero if any citation is stale, or if a listed source document is
  missing (a guard that silently checks nothing is worse than no guard).
  """

  use Mix.Task

  @shortdoc "Check file:line citations in domain skills and CLAUDE.md"

  # Single-line citations may point at the head of a short clause; allow the
  # definition to appear within this many lines after the cited line.
  @single_line_window 3

  @doc "The documents whose citations are guarded."
  @spec sources() :: [Path.t()]
  def sources, do: ["CLAUDE.md" | Path.wildcard(".claude/skills/*/SKILL.md")]

  @impl Mix.Task
  def run(_args) do
    docs = sources()

    if Enum.count(docs) < 2 do
      Mix.raise(
        "check_skill_citations found #{length(docs)} source document(s) — expected " <>
          "CLAUDE.md plus at least one .claude/skills/*/SKILL.md. Run from the repo root."
      )
    end

    {problems, stats} = check_with_stats(docs)

    if problems == [] do
      Mix.shell().info(
        "#{stats.checked} citation(s) resolve across #{length(docs)} document(s) " <>
          "(#{stats.skipped} bare citation(s) skipped — no qualified citation in scope)"
      )
    else
      Mix.shell().error("Stale citations found:")
      Enum.each(problems, &Mix.shell().error("  " <> &1))
      Mix.raise("#{length(problems)} stale citation(s) found")
    end
  end

  @doc """
  Returns a list of human-readable problem strings for the given documents.

  Exposed for tests; `[]` means every resolvable citation still resolves.
  """
  @spec check([Path.t()]) :: [String.t()]
  def check(sources) when is_list(sources) do
    {problems, _stats} = check_with_stats(sources)
    problems
  end

  @doc """
  Like `check/1`, but also returns `%{checked: n, skipped: n}` coverage counts.

  A missing source document is a PROBLEM, never a silent skip.
  """
  @spec check_with_stats([Path.t()]) ::
          {[String.t()], %{checked: non_neg_integer(), skipped: non_neg_integer()}}
  def check_with_stats(sources) when is_list(sources) do
    index = source_index()

    Enum.reduce(sources, {[], %{checked: 0, skipped: 0}}, fn doc, {problems, stats} ->
      if File.exists?(doc) do
        {doc_problems, doc_stats} = check_doc(doc, index)
        {problems ++ doc_problems, merge_stats(stats, doc_stats)}
      else
        {problems ++ ["#{doc}: source document not found"], stats}
      end
    end)
  end

  defp merge_stats(a, b),
    do: %{checked: a.checked + b.checked, skipped: a.skipped + b.skipped}

  defp check_doc(doc, index) do
    lines =
      doc
      |> File.read!()
      |> String.split("\n")

    numbered = Enum.with_index(lines, 1)

    {problems, stats, _current_file} =
      Enum.reduce(numbered, {[], %{checked: 0, skipped: 0}, nil}, fn {line, lineno},
                                                                     {problems, stats, current} ->
        symbols = symbols_in_window(lines, lineno)
        {citations, current} = citations_in(line, current)

        {line_problems, line_stats} = check_citations(doc, lineno, citations, symbols, index)

        {problems ++ line_problems, merge_stats(stats, line_stats), current}
      end)

    {problems, stats}
  end

  # Bounds/range problems are reported per citation. The SYMBOL check is decided
  # per LINE: a line may carry several citations ("the clause at `:1702-1706`,
  # decided by `foo/4` (`:1725-1745`)"), and it is enough that ONE of the
  # line's qualified ranges defines one of the named symbols — demanding it of
  # every citation on the line would flag correct prose.
  defp check_citations(doc, lineno, citations, symbols, index) do
    Enum.reduce(citations, {[], %{checked: 0, skipped: 0}}, fn
      {_raw, nil, _s, _e, _qualified?}, {probs, st} ->
        {probs, %{st | skipped: st.skipped + 1}}

      {raw, file, start_line, end_line, qualified?}, {probs, st} ->
        # Symbol verification applies to qualified citations only — see the
        # @moduledoc.
        check_symbols =
          if qualified? and not symbols_satisfied_elsewhere?(citations, symbols, index, raw),
            do: symbols,
            else: []

        new =
          case resolve(file, index) do
            {:ok, path} ->
              verify_citation(doc, lineno, raw, path, start_line, end_line, check_symbols)

            {:error, reason} ->
              ["#{doc}:#{lineno} — #{raw}: #{reason}"]
          end

        {probs ++ new, %{st | checked: st.checked + 1}}
    end)
  end

  defp symbols_satisfied_elsewhere?(_citations, [], _index, _raw), do: false

  defp symbols_satisfied_elsewhere?(citations, symbols, index, raw) do
    Enum.any?(citations, fn
      {other_raw, file, start_line, end_line, true} when other_raw != raw ->
        case resolve(file, index) do
          {:ok, path} ->
            verify_citation("", 0, other_raw, path, start_line, end_line, symbols) == []

          {:error, _} ->
            false
        end

      _ ->
        false
    end)
  end

  defp verify_citation(doc, lineno, raw, path, start_line, end_line, symbols) do
    lines = path |> File.read!() |> String.split("\n")
    total = length(lines)

    cond do
      start_line < 1 or end_line < start_line ->
        ["#{doc}:#{lineno} — #{raw}: invalid citation range"]

      end_line > total ->
        ["#{doc}:#{lineno} — #{raw}: #{path} has only #{total} lines"]

      symbols == [] ->
        []

      true ->
        window_end = if end_line > start_line, do: end_line, else: end_line + @single_line_window
        slice = Enum.slice(lines, (start_line - 1)..(min(window_end, total) - 1)//1)

        if Enum.any?(symbols, &defined_in?(slice, &1)) do
          []
        else
          [
            "#{doc}:#{lineno} — #{raw}: none of #{inspect(symbols)} is defined in " <>
              "#{path}:#{start_line}-#{window_end}"
          ]
        end
    end
  end

  defp defined_in?(slice, symbol) do
    # Trailing `,` covers zero-arity one-liners: `def foo, do: :bar`.
    pattern = ~r/^\s*(def|defp|defmacro|defmacrop)\s+#{Regex.escape(symbol)}[\s(,]/

    Enum.any?(slice, &Regex.match?(pattern, &1))
  end

  # Qualified: `foo.ex:12`, `foo/bar.ex:12-34`. Bare: `:12`, `:12-34` — these
  # inherit the file of the most recent qualified citation in the document
  # (`current`), which is exactly how the prose reads them.
  #
  # The leading `(?<!\w)` is load-bearing. The file half is OPTIONAL, so without it
  # the bare form matches a `:NN` ANYWHERE in the line — including inside a clock time
  # (`04:00` -> `:00`), a host:port (`127.0.0.1:15432`), or a port forward
  # (`15432:5432`). Those reported as ":0: invalid citation range" against prose that
  # contains no citation at all. A genuine bare citation always follows whitespace, a
  # backtick, or an opening paren — never a word character — so requiring that is
  # exact, not a heuristic.
  defp citations_in(line, current) do
    ~r{(?<!\w)(?:([\w./-]+\.exs?))?:(\d+)(?:-(\d+))?}
    |> Regex.scan(line)
    |> Enum.reduce({[], current}, fn match, {acc, current} ->
      {file, start_line, end_line} = parse_match(match)

      {resolved_file, current} =
        if file == nil, do: {current, current}, else: {file, file}

      raw = if file == nil, do: ":#{start_line}", else: "#{file}:#{start_line}"

      {acc ++ [{raw, resolved_file, start_line, end_line, file != nil}], current}
    end)
  end

  defp parse_match([_raw, file, start_line]), do: normalize(file, start_line, start_line)
  defp parse_match([_raw, file, start_line, ""]), do: normalize(file, start_line, start_line)
  defp parse_match([_raw, file, start_line, end_line]), do: normalize(file, start_line, end_line)

  defp normalize(file, start_line, end_line) do
    file = if file == "", do: nil, else: file
    {file, String.to_integer(start_line), String.to_integer(end_line)}
  end

  # Symbols may sit on the citation's line OR on the PRECEDING one — markdown
  # prose wraps constantly ("`HeavyRead.guard!/2`\n(`heavy_read.ex:642-660`)"),
  # and requiring same-line co-location silently downgraded those citations to a
  # bounds check only. The preceding line is only adopted when the citation's own
  # line names no symbol AND that preceding line carries no citation of its own —
  # otherwise its symbols belong to ITS citation, not to this one.
  defp symbols_in_window(lines, lineno) do
    own = lines |> Enum.at(lineno - 1, "") |> symbols_in()
    previous = Enum.at(lines, lineno - 2, "")

    cond do
      own != [] -> own
      previous_claims_its_own_symbols?(previous) -> []
      true -> symbols_in(previous)
    end
  end

  defp previous_claims_its_own_symbols?(previous) do
    {citations, _} = citations_in(previous, nil)
    citations != []
  end

  # `` `foo/2` `` or `` `Mod.foo?/2` `` -> ["foo", "foo?"]
  defp symbols_in(line) when is_binary(line) do
    ~r/`(?:[A-Z][\w.]*\.)?([a-z_][\w]*[?!]?)\/\d`/
    |> Regex.scan(line)
    |> Enum.map(fn [_full, name] -> name end)
    |> Enum.uniq()
  end

  defp symbols_in(_), do: []

  defp resolve(file, index) do
    cond do
      String.contains?(file, "/") and File.exists?(file) ->
        {:ok, file}

      String.contains?(file, "/") ->
        {:error, "no such file"}

      File.exists?(file) ->
        {:ok, file}

      true ->
        case Map.get(index, file, []) do
          [path] -> {:ok, path}
          [] -> {:error, "no such file under lib/, test/, config/, priv/ or the repo root"}
          many -> {:error, "ambiguous basename (#{length(many)} matches) — cite a full path"}
        end
    end
  end

  defp source_index do
    [
      "lib/**/*.ex",
      "lib/**/*.exs",
      "test/**/*.exs",
      "config/*.exs",
      "priv/**/*.exs",
      "*.exs",
      "*.ex"
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.group_by(&Path.basename/1)
  end
end
