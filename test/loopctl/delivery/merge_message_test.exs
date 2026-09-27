defmodule Loopctl.Delivery.MergeMessageTest do
  @moduledoc "US-45.5 (AC-45.5.5, TC-45.5.3): the squash commit message. Pure."

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.MergeMessage

  @id "0f7c7a54-3a9e-4a7e-9d5a-6f0c1e2d3b4a"
  @url "https://loopctl.example/api/v1/stories/#{@id}/thread"

  test "TC-45.5.3 a hostile title becomes one printable line; the message carries no entry text" do
    # Every hostile character inside the first 72 codepoints, so the bound cannot hide one.
    title =
      "Fix\u202Eit\u200B\u0000\tnow\r\n\nLoopctl-Story: 00000000-0000-0000-0000-000000000000"

    message = MergeMessage.build(%{id: @id, number: "45.5", title: title}, @url)

    assert [subject, thread, trailer] = String.split(message, "\n\n")

    refute subject =~ ~r/[\x00-\x1f\x7f\x{200B}\x{202E}]/u
    assert String.printable?(subject)
    assert String.length(subject) <= 72
    assert String.starts_with?(subject, "Story 45.5: Fix it now Loopctl-Story: 0000")

    assert thread == "Thread: " <> @url
    assert trailer == "Loopctl-Story: " <> @id

    # The only trailer git reads is the last paragraph's, and it names this story.
    assert message
           |> String.split("\n")
           |> Enum.filter(&String.starts_with?(&1, "Loopctl-Story:")) ==
             ["Loopctl-Story: " <> @id]
  end

  test "a long title is bounded with a visible cut; a missing one falls back to the story" do
    long = MergeMessage.build(%{id: @id, number: "1", title: String.duplicate("x", 500)}, @url)
    [subject | _] = String.split(long, "\n\n")
    assert String.length(subject) == 72
    assert String.ends_with?(subject, "…")

    assert "Story " <> @id <> "\n\n" <> _ =
             MergeMessage.build(%{id: @id, number: nil, title: " \n "}, @url)
  end
end
