defmodule Loopctl.Changes.ReviewCustody do
  @moduledoc """
  Review custody for chg-dispatched reviews (US-47.5, Epic 47 PRD §6) — the one place that
  says what a chg story is, who may review it, which revision a review names, and whose keys
  may never certify anything.

  ## A chg story

  A story with a change binding (`Loopctl.Changes.Binding`). The binding is the truth, never
  the project's intake mode: a binding is written only by a `submitted` event a chg source
  delivered, and the custody rules below must keep applying to a story whose source was later
  switched back to `pr` or revoked. Its **chg root** is the `chg_root_dispatch_id` of the intake
  source that delivered the bound change's events. A change delivered through more than one
  source, or through a source naming no root, has NO root — and then no reviewer qualifies
  (fail closed, logged).

  ## Who may review one (AC-47.5.1)

  Only a key whose dispatch is a STRICT descendant of the story's chg root: its server-resolved
  lineage is `[root, ..., self]` with `self != root`. The root's own key and every key outside
  that subtree are refused `:chg_reviewer_required`. These checks run AFTER — never instead of —
  `Loopctl.Progress`'s own review-complete gates, which are unchanged.

  What this does NOT prove, so nobody reads more into it: every chg reviewer key sits under
  chg's root and outside every implementer's chain, so the lineage gate always passes a chg
  review whoever ran the job. loopctl proves chg-server minted the reviewer's key; that the job
  ran apart from the implementer's session is chg-server's to construct (PRD §6).

  ## Which revision (AC-47.5.2)

  `commit_sha` must be the envelope `sha` of an APPLIED `submitted` event of the story's
  CURRENT binding — a revision of the change the story follows now — or the review is refused
  `:commit_sha_not_bound`. An event held ahead of a gap is not applied, so the story has not
  moved for it, and a review of it waits (chg retries) rather than covering a revision the
  stage machine has not seen.

  ## Whose keys never certify (AC-47.5.4)

  A caller whose MINTING lineage (`Loopctl.Dispatches.minting_lineage_for_api_key/2`, revoked
  or not) is rooted at a dispatch some intake source of the tenant names as
  `chg_root_dispatch_id` — live or revoked source, `chg` or `pr` mode — is refused every
  terminal custody act (`:chg_root_cannot_verify`) and the implementer's own acts, claim and
  report (`:chg_root_review_only`). The MINTING lineage, not the live one: a chg key whose
  dispatch has expired resolves to a live lineage of `[]`, which `reject` would otherwise
  accept as an unlineaged caller. Every source, not only live `chg` ones: revoking a source,
  or switching it to `pr`, must not hand its reviewer tree the power to verify. An operator
  who CLEARS the column on a `pr` source (an audited write, `intake_source_chg_root_set`)
  lifts the refusal for that root, which is the one way back.

  ## Reads

  `AdminRepo` (or the caller's `Loopctl.Repo` tenant transaction) with an explicit `tenant_id`
  predicate on every query — the custody-read convention (`.claude/skills/tenancy-rls`).
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Artifacts.ReviewRecord
  alias Loopctl.Changes.Binding
  alias Loopctl.Changes.Event
  alias Loopctl.GitSha
  alias Loopctl.Intake.Source

  @typedoc """
  A story bound to a chg change: its CURRENT binding (`nil` only if every binding is
  superseded, which no writer produces) and its chg root (`nil` when it cannot be resolved to
  exactly one).
  """
  @type chg_story :: %{binding: Binding.t() | nil, root_id: Ecto.UUID.t() | nil}

  @typedoc "What a chg review records, programmatically, on its `review_records` row."
  @type chg_review :: %{commit_sha: String.t(), reviewer_dispatch_id: Ecto.UUID.t()}

  @doc """
  `:not_chg` for a story with no change binding, else `{:chg, chg_story}`. Reads on `repo`
  (default `AdminRepo`), tenant-scoped.
  """
  @spec chg_story(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: :not_chg | {:chg, chg_story()}
  def chg_story(repo \\ AdminRepo, tenant_id, story_id) do
    newest =
      repo.one(
        from b in Binding,
          where: b.tenant_id == ^tenant_id and b.story_id == ^story_id,
          order_by: [desc: is_nil(b.superseded_at), desc: b.inserted_at, desc: b.id],
          limit: 1
      )

    case newest do
      nil ->
        :not_chg

      %Binding{} = binding ->
        current = if is_nil(binding.superseded_at), do: binding
        {:chg, %{binding: current, root_id: chg_root(repo, tenant_id, binding)}}
    end
  end

  # The root of the ONE source that delivered this change's events. Any other count is not a
  # root anybody can be shown to descend from.
  defp chg_root(repo, tenant_id, %Binding{} = binding) do
    roots =
      repo.all(
        from s in Source,
          join: e in Event,
          on: e.source_id == s.id and e.tenant_id == s.tenant_id,
          where:
            s.tenant_id == ^tenant_id and e.tenant_id == ^tenant_id and e.repo == ^binding.repo and
              e.change_id == ^binding.change_id,
          distinct: true,
          select: {s.id, s.chg_root_dispatch_id}
      )

    case roots do
      [{_source_id, root_id}] when is_binary(root_id) ->
        root_id

      other ->
        Logger.warning(
          "chg_root_unresolved: no single chg root for a bound change; no reviewer qualifies " <>
            "tenant_id=#{tenant_id} story_id=#{binding.story_id} change_id=#{binding.change_id} " <>
            "sources=#{length(other)}"
        )

        nil
    end
  end

  @doc """
  Decides a review of a chg story by a caller with `reviewer_lineage` (server-resolved, LIVE)
  naming `commit_sha`: `{:ok, chg_review}` to record, `{:error, :chg_reviewer_required}`, or
  `{:error, :commit_sha_not_bound}` — in that order, so a caller outside chg's subtree learns
  nothing about the change's revisions.
  """
  @spec authorize_review(Ecto.UUID.t(), chg_story(), [Ecto.UUID.t()], term()) ::
          {:ok, chg_review()} | {:error, :chg_reviewer_required | :commit_sha_not_bound}
  def authorize_review(tenant_id, %{} = chg, reviewer_lineage, commit_sha) do
    with {:ok, dispatch_id} <- chg_reviewer(chg, reviewer_lineage),
         :ok <- bound_revision(tenant_id, chg, commit_sha) do
      {:ok, %{commit_sha: commit_sha, reviewer_dispatch_id: dispatch_id}}
    end
  end

  # A strict descendant of the root: the root first, at least one dispatch after it, and the
  # caller's own dispatch last. The root alone (`[root]`) and an empty lineage do not match.
  defp chg_reviewer(%{root_id: root}, [root | [_ | _] = below]) when is_binary(root),
    do: {:ok, List.last(below)}

  defp chg_reviewer(_chg, _lineage), do: {:error, :chg_reviewer_required}

  defp bound_revision(tenant_id, %{binding: %Binding{} = binding}, commit_sha) do
    bound? =
      GitSha.valid?(commit_sha) and
        AdminRepo.exists?(
          from e in Event,
            where:
              e.tenant_id == ^tenant_id and e.repo == ^binding.repo and
                e.change_id == ^binding.change_id and e.kind == "submitted" and
                e.sha == ^commit_sha and not is_nil(e.applied_at)
        )

    if bound?, do: :ok, else: {:error, :commit_sha_not_bound}
  end

  defp bound_revision(_tenant_id, _chg, _commit_sha), do: {:error, :commit_sha_not_bound}

  @doc """
  Whether `story_id` has a chg review recorded for the revision commit `sha` — what a
  `landed` event asks before it lets the merge stand (AC-47.5.5). Reads on `repo`, the event's
  own tenant transaction.
  """
  @spec reviewed_revision?(Ecto.Repo.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: boolean()
  def reviewed_revision?(repo, tenant_id, story_id, sha) when is_binary(sha) do
    repo.exists?(
      from r in ReviewRecord,
        where:
          r.tenant_id == ^tenant_id and r.story_id == ^story_id and r.commit_sha == ^sha and
            not is_nil(r.reviewer_dispatch_id)
    )
  end

  def reviewed_revision?(_repo, _tenant_id, _story_id, _sha), do: false

  @doc """
  True when `lineage`'s ROOT is a `chg_root_dispatch_id` some intake source of the tenant
  names (any status, any mode — see the moduledoc). `[]` is never chg-rooted.
  """
  @spec chg_rooted?(Ecto.UUID.t(), [Ecto.UUID.t()]) :: boolean()
  def chg_rooted?(_tenant_id, []), do: false

  def chg_rooted?(tenant_id, [root | _]) when is_binary(tenant_id) and is_binary(root) do
    AdminRepo.exists?(
      from s in Source, where: s.tenant_id == ^tenant_id and s.chg_root_dispatch_id == ^root
    )
  end

  def chg_rooted?(_tenant_id, _lineage), do: false

  @doc """
  `:ok`, or `{:error, refusal}` when the caller with minting `lineage` is chg-rooted. `refusal`
  is `:chg_root_cannot_verify` (the default; verify, reject, verify-all, bulk verify/reject,
  backfill, bulk mark-complete) or `:chg_root_review_only` (claim, bulk claim, report).
  """
  @spec refuse_chg_root(Ecto.UUID.t(), [Ecto.UUID.t()], atom()) :: :ok | {:error, atom()}
  def refuse_chg_root(tenant_id, lineage, refusal \\ :chg_root_cannot_verify)
      when refusal in [:chg_root_cannot_verify, :chg_root_review_only] do
    if chg_rooted?(tenant_id, lineage) do
      Logger.warning(
        "#{refusal}: a chg-server key attempted a custody act it may never perform " <>
          "tenant_id=#{tenant_id} lineage_root=#{hd(lineage)}"
      )

      {:error, refusal}
    else
      :ok
    end
  end

  @doc """
  The lineage the chg-root refusal judges, from a custody call's `opts`:
  `:caller_minting_lineage` (the controllers resolve it with
  `Loopctl.Dispatches.minting_lineage_for_api_key/2`), else the first of `fallbacks` the opts
  carry — the call's own live lineage — else `[]`. Never request data.
  """
  @spec caller_lineage(keyword(), [atom()]) :: [Ecto.UUID.t()]
  def caller_lineage(opts, fallbacks) do
    Enum.find_value([:caller_minting_lineage | fallbacks], [], fn key ->
      case Keyword.get(opts, key) do
        [_ | _] = lineage -> lineage
        _ -> nil
      end
    end)
  end
end
