defmodule Loopctl.Delivery.ResolutionTest do
  @moduledoc """
  `Loopctl.Delivery.Resolution` — the verdict-to-resolution contract (issue #805 item 1).

  Pure data, and the whole value of it is that both sides bind to the SAME constants: the
  labels are what a reporting system matches on, so a test that restated the strings would
  agree with itself while the contract drifted. Each one is asserted as a literal here
  precisely because it is a published name, not an implementation detail.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.Resolution

  describe "the mapping" do
    test "a deploy-verified story is shipped: close, with the label and the existing text" do
      assert %Resolution{
               verdict: :shipped,
               close?: true,
               label: "loopctl:resolution-shipped",
               resolution_notes: notes
             } = Resolution.for_verdict(:shipped)

      # VERBATIM the string the reporting system already sends. The shipped path is the one
      # case its current behaviour gets right, and changing the wording would churn the only
      # message that is already correct.
      assert notes == "Our team has shipped a fix for this issue."
    end

    test "a rejected request closes with its OWN text and its own label" do
      assert %Resolution{
               verdict: :not_actionable,
               close?: true,
               label: "loopctl:resolution-not-actionable",
               resolution_notes: notes
             } = Resolution.for_verdict(:not_actionable)

      # The failure this whole module exists to prevent: a reporting system that resolves
      # on ANY close tells the reporter a fix shipped for something nobody built, and she
      # goes looking for it.
      refute notes == Resolution.for_verdict(:shipped).resolution_notes
      refute notes =~ "shipped a fix"
      assert notes =~ "no change was made"
    end

    test "an escalated story closes NOTHING and says nothing" do
      assert %Resolution{
               verdict: :escalated,
               close?: false,
               label: nil,
               resolution_notes: nil
             } = Resolution.for_verdict(:escalated)
    end

    test "every verdict is mapped, and no close is ever unlabelled" do
      # A close with no label is indistinguishable from anybody else's close, which is
      # exactly the ambiguity the label exists to remove.
      for verdict <- Resolution.verdicts() do
        resolution = Resolution.for_verdict(verdict)
        assert resolution.verdict == verdict

        if resolution.close? do
          assert resolution.label in Resolution.labels()
          assert is_binary(resolution.resolution_notes)
        else
          assert is_nil(resolution.label)
        end
      end
    end

    test "no two verdicts share a label or a text" do
      closing = Enum.map(Resolution.verdicts(), &Resolution.for_verdict/1)

      labels = closing |> Enum.map(& &1.label) |> Enum.reject(&is_nil/1)
      notes = closing |> Enum.map(& &1.resolution_notes) |> Enum.reject(&is_nil/1)

      assert labels == Enum.uniq(labels)
      assert notes == Enum.uniq(notes)
      assert Enum.sort(labels) == Enum.sort(Resolution.labels())
    end
  end

  describe "reading a closed issue back" do
    test "each published label resolves to its own resolution" do
      for label <- Resolution.labels() do
        assert %Resolution{label: ^label} = Resolution.for_label(label)
      end
    end

    test "a label that is not ours is nil — that close was somebody else's" do
      assert is_nil(Resolution.for_label("bug"))
      assert is_nil(Resolution.for_label("loopctl:something-else"))
    end

    # `for_labels/1` was REMOVED in #826 round 3 (findings 4 and 5), and the three tests that
    # covered it went with it. It resolved a label LIST to the FIRST loopctl label it found,
    # and its one caller was wrong to use it: an issue carrying BOTH resolution labels is
    # ambiguous, and "first one wins" let the reporting system send one verdict while loopctl
    # recorded the other as delivered. The closer now filters with `labels/0`, insists on
    # exactly one, and treats anything else as somebody else's close.
    test "reading a closed issue back is the CALLER's job, and ambiguity is theirs to refuse" do
      both = ["loopctl:resolution-shipped", "loopctl:resolution-not-actionable"]

      # The supported way: filter to ours, insist on exactly one, then resolve it.
      assert [_a, _b] = Enum.filter(both, &(&1 in Resolution.labels()))

      assert [one] =
               Enum.filter(["bug", "loopctl:resolution-shipped"], &(&1 in Resolution.labels()))

      assert Resolution.for_label(one).verdict == :shipped

      refute function_exported?(Resolution, :for_labels, 1)
    end
  end
end
