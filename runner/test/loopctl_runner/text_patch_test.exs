defmodule LoopctlRunner.TextPatchTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.TextPatch

  @text "one\ntwo\nthree\nfour\nfive\nsix\nseven"

  test "a one-hunk diff replaces the lines it names" do
    diff = "@@ -2,2 +2,2 @@\n two\n-three\n+THREE"
    assert TextPatch.apply(@text, diff) == {:ok, "one\ntwo\nTHREE\nfour\nfive\nsix\nseven"}
  end

  test "headers before the first hunk are read past" do
    diff =
      "diff --git a/t b/t\nindex 1..2\n--- a/t\n+++ b/t\n@@ -1,1 +1,2 @@\n one\n+one and a half"

    assert {:ok, "one\none and a half\ntwo" <> _} = TextPatch.apply(@text, diff)
  end

  test "later hunks are placed after what earlier hunks added" do
    diff = "@@ -1,1 +1,3 @@\n one\n+a\n+b\n@@ -6,1 +8,1 @@\n-six\n+SIX"

    assert TextPatch.apply(@text, diff) ==
             {:ok, "one\na\nb\ntwo\nthree\nfour\nfive\nSIX\nseven"}
  end

  test "a hunk at the wrong line applies at the one place its lines occur" do
    diff = "@@ -1,1 +1,1 @@\n-five\n+FIVE"
    assert {:ok, patched} = TextPatch.apply(@text, diff)
    assert patched =~ "four\nFIVE\nsix"
  end

  test "an insertion anchored by a context line applies next to that line" do
    diff = "@@ -3,1 +3,2 @@\n three\n+inserted"
    assert {:ok, "one\ntwo\nthree\ninserted\nfour" <> _} = TextPatch.apply(@text, diff)

    # Anchored by its text, so the same hunk lands next to `three` in a longer text too.
    assert {:ok, "pre\none\ntwo\nthree\ninserted\nfour" <> _} =
             TextPatch.apply("pre\n" <> @text, diff)
  end

  test "a zero-context insertion (-a,0) is refused: nothing anchors it but its line number" do
    diff = "@@ -3,0 +4,1 @@\n+inserted"

    assert TextPatch.apply(@text, diff) ==
             {:error, "hunk 1 is not anchored: it carries no non-blank context or removed line"}
  end

  test "a hunk whose only context is blank lines is refused as unanchored" do
    text = "a\n\nb\n\nc"
    diff = "@@ -2,1 +2,2 @@\n\n+inserted"

    assert TextPatch.apply(text, diff) ==
             {:error, "hunk 1 is not anchored: it carries no non-blank context or removed line"}

    # Removing only blank lines is the same: it names no text to stand on.
    assert {:error, "hunk 1 is not anchored" <> _} =
             TextPatch.apply(text, "@@ -2,1 +2,0 @@\n-")
  end

  test "an unanchored hunk refuses the whole diff, even after an anchored one" do
    diff = "@@ -1,1 +1,1 @@\n-one\n+1\n@@ -5,0 +6,1 @@\n+inserted"
    assert {:error, "hunk 2 is not anchored" <> _} = TextPatch.apply(@text, diff)
  end

  test "an empty body line stands for an empty context line" do
    text = "a\n\nb"
    diff = "@@ -1,3 +1,3 @@\n a\n\n-b\n+B"
    assert TextPatch.apply(text, diff) == {:ok, "a\n\nB"}
  end

  test "a hunk whose lines are not in the text does not apply" do
    diff = "@@ -2,1 +2,1 @@\n-deux\n+DEUX"

    assert {:error, "hunk 1 does not apply: its lines are not in the text"} =
             TextPatch.apply(@text, diff)
  end

  test "a hunk away from its line that matches in two places does not apply" do
    text = "x\nsame\ny\nsame\nz"
    diff = "@@ -1,1 +1,1 @@\n-same\n+other"

    assert {:error, "hunk 1 matches more than one place in the text"} =
             TextPatch.apply(text, diff)
  end

  test "a diff that changes nothing does not apply" do
    assert TextPatch.apply(@text, "@@ -1,1 +1,1 @@\n one") == {:error, "the diff changes nothing"}
  end

  test "malformed diffs are refused, never guessed at" do
    assert {:error, "the diff has no hunk"} = TextPatch.apply(@text, "")
    assert {:error, "the diff has no hunk"} = TextPatch.apply(@text, "--- a/t\n+++ b/t")

    assert {:error, "the diff has text before its first hunk that is not a header"} =
             TextPatch.apply(@text, "please change line 2\n@@ -2,1 +2,1 @@\n-two\n+2")

    assert {:error, "hunk 1 has fewer lines than its header counts"} =
             TextPatch.apply(@text, "@@ -2,3 +2,3 @@\n-two\n+2")

    assert {:error, "hunk 1 has a line that is not context, removed or added: \"two\""} =
             TextPatch.apply(@text, "@@ -2,1 +2,1 @@\ntwo")

    assert {:error, "hunk 2 does not start with an @@ header"} =
             TextPatch.apply(@text, "@@ -1,1 +1,1 @@\n-one\n+1\ngarbage")
  end

  test "it reads and writes nothing: the text is a string in, a string out" do
    {:ok, patched} = TextPatch.apply(@text, "@@ -1,1 +1,1 @@\n-one\n+1")
    assert is_binary(patched)
    assert @text =~ "one"
  end
end
