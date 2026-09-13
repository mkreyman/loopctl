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

  **Nothing in `lib/` closes a GitHub issue yet**, and this module does not do it either:
  the story-to-intake-record link that would say WHICH issue a story came from is triage's
  (design §4, build order step 4) and does not exist. When a closer is written, it goes
  through `for_verdict/1` and applies `label/1` — that is a CONVENTION with no binding
  guard today, exactly as `Loopctl.Delivery.Stages.escalation_block/1` is, because there is
  no call site to bind. The guard is one test naming the closer, and it belongs to the
  change that writes one.
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

  @doc """
  The resolution named by the FIRST loopctl label in a list, or `nil` when it holds none.

  Order is the list's, not ours, so an issue that somehow carries two of them resolves to
  the one that appears first rather than to whichever this module happens to check first.
  """
  @spec for_labels([String.t()]) :: t() | nil
  def for_labels(labels) when is_list(labels) do
    Enum.find_value(labels, fn label -> is_binary(label) and for_label(label) end)
  end
end
