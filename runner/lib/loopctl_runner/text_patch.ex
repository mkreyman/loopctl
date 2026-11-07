defmodule LoopctlRunner.TextPatch do
  @moduledoc """
  A unified diff applied to a string, in memory (US-48.13). Pure: nothing here reads or writes a
  file, so a proposed template revision is only ever applied to a COPY of a rendered prompt and
  never to anything in the runner's source.

  The diff is the `diff` of a `spec_tuner@1` proposal: hunks (`@@ -a,b +c,d @@`) of context
  (`" "`), removed (`"-"`) and added (`"+"`) lines, optionally preceded by `---`/`+++` (and `diff`
  or `index`) headers. A body line that is empty stands for an empty context line, because that is
  what an editor that strips trailing whitespace leaves of one.

  Each hunk must apply EXACTLY: its context and removed lines must be the text's own lines, at the
  line the header names (shifted by what earlier hunks added or removed), or else at the one and
  only place after the previous hunk where they occur. No fuzz: a hunk that matches nowhere, or in
  more than one place when not at its named line, does not apply, and neither does the diff.
  A hunk with no non-blank context or removed line — a pure insertion (`-a,0`), or one whose old
  lines are all blank — is anchored by nothing but its line number, and is refused as
  `is not anchored`: add a context line to insert next to.
  A diff that parses but changes nothing does not apply either — it proposes no revision.
  """

  @header ~r/\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

  @type hunk :: %{
          old_start: non_neg_integer(),
          old: [String.t()],
          new: [String.t()]
        }

  @doc "`text` with `diff` applied, or why it does not apply."
  @spec apply(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def apply(text, diff) when is_binary(text) and is_binary(diff) do
    with {:ok, hunks} <- parse(diff),
         {:ok, lines} <- apply_hunks(String.split(text, "\n"), hunks) do
      patched = Enum.join(lines, "\n")

      if patched == text,
        do: {:error, "the diff changes nothing"},
        else: {:ok, patched}
    end
  end

  @doc "The hunks of a unified diff, or why it is not one."
  @spec parse(String.t()) :: {:ok, [hunk()]} | {:error, String.t()}
  def parse(diff) when is_binary(diff) do
    lines = diff |> String.replace("\r\n", "\n") |> String.split("\n")

    case headers(lines) do
      {:ok, rest} -> hunks(rest, [])
      {:error, _} = error -> error
    end
  end

  defp headers([line | rest] = lines) do
    cond do
      String.starts_with?(line, "@@") -> {:ok, lines}
      String.starts_with?(line, ["--- ", "+++ ", "diff ", "index "]) -> headers(rest)
      String.trim(line) == "" -> headers(rest)
      true -> {:error, "the diff has text before its first hunk that is not a header"}
    end
  end

  defp headers([]), do: {:error, "the diff has no hunk"}

  defp hunks([], []), do: {:error, "the diff has no hunk"}
  defp hunks([], acc), do: {:ok, Enum.reverse(acc)}

  defp hunks([line | rest], acc) do
    cond do
      String.trim(line) == "" and Enum.all?(rest, &(String.trim(&1) == "")) ->
        hunks([], acc)

      match = Regex.run(@header, line) ->
        with {:ok, hunk, rest} <- hunk(match, rest, length(acc) + 1),
             do: hunks(rest, [hunk | acc])

      true ->
        {:error, "hunk #{length(acc) + 1} does not start with an @@ header"}
    end
  end

  defp hunk([_ | numbers], rest, n) do
    [old_start, old_count, _new_start, new_count] =
      numbers
      |> Kernel.++(List.duplicate("", 4 - length(numbers)))
      |> Enum.map(&count/1)

    case body(rest, old_count || 1, new_count || 1, [], []) do
      {:ok, old, new, rest} ->
        {:ok, %{old_start: old_start, old: old, new: new}, rest}

      :short ->
        {:error, "hunk #{n} has fewer lines than its header counts"}

      {:bad, line} ->
        {:error, "hunk #{n} has a line that is not context, removed or added: #{inspect(line)}"}
    end
  end

  defp count(""), do: nil
  defp count(digits), do: String.to_integer(digits)

  # Read until both counts are met, so a hunk's end is where its header says.
  defp body(rest, 0, 0, old, new), do: {:ok, Enum.reverse(old), Enum.reverse(new), rest}
  defp body([], _old_left, _new_left, _old, _new), do: :short

  defp body(["\\" <> _ | rest], old_left, new_left, old, new),
    do: body(rest, old_left, new_left, old, new)

  defp body([line | rest], old_left, new_left, old, new) do
    case line do
      "-" <> text when old_left > 0 ->
        body(rest, old_left - 1, new_left, [text | old], new)

      "+" <> text when new_left > 0 ->
        body(rest, old_left, new_left - 1, old, [text | new])

      " " <> text when old_left > 0 and new_left > 0 ->
        body(rest, old_left - 1, new_left - 1, [text | old], [text | new])

      "" when old_left > 0 and new_left > 0 ->
        body(rest, old_left - 1, new_left - 1, ["" | old], ["" | new])

      other ->
        unfit(other)
    end
  end

  # A diff line its hunk has no room for: a known kind past its count is a short header,
  # anything else is not a diff line at all.
  defp unfit(""), do: :short
  defp unfit("-" <> _), do: :short
  defp unfit("+" <> _), do: :short
  defp unfit(" " <> _), do: :short
  defp unfit(other), do: {:bad, String.slice(other, 0, 60)}

  defp apply_hunks(lines, hunks) do
    hunks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, lines, 0, 0}, fn {hunk, n}, {:ok, lines, cursor, offset} ->
      case place(lines, hunk, cursor, offset) do
        {:ok, at} ->
          old_len = length(hunk.old)
          new_len = length(hunk.new)
          patched = Enum.take(lines, at) ++ hunk.new ++ Enum.drop(lines, at + old_len)
          {:cont, {:ok, patched, at + new_len, at + new_len - (named(hunk) + old_len)}}

        {:error, why} ->
          {:halt, {:error, "hunk #{n} #{why}"}}
      end
    end)
    |> case do
      {:ok, lines, _cursor, _offset} -> {:ok, lines}
      {:error, _} = error -> error
    end
  end

  # The line a hunk names, zero-based: it starts AT line a. (A `-a,0` hunk, which would insert
  # AFTER line a, is never placed: it is unanchored, `place/4`.)
  defp named(%{old_start: start}), do: max(start - 1, 0)

  # A hunk is placed by its TEXT, never by its line number alone: one with no non-blank context or
  # removed line — a pure insertion (`-a,0`), or one whose old lines are all blank — names no text
  # to stand on, so it would land at line a of whatever it is applied to. A tuning diff is applied
  # to every case's rendered prompt (`LoopctlRunner.SpecTune`), and those prompts differ in length
  # above the template's text, so such a hunk would land somewhere different in each, possibly
  # inside the fenced untrusted data, while still "applying" to all of them.
  defp place(lines, hunk, cursor, offset) do
    if anchored?(hunk),
      do: place_anchored(lines, hunk, cursor, offset),
      else: {:error, "is not anchored: it carries no non-blank context or removed line"}
  end

  defp anchored?(%{old: old}), do: Enum.any?(old, &(String.trim(&1) != ""))

  defp place_anchored(lines, hunk, cursor, offset) do
    at = named(hunk) + offset

    if at >= cursor and matches?(lines, at, hunk.old),
      do: {:ok, at},
      else: unique_match(lines, hunk.old, cursor)
  end

  # Not where the header says: the one place after the cursor its lines match, or a refusal.
  defp unique_match(lines, old, cursor) do
    case for(
           i <- cursor..max(length(lines) - length(old), cursor - 1)//1,
           matches?(lines, i, old),
           do: i
         ) do
      [only] -> {:ok, only}
      [] -> {:error, "does not apply: its lines are not in the text"}
      _many -> {:error, "matches more than one place in the text"}
    end
  end

  defp matches?(lines, at, old), do: Enum.slice(lines, at, length(old)) == old
end
