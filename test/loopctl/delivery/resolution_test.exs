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
      assert is_nil(Resolution.for_labels(["bug", "wontfix"]))
      assert is_nil(Resolution.for_labels([]))
    end

    test "a list resolves on the FIRST loopctl label it holds, in the list's order" do
      assert Resolution.for_labels(["bug", "loopctl:resolution-not-actionable"]).verdict ==
               :not_actionable

      assert Resolution.for_labels([
               "loopctl:resolution-not-actionable",
               "loopctl:resolution-shipped"
             ]).verdict == :not_actionable

      assert Resolution.for_labels([
               "loopctl:resolution-shipped",
               "loopctl:resolution-not-actionable"
             ]).verdict == :shipped
    end

    test "a non-string in the label list does not crash the read" do
      assert Resolution.for_labels([nil, 42, "loopctl:resolution-shipped"]).verdict == :shipped
    end
  end
end
