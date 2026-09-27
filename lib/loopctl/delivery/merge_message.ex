defmodule Loopctl.Delivery.MergeMessage do
  @moduledoc """
  The squash commit message the merge executor writes (US-45.5, AC-45.5.5, PRD §4 item 5).
  Pure.

  It QUOTES NO SESSION TEXT: the story's number and title, the thread URL and a
  `Loopctl-Story: <id>` trailer, and nothing else — no entry body, no finding, no note. The
  base branch's history is read by people and tools that trust it; a reader who wants the
  reasoning follows the link, where the thread renders it fenced.

  The title and number are story fields a caller wrote, so each is reduced to ONE line of
  printable characters: every run of whitespace, control, format (zero-width, bidirectional),
  line or paragraph separator, private-use or unassigned codepoint becomes one space, and the
  result is bounded (`@max_subject_codepoints`). So the subject cannot break into a second
  line, and in particular cannot forge a trailer: git reads trailers only from the message's
  LAST paragraph, which this module writes.
  """

  @max_subject_codepoints 72
  @max_number_codepoints 32

  # Anything that is not a visible character on one line. `\p{C}` is control, format,
  # private use, surrogate and unassigned; `\p{Z}` every separator, the line and paragraph
  # ones included; `\s` the ASCII whitespace `\p{Z}` does not cover (tab, newline).
  @unprintable ~r/[\p{C}\p{Z}\s]+/u

  @doc "The message for `story`, whose thread is at `thread_url`."
  @spec build(%{id: String.t(), number: String.t() | nil, title: String.t() | nil}, String.t()) ::
          String.t()
  def build(%{id: id, number: number, title: title}, thread_url) do
    subject =
      case one_line(number, @max_number_codepoints) do
        "" -> one_line(title, @max_subject_codepoints)
        number -> one_line("Story #{number}: " <> (title || ""), @max_subject_codepoints)
      end

    subject = if subject == "", do: "Story #{id}", else: subject

    Enum.join(
      [subject, "Thread: " <> one_line(thread_url, 2_048), "Loopctl-Story: " <> id],
      "\n\n"
    )
  end

  @doc false
  # One printable line of at most `max` codepoints, an ellipsis marking a cut.
  @spec one_line(String.t() | nil, pos_integer()) :: String.t()
  def one_line(nil, _max), do: ""

  def one_line(text, max) when is_binary(text) do
    line =
      text
      |> String.replace_invalid()
      |> String.replace(@unprintable, " ")
      |> String.trim()

    chars = String.to_charlist(line)

    if length(chars) > max,
      do: (chars |> Enum.take(max - 1) |> List.to_string() |> String.trim_trailing()) <> "…",
      else: line
  end
end
