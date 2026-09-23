defmodule Loopctl.Delivery.GateAInput do
  @moduledoc """
  What Gate A is judged on, read from the database and never from a caller (epic 44,
  US-44.1).

  Until contract 1.15.0 the merge precondition took the triage trio's outputs from the
  request, so the principal driving a merge also supplied the triage it was judged against
  and a fabricated unanimous trio cleared Gate A. Now the input is one of three facts, each
  resolved here from the story's own transition history:

  - `{:persisted_triage, outputs}` — the three lens verdicts of the ONE triage that triaged
    the story, translated to the shape `Loopctl.DeliveryGates.GateA.evaluate/1` reads. They
    are runner-authored and untrusted, but they were written by a triage session before any
    implementation existed, which is a different principal from whoever asks for the merge.
  - `:human_resolution` — a human re-queued the story from an escalation that was ABOUT Gate
    A: a `:triage_escalate` escalation, or a `:merge_gate` one whose event records Gate A
    among its reasons. A human already made the decision Gate A exists to route to them, and
    refusing it again at merge would loop. A human re-queue of any OTHER escalation (a spent
    retry ceiling, a Gate B refusal) says nothing about the request and does not count.
  - `:missing` — neither. The gate refuses, because waiting cannot make a verdict appear.

  ## Which verdict: the one that triaged the story, never the newest row

  A story leaves `detected` exactly once — the stage machine has no edge back — and the
  `detected -> triaged` event names the dispatch whose verdict drove it
  (`"triage_dispatch_id"`, written by `Loopctl.Delivery.TriageVerdict`). Gate A reads THAT
  dispatch's row. It cannot take "the newest row for the story": a verdict is recorded before
  its transitions run, so a zombie triage dispatch reporting late still records a row even
  though its transitions are refused, and the newest row would then be one that decided
  nothing. A story whose triaged event names no dispatch (triaged before this binding
  existed) is `:missing`.

  ## Where the state lives

  In `story_stage_events` and `triage_verdicts`, both read through `Repo.with_tenant/2` with
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
    walk = tenant_id |> Stages.list_transitions(story_id) |> walk()

    cond do
      walk.resolved? -> :human_resolution
      walk.triage_dispatch_id -> persisted(tenant_id, story_id, walk.triage_dispatch_id)
      true -> :missing
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

  # One pass over the transitions: which dispatch triaged the story, and whether a human has
  # since resolved an escalation that was about Gate A. A resolution is STICKY — a human who
  # answered the Gate A question does not un-answer it by later re-queueing the story from an
  # unrelated escalation — and ANY qualifying resolution counts, not only the last one.
  defp walk(transitions) do
    Enum.reduce(
      transitions,
      %{triage_dispatch_id: nil, escalation: nil, resolved?: false},
      &step/2
    )
  end

  # The triage event itself; a triage that went straight to `escalated` is also the Gate A
  # escalation a human may then resolve.
  defp step(%{from: "detected", to: "triaged", data: data}, acc),
    do: %{acc | triage_dispatch_id: get_in(data || %{}, ["payload", "triage_dispatch_id"])}

  defp step(%{to: "escalated"} = event, acc), do: %{acc | escalation: event}

  defp step(%{edge: "human_resolution"}, %{escalation: escalation} = acc),
    do: %{acc | escalation: nil, resolved?: acc.resolved? or gate_a_escalation?(escalation)}

  defp step(_event, acc), do: acc

  defp gate_a_escalation?(%{edge: "triage_escalate"}), do: true

  # `Stages` stores a transition's `:event_data` under "payload"; the merge gate sets it only
  # when Gate A was among the reasons it refused.
  defp gate_a_escalation?(%{edge: "merge_gate", data: %{"payload" => %{"gate_a" => true}}}),
    do: true

  defp gate_a_escalation?(_escalation), do: false
end
