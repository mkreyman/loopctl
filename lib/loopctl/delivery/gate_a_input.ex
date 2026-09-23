defmodule Loopctl.Delivery.GateAInput do
  @moduledoc """
  What Gate A is judged on, read from the database and never from a caller (epic 44,
  US-44.1).

  Until contract 1.15.0 the merge precondition took the triage trio's outputs from the
  request, so the principal driving a merge also supplied the triage it was judged against
  and a fabricated unanimous trio cleared Gate A. Now the input is one of three facts, each
  resolved here:

  - `{:persisted_triage, outputs}` — the three lens verdicts recorded with the story's MOST
    RECENT triage verdict (a re-triage supersedes an earlier one), translated to the shape
    `Loopctl.DeliveryGates.GateA.evaluate/1` reads. They are runner-authored and untrusted,
    but they were written by a triage session before any implementation existed, which is a
    different principal from whoever asks for the merge.
  - `:human_resolution` — a human re-queued the story from an escalation that was ABOUT Gate
    A, after the most recent triage: a `:triage_escalate` escalation, or a `:merge_gate` one
    whose event records Gate A among its reasons. A human already made the decision Gate A
    exists to route to them, and refusing it again at merge would loop. A human re-queue of
    any OTHER escalation (a spent retry ceiling, a Gate B refusal) says nothing about the
    request and does not count.
  - `:missing` — neither. The gate refuses, because waiting cannot make a verdict appear.

  ## Where the state lives, and why ordering never crosses tables

  "After the most recent triage" is decided inside `story_stage_events` alone: the triage
  verdict's own transition out of `triaged` is an event on the same row as the human
  resolution, so both are ordered by that table's `(inserted_at, lock_version)` — the order
  `Loopctl.Delivery.Stages.list_events/2` reads them in, and this module reads them through
  it. Comparing `triage_verdicts.inserted_at`
  with an event's timestamp would compare two clocks written by two transactions.

  Every read is tenant-scoped through `Repo.with_tenant/2`, so a tenant's evaluation cannot
  reach another tenant's verdict or events.
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
    if human_resolved?(tenant_id, story_id),
      do: :human_resolution,
      else: persisted(tenant_id, story_id)
  end

  @doc """
  The stored lens map as Gate A's three outputs, in the contract's lens order. `nil` for a
  map that does not name each lens exactly once — a verdict recorded before 1.15.0, or a
  row written around the cast.
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

  # A row written around the cast is read as missing, never crashed on: the gate must refuse,
  # and a 500 would refuse nothing and record nothing.
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

  # The NEWEST verdict row, incomplete ones included: a re-triage that produced nothing
  # supersedes an earlier verdict rather than letting Gate A fall back to it.
  defp persisted(tenant_id, story_id) do
    Repo.with_tenant(tenant_id, fn ->
      Repo.one(
        from r in TriageVerdictRecord,
          where: r.tenant_id == ^tenant_id and r.story_id == ^story_id,
          order_by: [desc: r.inserted_at, desc: r.id],
          limit: 1,
          select: r.lens_verdicts
      )
    end)
    |> case do
      {:ok, lens_map} ->
        case outputs(lens_map) do
          nil -> :missing
          outputs -> {:persisted_triage, outputs}
        end

      {:error, _reason} ->
        :missing
    end
  end

  # Walks the story's transitions in order, remembering the escalation each human
  # resolution left, and answers whether the LAST human resolution came after the last
  # triage and resolved a Gate A escalation.
  # `Stages.list_events/2` is the one reader of that history, and its order is the order.
  defp human_resolved?(tenant_id, story_id) do
    tenant_id
    |> Stages.list_events(story_id)
    |> Enum.filter(&(&1.event == "transitioned"))
    |> Enum.map(&%{from: &1.from_stage, to: &1.to_stage, edge: &1.edge, data: &1.data})
    |> Enum.reduce(%{escalation: nil, resolved?: false}, &step/2)
    |> Map.fetch!(:resolved?)
  end

  # A new triage outcome starts the question over: a human decision about an EARLIER
  # triage is not a decision about this one.
  # A triage escalation is both at once — a new triage outcome AND the escalation a human
  # may then resolve — so it resets and is remembered in the same step.
  defp step(%{from: "triaged", to: "escalated"} = event, _acc),
    do: %{escalation: event, resolved?: false}

  defp step(%{from: "triaged"}, _acc), do: %{escalation: nil, resolved?: false}

  defp step(%{to: "escalated"} = event, acc), do: %{acc | escalation: event}

  # STICKY until the next triage: a human who answered the Gate A question does not un-answer
  # it by later re-queueing the story from an unrelated escalation.
  defp step(%{edge: "human_resolution"}, %{escalation: escalation, resolved?: resolved?}),
    do: %{escalation: nil, resolved?: resolved? or gate_a_escalation?(escalation)}

  defp step(_event, acc), do: acc

  defp gate_a_escalation?(%{edge: "triage_escalate"}), do: true
  # `Stages` stores a transition's `:event_data` under "payload"; the merge gate sets it only
  # when Gate A was among the reasons it refused.
  defp gate_a_escalation?(%{edge: "merge_gate", data: %{"payload" => %{"gate_a" => true}}}),
    do: true

  defp gate_a_escalation?(_escalation), do: false
end
