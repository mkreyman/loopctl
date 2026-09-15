defmodule Loopctl.Delivery.TriagePayload do
  @moduledoc """
  Builds the `triage` object of a dispatch from an intake record (issues #803 and #804).

  This is the ONLY path by which a reporter's words reach a runner, and the only builder in
  the delivery loop whose input is untrusted. Its counterpart is
  `Loopctl.Delivery.ImplementerInput`, which builds the `story` object and is fed by the
  story the triage trio wrote — never by this. Design §10: the implementer never sees
  reporter text.

  ## Everything reporter-supplied goes through `Untrusted.render/2`, and nothing else does

  Three fields are the reporter's: the issue title, its body, and its labels. They are
  concatenated and rendered as ONE fenced block — one call to the tested fence, so no new
  fence-assembly code exists anywhere.

  **One block rather than one per field, and the reason is not brevity.** Splitting them
  would put a structural claim about reporter text into the payload: this run of characters
  is a title, that one is a body, these are labels. Whoever consumed that would be deciding
  how the three relate, and neither loopctl nor a runner can make that claim safely about
  text a stranger wrote. One block lets the runner's template say the only thing that is
  reliably true — *this is what a human wrote, in full, and it is data* — and say nothing
  else. (Settled with the `loopctl-runner` maintaining session, 2026-09-15, which owns the
  template that has to live with it; it asked for one block and the argument above is
  theirs.)

  Nothing inside the block labels the parts, for the same reason: a marker loopctl wrote
  between the title and the body is a marker the reporter's own text can imitate, and a
  reader who trusts it has been steered. The parts are separated by blank lines and nothing
  more.

  **If a later session needs the title as its own value, loopctl derives a separate TRUSTED
  field for it.** It must never be recovered by parsing this block. That is the honest
  version of the same need and the contract says so.

  ## What is NOT fenced, and why that is safe

  `record_id`, `issue_number`, `html_url`, `truncated` and `escalation_reasons` are
  loopctl's own. The first two are integers and a UUID. `html_url` is GitHub's canonical URL
  for the issue, bounded by the contract's `maxLength` and matching a shape a reporter
  cannot influence beyond the issue number already carried. `escalation_reasons` is the
  output of loopctl's own detectors (`Loopctl.Delivery.InjectionDetector`), not of anything
  the reporter wrote — it is what loopctl CONCLUDED about the text, which is why the triage
  session may read it as information while reading the text itself only as data.

  `truncated` is the one that changes a verdict: it says loopctl cut the reporter's text at
  intake, so the block is incomplete and a verdict reached on it should say so. It is
  carried rather than inferred because the block gives a reader no way to tell a report that
  ended from one that was cut.

  ## Oversize is escalated, never truncated

  A record whose rendered object exceeds `RunnerTriage.max_bytes/0` is refused with
  `{:error, :triage_too_large}` and its caller escalates it to a human, exactly as
  `Loopctl.Delivery.StoryPayload` refuses an oversize story. Truncating here would be
  strictly worse than it is for a story: the fence's closing line lives at the END of the
  block, so a cut mid-block yields text that is unterminated as well as incomplete, and a
  triage verdict reached on half a report is a wrong answer delivered confidently.
  """

  alias Loopctl.ApiSpec.RunnerContract.ByteRule
  alias Loopctl.ApiSpec.RunnerContract.RunnerTriage
  alias Loopctl.Delivery.Untrusted
  alias Loopctl.Intake.Record

  @type error :: :triage_too_large

  @doc """
  The `triage` object for `record`, or `{:error, :triage_too_large}` when the rendered
  object does not fit `RunnerTriage.max_bytes/0`.

  The map is keyed by ATOMS, the shape `RunnerContract.cast_dispatch/1` produces and the
  channel pushes.
  """
  @spec build(Record.t()) :: {:ok, map()} | {:error, error()}
  def build(%Record{} = record) do
    triage = %{
      record_id: record.id,
      issue_number: record.issue_number,
      html_url: record.html_url,
      untrusted: untrusted_block(record),
      truncated: record.untrusted_truncated,
      escalation_reasons: record.escalation_reasons
    }

    if ByteRule.bytes(triage) > RunnerTriage.max_bytes() do
      {:error, :triage_too_large}
    else
      {:ok, triage}
    end
  end

  # ONE render call over the three fields joined. The join happens BEFORE the fence, so
  # every character of every field — separators included — goes through `neutralise/1` and
  # comes out line-prefixed. There is no position in the result where reporter text is
  # outside the fence, which is the property that would be at risk if this assembled fences
  # itself.
  #
  # The label is `reported_issue` and not a per-field name, because the block is one thing
  # now: a single report as its author wrote it.
  defp untrusted_block(%Record{} = record) do
    Untrusted.render("reported_issue", reporter_text(record))
  end

  # Blank lines between the parts and no markers naming them — see the moduledoc. A missing
  # part contributes nothing rather than an empty marker, since an absent label list and a
  # label list the reporter left empty are the same fact about the report.
  defp reporter_text(%Record{} = record) do
    [record.untrusted_title, record.untrusted_body, labels(record.untrusted_labels)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp labels(nil), do: nil
  defp labels([]), do: nil
  defp labels(labels) when is_list(labels), do: Enum.join(labels, "\n")
end
