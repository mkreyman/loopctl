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
  that arrived in between answers unevaluated (`landing_changed`), never the stale answer, as
  does a story with no assessment at all (its local gates refused before the read and pass
  now). The bindings and landings are read through `Loopctl.Changes.Landings`, the reads the
  landed-review gate makes, so the two gates always judge the same landing.

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
  alias Loopctl.Changes.Landings
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.PullRequestSource
  alias Loopctl.GitSha
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
  story whose current landing is not already reverted and names a valid trunk commit, and
  only when `ask?` (called with no arguments, just before the forge read) answers true: the
  caller passes its own cheap local gates there, so a verify they would refuse spends no
  credentialed forge call. A declined ask is no assessment (`nil`), which the in-transaction
  half answers as unevaluated `landing_changed` should those gates have passed since.
  """
  @spec assess(Ecto.UUID.t(), Ecto.UUID.t(), (-> boolean())) :: assessment() | nil
  def assess(tenant_id, story_id, ask? \\ fn -> true end) do
    tenant_id
    |> assess_many([story_id], fn _story_id -> ask?.() end)
    |> Map.get(story_id, :not_chg)
  end

  @doc """
  `assess/3` for a batch, as a map keyed by story id; a story with no change binding is
  absent (`:not_chg`). The bindings, landings and reverts are read in one query each; `ask?`
  (called with the story id) is asked only for the stories that would make a forge call, and
  those calls run `@batch_concurrency` at a time. A call that outlives its task bound is
  `forge_unavailable` for that story.
  """
  @spec assess_many(Ecto.UUID.t(), [Ecto.UUID.t()], (Ecto.UUID.t() -> boolean())) ::
          %{optional(Ecto.UUID.t()) => assessment() | nil}
  def assess_many(tenant_id, story_ids, ask? \\ fn _story_id -> true end)
      when is_list(story_ids) do
    ids = Enum.filter(story_ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))
    facts = facts_many(AdminRepo, tenant_id, ids)

    {to_forge, decided} =
      Enum.split_with(facts, fn {story_id, landing} ->
        needs_forge?(landing) and ask?.(story_id)
      end)

    decided =
      Map.new(decided, fn
        {story_id, nil} -> {story_id, %{landed_event_id: nil, outcome: nil}}
        {story_id, landing} -> {story_id, local_assessment(landing)}
      end)

    to_forge
    |> Task.async_stream(
      fn {story_id, landing} ->
        {story_id, %{landed_event_id: landing.id, outcome: judge(tenant_id, landing)}}
      end,
      max_concurrency: @batch_concurrency,
      timeout: @batch_task_timeout_ms,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(to_forge)
    |> Map.new(fn
      {{:ok, {story_id, assessment}}, _landing} ->
        {story_id, assessment}

      {{:exit, _reason}, {story_id, landing}} ->
        {story_id,
         %{
           landed_event_id: landing.id,
           outcome: {:unevaluated, "forge_unavailable", @default_retry_after_seconds}
         }}
    end)
    |> Map.merge(decided)
  end

  # A landing the forge must be asked about: not reverted, and naming a valid trunk commit.
  defp needs_forge?(%{reverted?: false, merge_sha: sha}) when is_binary(sha), do: true
  defp needs_forge?(_landing), do: false

  # A landing decided without the forge, or one whose forge read the caller declined (`nil`).
  defp local_assessment(%{reverted?: true} = landing),
    do: %{landed_event_id: landing.id, outcome: :reverted}

  defp local_assessment(%{merge_sha: nil} = landing),
    do: %{landed_event_id: landing.id, outcome: :no_trunk_commit}

  defp local_assessment(_declined), do: nil

  @doc """
  The in-transaction half: `:ok` or a refusal (see the moduledoc), from the landing as the
  database holds it NOW and the `assessment` made before the transaction. A chg story with no
  assessment, or one made for a different landing, is unevaluated `landing_changed`. Reads
  on `repo` (default `AdminRepo`), tenant-scoped.
  """
  @spec ensure_trunk_verified(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t(), assessment() | nil) ::
          :ok | {:error, refusal()}
  def ensure_trunk_verified(repo \\ AdminRepo, tenant_id, story_id, assessment) do
    case Map.fetch(facts_many(repo, tenant_id, [story_id]), story_id) do
      :error ->
        :ok

      {:ok, nil} ->
        {:error, :chg_landing_not_trunk_verified}

      {:ok, %{reverted?: true}} ->
        refuse(tenant_id, story_id, :chg_landing_reverted)

      {:ok, %{id: landed_id}} ->
        case assessment do
          %{landed_event_id: ^landed_id, outcome: outcome} ->
            decide(tenant_id, story_id, outcome)

          _stale_or_missing ->
            unevaluated(tenant_id, story_id, "landing_changed", @default_retry_after_seconds)
        end
    end
  end

  # -- the facts -----------------------------------------------------------------------------

  # Keyed by story id, for the stories that have a binding: `nil` when the newest binding is
  # superseded or its change has no applied landing, else that landing. Three queries for any
  # batch: the bindings and the landings through `Loopctl.Changes.Landings` — the reads the
  # landed-review gate makes, so the two gates judge the same landing — and the reverts.
  defp facts_many(repo, tenant_id, story_ids) do
    bindings = Landings.newest_bindings(repo, tenant_id, story_ids)
    current = for {_story_id, %Binding{superseded_at: nil} = b} <- bindings, do: b
    landings = Landings.newest_applied_landings(repo, tenant_id, current)
    reverts = newest_reverts(repo, tenant_id, current)

    Map.new(bindings, fn
      {story_id, %Binding{superseded_at: nil} = binding} ->
        key = {binding.repo, binding.change_id}
        {story_id, landing(Map.get(landings, key), Map.get(reverts, key))}

      {story_id, %Binding{}} ->
        {story_id, nil}
    end)
  end

  defp landing(nil, _revert_seq), do: nil

  defp landing(landed, revert_seq) do
    %{
      id: landed.id,
      repo: landed.source_repo,
      merge_sha: merge_sha(landed.data),
      reverted?: is_integer(revert_seq) and revert_seq > landed.event_seq
    }
  end

  # The highest `event_seq` of an APPLIED `reverted` event of each binding's change.
  defp newest_reverts(_repo, _tenant_id, []), do: %{}

  defp newest_reverts(repo, tenant_id, bindings) do
    repo.all(
      from e in Event,
        where:
          e.tenant_id == ^tenant_id and e.repo in ^Enum.map(bindings, & &1.repo) and
            e.change_id in ^Enum.map(bindings, & &1.change_id) and e.kind == "reverted" and
            not is_nil(e.applied_at),
        group_by: [e.repo, e.change_id],
        select: {{e.repo, e.change_id}, max(e.event_seq)}
    )
    |> Map.new()
  end

  defp merge_sha(%{"merge_sha" => sha}) when is_binary(sha) do
    if GitSha.valid?(sha), do: sha
  end

  defp merge_sha(_data), do: nil

  # -- the forge -----------------------------------------------------------------------------

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
