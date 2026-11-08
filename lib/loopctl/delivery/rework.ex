defmodule Loopctl.Delivery.Rework do
  @moduledoc """
  The `rework` object of an `implement` dispatch (contract 1.31.0, `RunnerRework`): which pull
  request the story already has and what the independent verifier found wrong with it.

  ## Why it exists

  A `verify@1` reject sends the story back to work (`{:ci, :implementing, :verify_rejected}`,
  `Loopctl.Agents.VerifyVerdict`) and releases the claim, so the dispatch driver places a new
  implement session. Without this the new session was handed exactly what the first one was —
  the story and nothing else — on a branch whose pull request is already open, and told to
  open one. It could neither see what to fix nor that the work existed (900.224, 2026-11-08).

  ## Where the values come from

  Every value is loopctl's own record, never the runner's word:

  - the NEWEST `verify_rejected` transition on the story's stage events, whose `payload.verify`
    names the verifier dispatch, the head it judged and the pull request
    (`VerifyVerdict` writes it with the transition);
  - the findings off that verifier dispatch's ledger row (`agent_result`), the one copy of the
    verdict (`VerifyVerdict`'s moduledoc), already validated against `verify@1`'s schema.

  A reject that a later transition into `detected` (a human re-triage starts the story over) or
  `merged` (the work landed) has overtaken yields nothing. So does a reject whose event names no
  pull request or no head, or whose ledger row is gone: the session then implements the story
  as it always did, which is what a runner on an older contract does anyway.

  ## Retries

  A pure read: the same rows give the same object, so a re-send of one `dispatch_id` carries the
  rework the first send did. Nothing is written.

  ## Where it runs

  In the placing caller's process, on the RLS-enforced `Loopctl.Repo`.
  """

  import Ecto.Query

  alias Loopctl.ApiSpec.RunnerContract.RunnerRework
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchLedger
  alias Loopctl.Runners.DispatchRecord

  @sha ~r/^[0-9a-f]{40}([0-9a-f]{24})?$/

  # Transitions after which a reject no longer describes the story's work.
  @overtaken_by ~w(detected merged)

  @doc """
  The rework object for the story's next implement dispatch, or `nil` when there is none.
  """
  @spec for_story(Ecto.UUID.t(), Ecto.UUID.t()) :: map() | nil
  def for_story(tenant_id, story_id) do
    case for_placement(tenant_id, story_id) do
      {rework, _branch} -> rework
      nil -> nil
    end
  end

  @doc """
  The rework object and the branch its pull request was opened on, or `nil`.

  The branch is the stage's at the reject (`payload.verify.branch`), `nil` on a reject recorded
  before it was written there. A new placement pins the dispatch's `branch` to it: otherwise it
  derives a name from the TARGET runner's declared prefixes, which need not be the prefixes of
  the runner that opened the pull request, and the session would push beside it.
  """
  @spec for_placement(Ecto.UUID.t(), Ecto.UUID.t()) :: {map(), String.t() | nil} | nil
  def for_placement(tenant_id, story_id) when is_binary(tenant_id) and is_binary(story_id) do
    with %StageEvent{} = reject <- latest_reject(tenant_id, story_id),
         false <- overtaken?(tenant_id, story_id, reject),
         %{"dispatch_id" => dispatch_id, "head_sha" => head, "pr_number" => pr} = verify <-
           get_in(reject.data, ["payload", "verify"]),
         true <- is_integer(pr) and pr >= 1 and is_binary(head) and head =~ @sha,
         %DispatchRecord{
           kind: "verify",
           agent_result_spec: "verify@1",
           story_id: ^story_id,
           agent_result: %{} = result
         } <- DispatchLedger.get_record(tenant_id, dispatch_id) do
      {%{"pr_number" => pr, "rejected_head_sha" => head, "findings" => findings(result)},
       branch(verify)}
    else
      _ -> nil
    end
  end

  @doc """
  Whether the reject `dispatch_id` recorded is still the story's last transition, with its
  claim never released: the row sits at `implementing` under the claim epoch the reject wrote,
  and no transition followed it. A release takes a new epoch, so it cannot pass. Judged on
  transitions rather than the row's `lock_version`, which effect events also bump.
  `Loopctl.Agents.VerifyVerdict` asks this on a retried job, so a release lost to a crash
  between the reject's commit and the release is made on the retry.
  """
  @spec unreleased_reject?(Ecto.UUID.t(), StoryStage.t(), Ecto.UUID.t()) :: boolean()
  def unreleased_reject?(tenant_id, %StoryStage{stage: :implementing} = row, dispatch_id)
      when is_binary(dispatch_id) do
    case latest_reject(tenant_id, row.story_id) do
      %StageEvent{claim_epoch: epoch, data: data} = reject when epoch == row.claim_epoch ->
        get_in(data, ["payload", "verify", "dispatch_id"]) == dispatch_id and
          not transitioned_since?(tenant_id, row.story_id, reject)

      _ ->
        false
    end
  end

  def unreleased_reject?(_tenant_id, _row, _dispatch_id), do: false

  defp branch(%{"branch" => branch}) when is_binary(branch) and branch != "", do: branch
  defp branch(_verify), do: nil

  # Ordered by the row's `lock_version`, which every transition bumps: a clock tie between two
  # events in one second cannot reorder them.
  defp latest_reject(tenant_id, story_id) do
    tenant_id
    |> events(story_id)
    |> where([e], e.event == "transitioned" and e.edge == "verify_rejected")
    |> order_by([e], desc: e.lock_version, desc: e.inserted_at)
    |> limit(1)
    |> one(tenant_id)
  end

  defp overtaken?(tenant_id, story_id, %StageEvent{lock_version: version}) do
    tenant_id
    |> events(story_id)
    |> where([e], e.event == "transitioned" and e.to_stage in @overtaken_by)
    |> where([e], e.lock_version > ^version)
    |> select([e], e.id)
    |> limit(1)
    |> one(tenant_id)
    |> is_binary()
  end

  defp transitioned_since?(tenant_id, story_id, %StageEvent{lock_version: version}) do
    tenant_id
    |> events(story_id)
    |> where([e], e.event == "transitioned" and e.lock_version > ^version)
    |> select([e], e.id)
    |> limit(1)
    |> one(tenant_id)
    |> is_binary()
  end

  defp events(tenant_id, story_id) do
    from e in StageEvent, where: e.tenant_id == ^tenant_id and e.story_id == ^story_id
  end

  defp one(query, tenant_id) do
    {:ok, row} = Repo.with_tenant(tenant_id, fn -> Repo.one(query) end)
    row
  end

  # The ledger row was validated against `verify@1` when it was recorded, whose caps are the
  # contract's; held to them again here so a row recorded under another schema version can never
  # make the dispatch refuse to cast. Blank entries are dropped rather than sent as `""`, which
  # the schema refuses.
  defp findings(result) do
    (Map.get(result, "findings") || [])
    |> List.wrap()
    |> Enum.filter(&sendable?/1)
    |> Enum.take(RunnerRework.max_findings())
  end

  defp sendable?(finding) when is_binary(finding),
    do: String.trim(finding) != "" and String.length(finding) <= RunnerRework.max_finding_length()

  defp sendable?(_finding), do: false
end
