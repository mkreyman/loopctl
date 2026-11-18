defmodule Loopctl.Changes.ReviewFindings do
  @moduledoc """
  Parses a pull request body's `## Review findings` section (US-50.4).

  The format is the one claude-config's `bin/review-dispositions.py --render` prints and its
  parser reads, one line per finding:

      N. <disposition> <severity> <file>:<line> — <summary>[ — <reason>]

  This module is a port of that parser, and its vocabulary below is copied from it; the test
  pins both with a section taken from a real merged PR body. It never fails on content: the body
  is untrusted text from a forge, so a line it cannot read is returned under `:unparsed` and a
  body with no section is `section?: false`.

  - A section starts at a heading whose text begins `Review findings` (any level) and ends at
    the next heading of its own level or higher. Headings inside fenced code open nothing.
  - An indented continuation line joins the finding above it.
  - `wrong`, `intentional`, `didnt-matter`, `deferred` and `routed` need a reason after the
    summary; `wrong` must read `wrong because ...`, `deferred` must name `#N`, `owner/repo#N`
    or `story <id>`, `routed` must name `#N` or `owner/repo#N`.
  - `0 findings.` is a section with no findings.
  """

  @dispositions ~w(fixed wrong intentional didnt-matter deferred routed)
  @needs_reason ~w(wrong intentional didnt-matter deferred routed)
  @severities ~w(critical high medium low)

  @heading ~r/^ {0,3}(\#{1,6})[ \t]+(.*?)[ \t#]*$/
  @fence ~r/^ {0,3}(`{3,}|~{3,})/
  @section_name "review findings"
  @zero ~r/^0 findings\b[:.]?(\s.*)?$/i
  @numbered ~r/^(\d+)\.[ \t]+(.*)$/
  @listish ~r/^([-*+]|\d+\))[ \t]+\S/
  @location ~r/^(\S+?):(\d+)(?:-\d+)?(?::\d+)?$/
  @sep ~r/[ \t]+(?:—|--)[ \t]+/u
  @deferred_to ~r/(?:^|[\s(])(?:[\w.-]+\/[\w.-]+)?#\d+\b|\bstory\s+[\w.-]*\d/i
  @routed_to ~r/(?:^|[\s(])(?:[\w.-]+\/[\w.-]+)?#\d+\b/
  @wrong_because ~r/^wrong because\b\s*\S/i
  # Markdown a writer puts around a word (`**fixed**`, a backticked location). Never `_`.
  @markup ~r/^[*`]+|[*`]+$/

  @max_body_bytes 262_144
  @max_unparsed 50
  @max_field 500

  @type finding :: %{
          n: pos_integer(),
          disposition: String.t(),
          severity: String.t(),
          file: String.t(),
          line: pos_integer(),
          summary: String.t(),
          reason: String.t() | nil
        }

  @type result :: %{section?: boolean(), findings: [finding()], unparsed: [String.t()]}

  @doc "The disposition vocabulary, as review-dispositions.py has it."
  @spec dispositions() :: [String.t()]
  def dispositions, do: @dispositions

  @doc "The severity vocabulary, as review-dispositions.py has it."
  @spec severities() :: [String.t()]
  def severities, do: @severities

  @doc """
  Parses `body`. A `nil` or non-binary body is a body with no section. A body over
  #{@max_body_bytes} bytes is read only up to that length; at most #{@max_unparsed} unparsed lines
  are kept, each cut at #{@max_field} characters.
  """
  @spec parse(term()) :: result()
  def parse(body) when is_binary(body) do
    body =
      if byte_size(body) > @max_body_bytes, do: binary_part(body, 0, @max_body_bytes), else: body

    body = if String.valid?(body), do: body, else: String.replace_invalid(body)
    # U+0000 is valid UTF-8 but Postgres refuses it in text and jsonb, where the parse is
    # stored, so it is removed here rather than failing the job on body content.
    body = String.replace(body, <<0>>, "")

    sections = sections(body)

    {findings, unparsed} =
      Enum.reduce(sections, {[], []}, fn lines, acc -> parse_section(lines, acc) end)

    %{
      section?: sections != [],
      findings: Enum.reverse(findings),
      unparsed: unparsed |> Enum.reverse() |> Enum.take(@max_unparsed)
    }
  end

  def parse(_body), do: %{section?: false, findings: [], unparsed: []}

  defp parse_section(lines, {findings, unparsed}) do
    {findings, unparsed, zero?, count} =
      lines
      |> logical_lines()
      |> Enum.reduce({findings, unparsed, false, 0}, &classify/2)

    cond do
      zero? and count > 0 ->
        {findings, ["the section says \"0 findings.\" and also lists #{count}" | unparsed]}

      not zero? and count == 0 ->
        {findings,
         ["a Review findings section with neither a numbered finding nor 0 findings" | unparsed]}

      true ->
        {findings, unparsed}
    end
  end

  defp classify(line, {findings, unparsed, zero?, count}) do
    cond do
      match = Regex.run(@numbered, line) ->
        [_, n, rest] = match

        case parse_finding(n, rest) do
          {:ok, finding} -> {[finding | findings], unparsed, zero?, count + 1}
          :error -> {findings, [clip(line) | unparsed], zero?, count + 1}
        end

      Regex.match?(@zero, line) ->
        {findings, unparsed, true, count}

      Regex.match?(@listish, line) ->
        {findings, [clip(line) | unparsed], zero?, count + 1}

      true ->
        {findings, unparsed, zero?, count}
    end
  end

  defp clip(text), do: String.slice(text, 0, @max_field)

  defp sections(body) do
    {out, cur, _level, _fence} =
      body
      |> String.split(["\r\n", "\n"])
      |> Enum.reduce({[], nil, 0, nil}, &section_line/2)

    out |> close(cur) |> Enum.reverse() |> Enum.map(&Enum.reverse/1)
  end

  # `out` holds closed sections, each a reversed line list; `cur` is the open one, or nil.
  defp section_line(raw, {out, cur, level, fence}) do
    line = String.trim_trailing(raw, "\r")
    fence_match = Regex.run(@fence, line, capture: :all_but_first)

    cond do
      fence != nil ->
        if closes_fence?(fence_match, fence, line),
          do: {out, cur, level, nil},
          else: {out, cur, level, fence}

      fence_match != nil ->
        {out, cur, level, hd(fence_match)}

      heading = Regex.run(@heading, line, capture: :all_but_first) ->
        [hashes, text] = heading
        heading_line(String.length(hashes), text, line, {out, cur, level})

      cur != nil ->
        {out, [line | cur], level, nil}

      true ->
        {out, cur, level, nil}
    end
  end

  defp heading_line(lv, text, line, {out, cur, level}) do
    cond do
      text |> String.trim() |> String.downcase() |> String.starts_with?(@section_name) ->
        {close(out, cur), [], lv, nil}

      cur != nil and lv <= level ->
        {close(out, cur), nil, 0, nil}

      cur != nil ->
        {out, [line | cur], level, nil}

      true ->
        {out, nil, level, nil}
    end
  end

  defp close(out, nil), do: out
  defp close(out, cur), do: [cur | out]

  defp closes_fence?(nil, _fence, _line), do: false

  defp closes_fence?([marker], fence, line) do
    String.first(marker) == String.first(fence) and String.length(marker) >= String.length(fence) and
      String.trim(String.replace_prefix(String.trim_leading(line), marker, "")) == ""
  end

  defp logical_lines(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      text = String.trim(line)

      cond do
        text == "" ->
          acc

        indented?(line) and acc != [] and Regex.match?(@numbered, hd(acc)) and
          not Regex.match?(@numbered, text) and not Regex.match?(@listish, text) ->
          [hd(acc) <> " " <> text | tl(acc)]

        true ->
          [text | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp indented?(<<c, _::binary>>) when c in [?\s, ?\t], do: true
  defp indented?(_line), do: false

  defp parse_finding(n, rest) do
    with [w1, w2, location | tail] <- split_words(rest),
         {disposition, severity} = order(strip(w1), strip(w2)),
         true <- disposition in @dispositions and severity in @severities,
         [_, file, line] <- Regex.run(@location, strip(location)),
         ["" | [_ | _] = parts] <- Regex.split(@sep, " " <> Enum.join(tail)),
         parts = Enum.map(parts, &String.trim/1),
         {summary, reason} = summary_reason(disposition, parts),
         true <- summary != "" and reason_ok?(disposition, reason) do
      {:ok,
       %{
         n: String.to_integer(n),
         disposition: disposition,
         severity: severity,
         file: clip(file),
         line: String.to_integer(line),
         summary: clip(summary),
         reason: if(reason == "", do: nil, else: clip(reason))
       }}
    else
      _ -> :error
    end
  end

  # Python's `rest.split(None, 3)`: three words, then the rest of the line.
  defp split_words(rest), do: String.split(String.trim(rest), ~r/\s+/, parts: 4)

  # Python's `word.strip('*`')`: markup characters off both ends, case kept.
  defp strip(word), do: Regex.replace(@markup, word, "")

  defp order(a, b) do
    if String.downcase(a) in @severities and String.downcase(b) in @dispositions,
      do: {String.downcase(b), String.downcase(a)},
      else: {String.downcase(a), String.downcase(b)}
  end

  defp summary_reason(disposition, parts) when disposition in @needs_reason and length(parts) > 1,
    do: {parts |> Enum.drop(-1) |> Enum.join(" — "), List.last(parts)}

  defp summary_reason(_disposition, parts), do: {Enum.join(parts, " — "), ""}

  defp reason_ok?(disposition, reason) when disposition in @needs_reason do
    reason != "" and
      case disposition do
        "wrong" -> Regex.match?(@wrong_because, reason)
        "deferred" -> Regex.match?(@deferred_to, reason)
        "routed" -> Regex.match?(@routed_to, reason)
        _ -> true
      end
  end

  defp reason_ok?(_disposition, _reason), do: true
end
