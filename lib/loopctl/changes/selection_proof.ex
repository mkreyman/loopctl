defmodule Loopctl.Changes.SelectionProof do
  @moduledoc """
  The measured proof that a change to chg's test-SELECTION code only widens what it selects
  (US-51.5). `Loopctl.Delivery.MergePrecondition` clears a `:prove_effect` Gate B outcome on a
  selection-proof repository (`Loopctl.Changes.Findings.chg_repo/1` by default) with it, and
  with nothing else.

  ## Where the measurement comes from, and why there

  From the `selection_replay` the story's verifier recorded with its `verify@1` verdict: the
  `agent_result` on the dispatch ledger row of the story's `verifier_dispatch_id`. That dispatch
  is the verifier B `Loopctl.Agents.VerifierPlacement` minted as its own root for a runner whose
  agent is not the implementer's, and B's key never leaves loopctl, so nothing the implementing
  session can reach writes that row. The story's design first named chg LEDGER rows carrying
  the verifier's dispatch id in `raw`; those are signed with a source secret every fleet machine
  holds, so the implementer could have written one naming any id. The verdict row cannot be.

  ## What passes

  All of, for the stage row's CURRENT head:

  1. a `verify@1` verdict of `pass` for that head, on B's row, carrying `selection_replay`;
  2. a replay corpus of at least `min_corpus/0` commits, none of which DROPS a test its base
     selected (`dropped` empty and `head_count >= base_count`): selection may only widen;
  3. when the story came from a `selection_miss` finding (`intake_records.loop_finding_id`),
     the replay of that finding's commit (`miss.sha`) covers every test the gate failed there,
     as loopctl recorded them on the finding, never as the verifier names them.

  Anything else is `{:fail, reasons}`, each reason naming what is missing or which commit
  narrowed. A story with no linked finding is judged on 1 and 2: there is no miss to cover, and
  widening is the property that keeps a fix from hiding one.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Finding
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Source
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord

  @min_corpus 5

  @type reason :: atom() | tuple()

  @doc "The fewest replayed commits a proof may rest on."
  @spec min_corpus() :: pos_integer()
  def min_corpus, do: @min_corpus

  @doc """
  Judges the proof for `story` (needs `tenant_id`, `id`, `verifier_dispatch_id` and
  `intake_record_id`) at `head_sha`, the stage row's recorded head.
  """
  @spec judge(map(), String.t() | nil) :: :pass | {:fail, [reason()]}
  def judge(%{verifier_dispatch_id: nil}, _head_sha),
    do: {:fail, [:selection_replay_missing]}

  def judge(_story, nil), do: {:fail, [:selection_replay_missing]}

  def judge(story, head_sha) do
    with {:ok, replay} <- replay(story, head_sha) do
      case corpus_reasons(replay) ++ miss_reasons(story, replay) do
        [] -> :pass
        reasons -> {:fail, reasons}
      end
    end
  end

  defp replay(story, head_sha) do
    case DispatchLedger.get_record(story.tenant_id, story.verifier_dispatch_id) do
      %DispatchRecord{
        kind: "verify",
        agent_result_spec: "verify@1",
        story_id: story_id,
        agent_result: %{} = result
      }
      when story_id == story.id ->
        verdict_replay(result, head_sha)

      _other ->
        {:fail, [:selection_replay_missing]}
    end
  end

  defp verdict_replay(result, head_sha) do
    cond do
      field(result, "head_sha") != head_sha -> {:fail, [:selection_replay_for_other_head]}
      field(result, "verdict") != "pass" -> {:fail, [:selection_replay_not_passed]}
      is_map(field(result, "selection_replay")) -> {:ok, field(result, "selection_replay")}
      true -> {:fail, [:selection_replay_missing]}
    end
  end

  defp corpus_reasons(replay) do
    corpus = List.wrap(field(replay, "corpus"))

    narrowed =
      for entry <- corpus, narrowed?(entry) do
        {:selection_narrowed, field(entry, "sha"), List.wrap(field(entry, "dropped"))}
      end

    if length(corpus) < @min_corpus,
      do: [{:selection_replay_corpus_too_small, length(corpus), @min_corpus} | narrowed],
      else: narrowed
  end

  defp narrowed?(entry) do
    dropped = List.wrap(field(entry, "dropped"))
    base = field(entry, "base_count")
    head = field(entry, "head_count")

    dropped != [] or not is_integer(base) or not is_integer(head) or head < base
  end

  defp miss_reasons(story, replay) do
    case loop_finding(story) do
      %Finding{kind: "selection_miss", evidence: evidence} -> covered_reasons(evidence, replay)
      _none -> []
    end
  end

  defp covered_reasons(evidence, replay) do
    miss = field(replay, "miss") || %{}
    failures = List.wrap(evidence["failures"])
    covered = MapSet.new(List.wrap(field(miss, "covered")))

    cond do
      failures == [] ->
        [:selection_miss_failures_unrecorded]

      field(miss, "sha") != evidence["sha"] ->
        [{:selection_replay_wrong_miss, evidence["sha"]}]

      true ->
        case Enum.reject(failures, &MapSet.member?(covered, &1)) do
          [] -> []
          missing -> [{:selection_miss_not_covered, missing}]
        end
    end
  end

  defp loop_finding(%{intake_record_id: nil}), do: nil

  # The finding a story's issue was filed for, on EVERY source. `loop_finding_id` is written
  # only where the ticket gate admitted the issue, and the chg repository's source is not
  # ticket-gated, so keying on it alone skipped the coverage check exactly where selection
  # misses are filed. The issue number on the record's own repository is the same rule
  # intake admission uses (`Findings.loop_finding_for/1`); `loop_finding_id` still counts for
  # a finding cleared since, whose issue number was reset.
  defp loop_finding(%{tenant_id: tenant_id, intake_record_id: record_id}) do
    AdminRepo.one(
      from r in Record,
        join: s in Source,
        on: s.id == r.source_id and s.tenant_id == r.tenant_id,
        join: f in Finding,
        on:
          f.tenant_id == r.tenant_id and
            (f.id == r.loop_finding_id or
               (f.issue_number == r.issue_number and
                  fragment("lower(?) = lower(?)", f.repo_full_name, s.repo_full_name))),
        where: r.tenant_id == ^tenant_id and r.id == ^record_id,
        order_by: [desc: f.id == r.loop_finding_id],
        limit: 1,
        select: f
    )
  end

  # Always read back from Postgres, so the keys are strings.
  defp field(map, key) when is_map(map), do: Map.get(map, key)

  defp field(_other, _key), do: nil
end
