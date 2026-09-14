defmodule Loopctl.Delivery.Resolution do
  @moduledoc """
  What a delivery verdict means to the person who REPORTED the issue (#805 item 1).

  Pure data. No database, no forge, no application environment — this module is the
  CONTRACT between loopctl's verdicts and the reporting system's resolution text, and both
  sides bind to it.

  ## The failure it exists to prevent

  HomeCareBilling's GitHub webhook auto-resolves the linked support ticket with
  `resolution_notes: "Our team has shipped a fix for this issue."` on **any** issue close
  (`github_controller.ex`, `ticket_notifier.ex`) — and that string is what the reporter
  reads in the resolution email. So a `reject` verdict, closing the issue for a duplicate
  or an already-implemented request, tells her a fix shipped for something nobody built,
  and she goes looking for it.

  loopctl must never close a reporter's issue in a way that says a fix shipped when it did
  not. The mechanism is a LABEL: every close loopctl makes carries exactly one
  `loopctl:resolution-*` label, and the reporting system selects the resolution text by
  that label instead of by the close event. An issue closed with no loopctl label is not
  loopctl's close, and the reporting system's existing behaviour applies to it unchanged.

  ## The mapping

  | verdict | closes the issue | label | what the reporter is told |
  |---|---|---|---|
  | `:shipped` | yes | `#{"loopctl:resolution-shipped"}` | a fix shipped — the existing text, unchanged |
  | `:not_actionable` | yes | `#{"loopctl:resolution-not-actionable"}` | no change was needed, and why to expect none |
  | `:escalated` | **no** | — | nothing. The issue stays open |

  `:escalated` closes NOTHING, and that is the point of it being in the table rather than
  absent: an escalated story is waiting on a human, so there is no verdict to report and
  any close would be a claim about work that has not finished.

  ## `:shipped` is deploy-gated, not merge-gated

  A story earns `:shipped` only from `Loopctl.Delivery.PostDeployVerification` — the merge
  is not the ship. Design §9: the reporter is notified when a change is DEPLOYED, and the
  post-deploy verification is what establishes that the merge is actually running. Nothing
  at the `merged` stage may map to `:shipped`.

  ## Who calls this

  `PostDeployVerification` puts the resolution on every result it produces, so the verdict
  and the text it implies are decided in one place and travel together.

  `Loopctl.Delivery.IssueCloser` is the CLOSER (#805, since the intake link landed). It takes
  its label and its text from `for_verdict/1` and nowhere else, and
  `Loopctl.Intake.IssueClosure` derives the set of storable verdicts from `close?` here — so a
  verdict that stops closing in this module stops being recordable, rather than leaving the
  closer an enum value to decide about. `Loopctl.Delivery.IssueCloserTest` is the binding
  guard the earlier version of this note asked a future change to write: it asserts the exact
  label and the exact text on each close, and that a shipped close never carries the
  not-actionable one.

  Which TRANSITIONS reach a verdict at all is `Loopctl.Delivery.StageMachine.resolution_verdict/1`,
  and it is deliberately somewhere else: this module maps a verdict to what the reporter is
  told, and the machine maps an edge to a verdict. Keeping them apart is what lets `failed`
  be reached by both a triage reject (tell her) and a budget exhaustion (tell her nothing)
  without either module having to know about the other's case.
  """

  @shipped_label "loopctl:resolution-shipped"
  @not_actionable_label "loopctl:resolution-not-actionable"

  # VERBATIM the string HomeCareBilling already sends, because the shipped path is the one
  # case its current behaviour gets right. Changing the wording here would churn the only
  # message that is already correct and would break a reporting system that binds to it.
  @shipped_notes "Our team has shipped a fix for this issue."

  @not_actionable_notes "We reviewed this report and no change was made. It is either " <>
                          "already covered by existing behaviour or duplicates another " <>
                          "report. Nothing has been deployed for it — if the problem is " <>
                          "still happening, please report it again with what you saw."

  @verdicts [:shipped, :not_actionable, :escalated]

  @type verdict :: :shipped | :not_actionable | :escalated

  @type t :: %__MODULE__{
          verdict: verdict(),
          close?: boolean(),
          label: String.t() | nil,
          resolution_notes: String.t() | nil
        }

  @enforce_keys [:verdict, :close?]
  defstruct [:verdict, :close?, :label, :resolution_notes]

  @doc "Every verdict this module maps."
  @spec verdicts() :: [verdict()]
  def verdicts, do: @verdicts

  @doc """
  Every label loopctl may put on an issue it closes.

  The reporting system binds to this list: a close carrying one of these is loopctl's, and
  its resolution text is `for_label/1`'s. A close carrying none of them is somebody else's.
  """
  @spec labels() :: [String.t()]
  def labels, do: [@shipped_label, @not_actionable_label]

  @doc "The resolution a verdict implies."
  @spec for_verdict(verdict()) :: t()
  def for_verdict(:shipped) do
    %__MODULE__{
      verdict: :shipped,
      close?: true,
      label: @shipped_label,
      resolution_notes: @shipped_notes
    }
  end

  def for_verdict(:not_actionable) do
    %__MODULE__{
      verdict: :not_actionable,
      close?: true,
      label: @not_actionable_label,
      resolution_notes: @not_actionable_notes
    }
  end

  # An escalated story is waiting on a human. There is no verdict to report, so there is no
  # close and no text — NOT a close with a quieter message, which would still tell the
  # reporter the work is finished.
  def for_verdict(:escalated) do
    %__MODULE__{verdict: :escalated, close?: false, label: nil, resolution_notes: nil}
  end

  @doc """
  The resolution a loopctl label names, or `nil` for a label that is not one of ours.

  The reverse direction of `for_verdict/1`, for a reader that has the closed issue and
  needs the text: `labels/0` is what it matches against, and `nil` means the close was not
  loopctl's.
  """
  @spec for_label(String.t()) :: t() | nil
  def for_label(@shipped_label), do: for_verdict(:shipped)
  def for_label(@not_actionable_label), do: for_verdict(:not_actionable)
  def for_label(_label), do: nil

  # REMOVED: `for_labels/1`, which resolved a label LIST to the first loopctl label it found
  # (#826 round 3, findings 4 and 5).
  #
  # It had exactly one caller, `Loopctl.Delivery.IssueCloser`, and that caller was wrong to use
  # it: "first one wins" is not a safe reading of an issue carrying BOTH resolution labels. The
  # reporting system resolves such a close by its own order, which may not be ours, so the
  # reporter can be sent one verdict while loopctl records the other as delivered. The closer
  # now treats more than one loopctl label as AMBIGUOUS and refuses to claim the close.
  #
  # Nothing replaces it here on purpose. A reader that has a closed issue and wants the text
  # should filter with `labels/0`, insist on exactly one, and then call `for_label/1` — which
  # makes the ambiguity a decision at the call site instead of hiding it behind an order.
end
