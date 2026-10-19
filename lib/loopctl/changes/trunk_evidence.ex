defmodule Loopctl.Changes.TrunkEvidence do
  @moduledoc """
  The CI-evidence input of story verification for a story bound to a chg change (US-47.6,
  Epic 47 PRD §7). A chg story's CI is not a pull request's checks: chg lands the change on
  trunk and its trunk verifier advances `refs/heads/verified/master` (ff-only) past every
  commit whose full suite passed. So the evidence is two facts, both about the CURRENT
  binding's newest APPLIED `landed` event:

  1. its TRUNK commit — `data.merge_sha`, the squash chg wrote onto trunk, never the envelope
     `sha` (the revision commit, which is what `Loopctl.Changes.ReviewCustody` certifies and
     which is not on trunk whenever trunk moved) — is an ancestor of, or equal to,
     `verified/master`, asked of the forge by sha (`PullRequestSource.contains?/3`); and
  2. no APPLIED `reverted` event of the same change has a higher `event_seq` than that
     landing. A re-landing after a revert is a newer landing, so it is judged afresh.

  A story with no change binding is `:not_chg` and every verify path takes exactly the gates
  it took before.

  ## No local short-circuit

  The `verified` event's `data.sha` (`story_stages.trunk_verified_sha`) is chg's claim at
  delivery time, not the ref. Even `merge_sha == trunk_verified_sha` is not taken as the
  answer: the ref is the one fact chg's deploy guard reads, and a verify that skipped it
  would certify on a delivery the ref may since have contradicted. One bounded read per
  verify is the whole cost.

  ## Two halves, and the forge call is outside every transaction

  `assess/3` (one story) and `assess_many/3` (a batch) run BEFORE the verify transaction and
  make the forge call there, so no story lock is ever held across a network read.
  `ensure_trunk_verified/4` runs INSIDE the transaction, under the story lock, after
  `ReviewCustody.ensure_landed_review/3`. It re-reads the landing and the revert from the
  database and applies the assessment only when it was made for the SAME landing; a landing
  that arrived in between answers unevaluated (`landing_changed`), never the stale answer.

  ## What each answer means to the caller

  - `:ok` — not a chg story, or the landing is in `verified/master` and not reverted
  - `{:error, :chg_landing_not_trunk_verified}` — the forge answered and the trunk commit is
    NOT in `verified/master` (`behind` or `diverged`), or the landing named no valid trunk
    commit, or there is no current landing at all
  - `{:error, :chg_landing_reverted}` — an applied `reverted` follows the landing
  - `{:error, {:chg_trunk_unevaluated, reason, retry_after_seconds}}` — nothing was decided.
    Every forge failure lands here, never in a pass: a timeout, an unreachable forge, a 5xx
    or a rate limit (`forge_unavailable`, with the forge's own delay when it named one), a
    401 / 403 / 422 / other status (`forge_unauthorized`, `forge_forbidden`,
    `forge_rejected`), an unreadable body (`forge_unreadable`), a 404 (`trunk_ref_not_found`:
    `verified/master` does not exist yet — chg has not verified anything — or the trunk commit
    is not on the forge yet; neither is a failure of the story), no credential for the
    repository (`credential_unavailable`), and `landing_changed`.

  ## Reads

  `AdminRepo` (or the verify transaction's repo) with an explicit `tenant_id` predicate on
  every query, the custody-read convention.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Binding
  alias Loopctl.Changes.Event
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.PullRequestSource
  alias Loopctl.GitSha
  alias Loopctl.Intake.Source
  alias Loopctl.Verification.Credential

  @verified_ref "verified/master"

  # The `Retry-After` an unevaluated answer carries when the forge named no delay — the merge
  # precondition's floor, so the two forge-backed 503s read alike.
  @default_retry_after_seconds 30

  # A batch asks the forge for at most this many stories at once; each call is bounded by the
  # forge client's own connect (2 s) and receive (5 s) timeouts, and the task by this.
  @batch_concurrency 4
  @batch_task_timeout_ms 15_000

  @type reason :: String.t()

  @type outcome ::
          :ancestor
          | :not_ancestor
          | :no_trunk_commit
          | :reverted
          | {:unevaluated, reason(), pos_integer()}

  @typedoc """
  What `assess/3` found BEFORE the transaction: `:not_chg`, or the landing it judged
  (`nil` when there was none) and the outcome.
  """
  @type assessment :: :not_chg | %{landed_event_id: Ecto.UUID.t() | nil, outcome: outcome() | nil}

  @type refusal ::
          :chg_landing_not_trunk_verified
          | :chg_landing_reverted
          | {:chg_trunk_unevaluated, reason(), pos_integer()}

  @doc "The ref a chg landing must be contained in."
  @spec verified_ref() :: String.t()
  def verified_ref, do: @verified_ref

  @doc "The `Retry-After` an unevaluated answer carries when the forge named none."
  @spec default_retry_after_seconds() :: pos_integer()
  def default_retry_after_seconds, do: @default_retry_after_seconds

  @doc """
  The assessment for one story, made OUTSIDE any transaction. Asks the forge only for a chg
  story whose current landing is not already reverted and names a valid trunk commit.
  """
  @spec assess(Ecto.UUID.t(), Ecto.UUID.t()) :: assessment()
  def assess(tenant_id, story_id) do
    case facts(AdminRepo, tenant_id, story_id) do
      :not_chg -> :not_chg
      {:chg, nil} -> %{landed_event_id: nil, outcome: nil}
      {:chg, landing} -> %{landed_event_id: landing.id, outcome: judge(tenant_id, landing)}
    end
  end

  @doc """
  `assess/2` for a batch, as a map keyed by story id. One query finds the bound stories; only
  they are assessed, the forge calls `@batch_concurrency` at a time. A call that outlives its
  task bound is `forge_unavailable` for that story.
  """
  @spec assess_many(Ecto.UUID.t(), [Ecto.UUID.t()]) :: %{optional(Ecto.UUID.t()) => assessment()}
  def assess_many(tenant_id, story_ids) when is_list(story_ids) do
    ids = Enum.filter(story_ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))

    bound =
      AdminRepo.all(
        from b in Binding,
          where: b.tenant_id == ^tenant_id and b.story_id in ^ids,
          distinct: true,
          select: b.story_id
      )

    landings =
      Enum.map(bound, fn story_id -> {story_id, facts(AdminRepo, tenant_id, story_id)} end)

    landings
    |> Task.async_stream(
      fn
        {story_id, {:chg, nil}} ->
          {story_id, %{landed_event_id: nil, outcome: nil}}

        {story_id, {:chg, landing}} ->
          {story_id, %{landed_event_id: landing.id, outcome: judge(tenant_id, landing)}}

        {story_id, :not_chg} ->
          {story_id, :not_chg}
      end,
      max_concurrency: @batch_concurrency,
      timeout: @batch_task_timeout_ms,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(landings)
    |> Map.new(fn
      {{:ok, {story_id, assessment}}, _landing} ->
        {story_id, assessment}

      {{:exit, _reason}, {story_id, {:chg, landing}}} ->
        {story_id,
         %{
           landed_event_id: landing && landing.id,
           outcome: {:unevaluated, "forge_unavailable", @default_retry_after_seconds}
         }}

      {{:exit, _reason}, {story_id, :not_chg}} ->
        {story_id, :not_chg}
    end)
  end

  @doc """
  The in-transaction half: `:ok` or a refusal (see the moduledoc), from the landing as the
  database holds it NOW and the `assessment` made before the transaction. A chg story with no
  assessment, or one made for a different landing, is unevaluated `landing_changed`. Reads
  on `repo` (default `AdminRepo`), tenant-scoped.
  """
  @spec ensure_trunk_verified(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t(), assessment() | nil) ::
          :ok | {:error, refusal()}
  def ensure_trunk_verified(repo \\ AdminRepo, tenant_id, story_id, assessment) do
    case facts(repo, tenant_id, story_id) do
      :not_chg ->
        :ok

      {:chg, nil} ->
        {:error, :chg_landing_not_trunk_verified}

      {:chg, %{reverted?: true}} ->
        refuse(tenant_id, story_id, :chg_landing_reverted)

      {:chg, %{id: landed_id}} ->
        case assessment do
          %{landed_event_id: ^landed_id, outcome: outcome} ->
            decide(tenant_id, story_id, outcome)

          _stale_or_missing ->
            unevaluated(tenant_id, story_id, "landing_changed", @default_retry_after_seconds)
        end
    end
  end

  # -- the facts -----------------------------------------------------------------------------

  # `:not_chg` when the story has no binding at all; `{:chg, nil}` when its newest binding is
  # superseded or its change has no applied landing; else the newest applied landing.
  defp facts(repo, tenant_id, story_id) do
    newest =
      repo.one(
        from b in Binding,
          where: b.tenant_id == ^tenant_id and b.story_id == ^story_id,
          order_by: [desc: is_nil(b.superseded_at), desc: b.inserted_at, desc: b.id],
          limit: 1
      )

    case newest do
      nil -> :not_chg
      %Binding{superseded_at: nil} = binding -> {:chg, landing(repo, tenant_id, binding)}
      %Binding{} -> {:chg, nil}
    end
  end

  defp landing(repo, tenant_id, %Binding{} = binding) do
    case newest_landing(repo, tenant_id, binding) do
      nil ->
        nil

      %{} = landed ->
        %{
          id: landed.id,
          repo: landed.repo,
          merge_sha: merge_sha(landed.data),
          reverted?: reverted_after?(repo, tenant_id, binding, landed.event_seq)
        }
    end
  end

  # The newest APPLIED `landed` event of the binding's change, with the repository of the
  # source that delivered it — the intake source's own `repo_full_name`, which the credential
  # is asked for, as every other forge read asks.
  defp newest_landing(repo, tenant_id, binding) do
    repo.one(
      from e in Event,
        join: s in Source,
        on: s.id == e.source_id and s.tenant_id == e.tenant_id,
        where:
          e.tenant_id == ^tenant_id and e.repo == ^binding.repo and
            e.change_id == ^binding.change_id and e.kind == "landed" and
            not is_nil(e.applied_at),
        order_by: [desc: e.event_seq],
        limit: 1,
        select: %{id: e.id, event_seq: e.event_seq, data: e.data, repo: s.repo_full_name}
    )
  end

  defp reverted_after?(repo, tenant_id, binding, landed_seq) do
    repo.exists?(
      from e in Event,
        where:
          e.tenant_id == ^tenant_id and e.repo == ^binding.repo and
            e.change_id == ^binding.change_id and e.kind == "reverted" and
            not is_nil(e.applied_at) and e.event_seq > ^landed_seq
    )
  end

  defp merge_sha(%{"merge_sha" => sha}) when is_binary(sha) do
    if GitSha.valid?(sha), do: sha
  end

  defp merge_sha(_data), do: nil

  # -- the forge -----------------------------------------------------------------------------

  defp judge(_tenant_id, %{reverted?: true}), do: :reverted
  defp judge(_tenant_id, %{merge_sha: nil}), do: :no_trunk_commit

  defp judge(tenant_id, %{repo: repo, merge_sha: sha}) do
    with {:ok, forge_repo} <- Credential.repo(tenant_id, repo),
         {:ok, contained?} <- PullRequestSource.contains?(forge_repo, sha, @verified_ref) do
      if contained?, do: :ancestor, else: :not_ancestor
    else
      {:error, reason} -> {:unevaluated, code(reason), retry_after(reason)}
    end
  end

  defp code(:credential_unavailable), do: "credential_unavailable"
  defp code({:github_api_error, 404}), do: "trunk_ref_not_found"
  defp code({:github_api_error, 401}), do: "forge_unauthorized"
  defp code({:github_api_error, 403}), do: "forge_forbidden"

  defp code(reason) do
    cond do
      MergePrecondition.transient?(reason) -> "forge_unavailable"
      match?({:github_api_error, _}, reason) -> "forge_rejected"
      true -> "forge_unreadable"
    end
  end

  defp retry_after(:credential_unavailable), do: Credential.configuration_retry_seconds()

  defp retry_after(reason),
    do: MergePrecondition.retry_after(reason) || @default_retry_after_seconds

  # -- deciding ------------------------------------------------------------------------------

  defp decide(_tenant_id, _story_id, :ancestor), do: :ok

  defp decide(tenant_id, story_id, :reverted),
    do: refuse(tenant_id, story_id, :chg_landing_reverted)

  defp decide(tenant_id, story_id, {:unevaluated, reason, retry_after}),
    do: unevaluated(tenant_id, story_id, reason, retry_after)

  defp decide(tenant_id, story_id, _not_ancestor_or_no_commit),
    do: refuse(tenant_id, story_id, :chg_landing_not_trunk_verified)

  defp refuse(tenant_id, story_id, code) do
    Logger.info("#{code}: tenant_id=#{tenant_id} story_id=#{story_id}")
    {:error, code}
  end

  defp unevaluated(tenant_id, story_id, reason, retry_after) do
    Logger.warning(
      "chg_trunk_unevaluated: tenant_id=#{tenant_id} story_id=#{story_id} reason=#{reason} " <>
        "retry_after=#{retry_after}"
    )

    {:error, {:chg_trunk_unevaluated, reason, retry_after}}
  end
end
