defmodule Loopctl.Delivery.GateAInput do
  @moduledoc """
  What Gate A is judged on, read from the database and never from a caller (epic 44,
  US-44.1).

  Until contract 1.15.0 the merge precondition took the triage trio's outputs from the
  request, so the principal driving a merge also supplied the triage it was judged against
  and a fabricated unanimous trio cleared Gate A. Now the input is one of three facts, each
  resolved here from the story's stage row and its transition history:

  - `{:persisted_triage, outputs}` — the three lens verdicts of the ONE triage that triaged
    the story, translated to the shape `Loopctl.DeliveryGates.GateA.evaluate/1` reads. They
    are runner-authored and untrusted, but they were written by a triage session before any
    implementation existed, which is a different principal from whoever asks for the merge.
  - `:human_resolution` — a human re-queued the story from an escalation that was ABOUT Gate
    A: a `:triage_escalate` escalation whose reason is the trio's own `escalate` verdict, or a
    `:merge_gate` one whose event records Gate A among its reasons. A triage escalation for any
    OTHER cause — a flagged or undispatchable draft, an oversize ticket, an incomplete run —
    put a different question to the human, who never saw the lens verdicts. A human already made the decision Gate A exists to route to them, and
    refusing it again at merge would loop. A human re-queue of any OTHER escalation (a spent
    retry ceiling, a Gate B refusal) says nothing about the request and does not count.
  - `:missing` — neither. The gate refuses, because waiting cannot make a verdict appear.

  ## Which verdict: the dispatch bound to the story, never the newest row

  The story's stage row carries `triage_dispatch_id`, written ON the `detected -> triaged`
  transition by the dispatch whose verdict took it (`Loopctl.Delivery.TriageVerdict`), in that
  transition's own transaction, and cleared by nothing. A dispatch that did not triage the
  story is refused before it can take any further transition. Gate A reads the bound
  dispatch's row. "The newest row for the story"
  would be wrong because records and transitions are separate writes, so a later row need not
  be the one that decided anything. A story with no bound dispatch (triaged before the binding
  existed, or escalated by the dispatcher without a triage run) is `:missing`.

  ## Where the state lives

  In `story_stages`, `story_stage_events` and `triage_verdicts`, all read through
  `Repo.with_tenant/2` with
  an explicit tenant predicate, so a tenant's evaluation cannot reach another tenant's rows.
  The history is walked in `Loopctl.Delivery.Stages.list_transitions/2`'s order, never by
  comparing timestamps across the two tables. A database error RAISES: the merge-precondition
  request then fails having written nothing, and the caller retries — a transient fault must
  not become an escalation a human has to clear.
  """

  import Ecto.Query

  alias Loopctl.ApiSpec.RunnerContract.RunnerLensVerdict
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.TriageVerdictRecord
  alias Loopctl.Repo

  @type t :: {:persisted_triage, [map()]} | :human_resolution | :missing

  # Gate A records a lens's confidence and never decides on it; the wire enum is mapped to
  # the number its parser reads only so the recorded value keeps its order.
  @confidence %{"low" => 0.25, "medium" => 0.5, "high" => 0.9}

  @doc "Gate A's input for one story. See the moduledoc for the three answers."
  @spec for_story(Ecto.UUID.t(), Ecto.UUID.t()) :: t()
  def for_story(tenant_id, story_id) do
    cond do
      human_resolved?(tenant_id, story_id) ->
        :human_resolution

      dispatch_id = bound_dispatch(tenant_id, story_id) ->
        persisted(tenant_id, story_id, dispatch_id)

      true ->
        :missing
    end
  end

  @doc """
  The stored lens map as Gate A's three outputs, in the contract's lens order. `nil` for a
  map that does not name each lens exactly once with an object for each — a verdict recorded
  before 1.15.0, or a row written around the cast. Read as missing, never crashed on.
  """
  @spec outputs(map() | nil) :: [map()] | nil
  def outputs(%{} = lens_map) do
    lenses = RunnerLensVerdict.lenses()

    if lens_map |> Map.keys() |> Enum.sort() == Enum.sort(lenses) and
         Enum.all?(Map.values(lens_map), &entry?/1),
       do: Enum.map(lenses, &output(Map.fetch!(lens_map, &1))),
       else: nil
  end

  def outputs(_lens_map), do: nil

  defp entry?(%{"outcome" => outcome}) when is_binary(outcome), do: true
  defp entry?(_entry), do: false

  defp output(entry) do
    %{
      "verdict" => entry["outcome"],
      "escalation_reasons" => entry["escalation_reasons"] || [],
      "contradicts" => entry["contradicts"] || [],
      "confidence" => Map.get(@confidence, entry["confidence"])
    }
  end

  defp persisted(tenant_id, story_id, dispatch_id) do
    {:ok, lens_map} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.one(
          from r in TriageVerdictRecord,
            where: r.tenant_id == ^tenant_id and r.story_id == ^story_id,
            where: r.dispatch_id == ^dispatch_id,
            select: r.lens_verdicts
        )
      end)

    case outputs(lens_map) do
      nil -> :missing
      outputs -> {:persisted_triage, outputs}
    end
  end

  defp bound_dispatch(tenant_id, story_id) do
    case Stages.get(tenant_id, story_id) do
      %{triage_dispatch_id: dispatch_id} -> dispatch_id
      nil -> nil
    end
  end

  # Whether a human has resolved an escalation that was about Gate A. A resolution is STICKY —
  # a human who answered the Gate A question does not un-answer it by later re-queueing the
  # story from an unrelated escalation — and ANY qualifying resolution counts, not only the
  # last one.
  defp human_resolved?(tenant_id, story_id) do
    tenant_id
    |> Stages.list_transitions(story_id)
    |> Enum.reduce(%{escalation: nil, resolved?: false}, &step/2)
    |> Map.fetch!(:resolved?)
  end

  defp step(%{to: "escalated"} = event, acc), do: %{acc | escalation: event}

  defp step(%{edge: "human_resolution"}, %{escalation: escalation} = acc),
    do: %{acc | escalation: nil, resolved?: acc.resolved? or gate_a_escalation?(escalation)}

  defp step(_event, acc), do: acc

  # `Stages` stores a transition's reason under "reason"; the trio's own escalate verdict is the
  # only triage escalation that put the lens verdicts in front of a human.
  defp gate_a_escalation?(%{
         edge: "triage_escalate",
         data: %{"reason" => "triage_verdict:escalate"}
       }),
       do: true

  # The triage gate screen's own refusal (US-44.2), when Gate A or the trio's verdict was among
  # its codes: the human who re-queues it was shown THAT refusal. A screen refusal on Gate B
  # codes alone put a different question to them.
  defp gate_a_escalation?(%{
         edge: "triage_escalate",
         data: %{"reason" => "triage_verdict:gate_screen(" <> kinds}
       }),
       do: String.contains?(kinds, ["gate_a:", "trio_verdict"])

  # `Stages` stores a transition's `:event_data` under "payload"; the merge gate sets it only
  # when Gate A was among the reasons it refused.
  defp gate_a_escalation?(%{edge: "merge_gate", data: %{"payload" => %{"gate_a" => true}}}),
    do: true

  defp gate_a_escalation?(_escalation), do: false
end
