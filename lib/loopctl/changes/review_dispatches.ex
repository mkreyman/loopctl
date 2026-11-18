defmodule Loopctl.Changes.ReviewDispatches do
  @moduledoc """
  Review dispatches minted by a chg intake source (US-50.3).

  There is no chg-server to hold a chg root's key, and no process could: a dispatch key lives
  at most four hours, and the operator key cannot mint under a root outside its own lineage. So
  a fleet machine's chgd asks loopctl for a review key with
  `POST /api/v1/change_events/:source_id/review_dispatch` `{change_id, revision}`, signed like
  a change event, and loopctl mints it server-side as an `:orchestrator` child of the source's
  `chg_root_dispatch_id` (`Loopctl.Dispatches.mint_chg_reviewer/4`). That key passes US-47.5's
  chg review custody unchanged: it is a strict descendant of the root, refused claim and report
  (`chg_root_review_only`) and verify and reject (`chg_root_cannot_verify`).

  ## What it trusts

  Whoever holds the source's `change_events_secret` can mint reviewers for that source's
  changes. loopctl proves the SOURCE minted the key; that the review ran apart from the
  implementer's session is the fleet's to construct (Epic 47 PRD §6). The root's own key
  expiry does not matter, only its revocation.

  ## One live dispatch per review

  Per `(source, change_id, revision)` there is one live review dispatch. A second request
  revokes the earlier one and mints afresh ONLY while no dispatch minted for that revision has
  recorded a review, so a lost response is retryable and a recorded verdict is never
  re-mintable (`409 review_already_recorded`). The change's cursor row is held `FOR UPDATE` for
  the decision, the per-change lock every event ingest takes, so two requests for one change
  never mint concurrently; the revision's `chg_review_dispatches` rows are held `FOR UPDATE`
  too, the lock a review by one of their keys takes (`ReviewCustody.hold_minted_dispatch/4`),
  so a verdict in flight and a re-mint serialise. A minted key reviews only its own revision.

  The reviewer identity is a system agent per revision (`agent_name/3`), in the reserved
  `system:` namespace no key can register into. Per revision because an api key is unique per
  (tenant, agent, role) while unrevoked: one agent per source let one live key block every
  other review of the source.

  The request body is exactly `{change_id, revision}`: the signed string is the same
  `<ts>.<body>` a change-event push signs, so a push envelope, which carries both keys among
  others, must not decode here.

  ## Refusals

  Every authentication refusal is the change-events 401 (`Loopctl.Changes.Events.signed/4`). A
  revision with no applied `submitted` event from this source is `422 revision_not_submitted`.
  A body other than `{change_id, revision}` is `400 invalid_request`. A tenant under a custody
  halt mints nothing: `503 tenant_halted`, as every other dispatch mint answers during a halt.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Agents.Agent
  alias Loopctl.Artifacts.ReviewRecord
  alias Loopctl.AuditChain
  alias Loopctl.Changes.Cursor
  alias Loopctl.Changes.Event
  alias Loopctl.Changes.Events
  alias Loopctl.Changes.ReviewDispatch
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Intake.Source
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant

  @change_id_format ~r/\A[A-Za-z0-9._:-]{1,255}\z/

  @type minted :: %{dispatch_id: Ecto.UUID.t(), api_key: String.t(), expires_at: DateTime.t()}

  @doc """
  Mints one review dispatch for a signed request to `source_id`. `input` is
  `%{raw_body:, timestamp:, signature:}`. Returns `{:ok, minted}`, `{:error, :unauthorized}`,
  `{:error, {:bad_request, "invalid_request"}}`, `{:error, {:rejected, 422,
  "revision_not_submitted"}}`, `{:error, {:rejected, 409, "review_already_recorded"}}`,
  `{:error, :busy}` or `{:error, :apply_failed}`.

  `opts`: `:now` and `:lock_timeout_ms`, as for `Loopctl.Changes.Events.signed/4`.
  """
  @spec request(term(), Events.push_input(), keyword()) ::
          {:ok, minted()}
          | {:error,
             :unauthorized
             | {:bad_request, String.t()}
             | {:rejected, pos_integer(), String.t()}
             | :busy
             | :apply_failed}
  def request(source_id, %{raw_body: raw_body} = input, opts \\ []) when is_binary(raw_body) do
    source_id
    |> Events.signed(input, opts, fn held ->
      case decode(raw_body) do
        {:ok, change_id, revision} -> mint(held, change_id, revision)
        :error -> Repo.rollback({:bad_request, "invalid_request"})
      end
    end)
    |> case do
      {:ok, {minted, entry}} ->
        AuditChain.announce_entry(entry)
        {:ok, minted}

      error ->
        error
    end
  end

  @doc """
  The reviewer agent's name for one revision of one change of a source:
  `system:chg-reviewer:<source_id>:<digest>`, the digest the first 16 hex of
  `sha256("<change_id>\\n<revision>")`. One agent per revision, not per source: an api key is
  unique per (tenant, agent, role) while unrevoked, so a per-source agent let one live review
  key block every other review of that source for its four hours.
  """
  @spec agent_name(Ecto.UUID.t(), String.t(), pos_integer()) :: String.t()
  def agent_name(source_id, change_id, revision) do
    digest =
      :crypto.hash(:sha256, "#{change_id}\n#{revision}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "system:chg-reviewer:" <> source_id <> ":" <> digest
  end

  # Exactly `{change_id, revision}`. An open match let a captured, signed change-event push
  # (which carries both keys and signs the same `<ts>.<body>` string) replay here as a mint.
  defp decode(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"change_id" => change_id, "revision" => revision} = body}
      when map_size(body) == 2 and is_binary(change_id) and is_integer(revision) and
             revision >= 1 and revision <= 2_147_483_647 ->
        if Regex.match?(@change_id_format, change_id),
          do: {:ok, change_id, revision},
          else: :error

      _ ->
        :error
    end
  end

  # Inside the held source's tenant transaction.
  defp mint(%Source{} = source, change_id, revision) do
    tenant_id = source.tenant_id
    repo = Events.repo_key(source.repo_full_name)

    with :ok <- not_halted(tenant_id),
         :ok <- lock_change(tenant_id, repo, change_id),
         :ok <- submitted(source, repo, change_id, revision),
         {:ok, agent_id} <- reviewer_agent(tenant_id, source.id, change_id, revision),
         prior = prior_dispatch_ids(source, repo, change_id, revision, agent_id),
         :ok <- no_verdict(tenant_id, prior, agent_id),
         :ok <- revoke_all(tenant_id, prior),
         :ok <- no_verdict(tenant_id, prior, agent_id),
         {:ok, %{dispatch: dispatch, raw_key: raw_key}} <-
           Dispatches.mint_chg_reviewer(tenant_id, source.chg_root_dispatch_id, agent_id) do
      entry = record!(source, repo, change_id, revision, dispatch)
      {%{dispatch_id: dispatch.id, api_key: raw_key, expires_at: dispatch.expires_at}, entry}
    else
      {:error, :chg_root_invalid} -> Repo.rollback({:refused, :chg_root_invalid})
      {:error, {:rejected, _status, _code} = rejected} -> Repo.rollback(rejected)
      {:error, reason} -> Repo.rollback({:mint_failed, reason})
    end
  end

  # A custody halt freezes dispatch minting (`LoopctlWeb.CustodySurface`). This route carries no
  # key, so `CheckCustodyHalt` never sees it; the same refusal is made here, read fresh.
  defp not_halted(tenant_id) do
    if Repo.exists?(
         from t in Tenant, where: t.id == ^tenant_id and not is_nil(t.custody_halted_at)
       ),
       do: {:error, {:rejected, 503, "tenant_halted"}},
       else: :ok
  end

  defp lock_change(tenant_id, repo, change_id) do
    locked =
      Repo.one(
        from c in Cursor,
          where: c.tenant_id == ^tenant_id and c.repo == ^repo and c.change_id == ^change_id,
          lock: "FOR UPDATE",
          select: c.id
      )

    if locked, do: :ok, else: not_submitted()
  end

  defp submitted(source, repo, change_id, revision) do
    if Repo.exists?(
         from e in Event,
           where:
             e.tenant_id == ^source.tenant_id and e.source_id == ^source.id and e.repo == ^repo and
               e.change_id == ^change_id and e.kind == "submitted" and e.revision == ^revision and
               not is_nil(e.applied_at)
       ),
       do: :ok,
       else: not_submitted()
  end

  defp not_submitted, do: {:error, {:rejected, 422, "revision_not_submitted"}}

  # Every dispatch this revision's reviewer could still hold: the recorded ones, taken FOR
  # UPDATE (the row lock `ReviewCustody.hold_minted_dispatch/4` takes inside a review, so a
  # verdict and this decision serialise), and any live dispatch of the revision's agent, which
  # covers a dispatch whose recording row rolled back after its AdminRepo mint committed.
  defp prior_dispatch_ids(source, repo, change_id, revision, agent_id) do
    recorded =
      Repo.all(
        from r in ReviewDispatch,
          where:
            r.tenant_id == ^source.tenant_id and r.source_id == ^source.id and r.repo == ^repo and
              r.change_id == ^change_id and r.revision == ^revision,
          lock: "FOR UPDATE",
          select: r.dispatch_id
      )

    live =
      AdminRepo.all(
        from d in Dispatch,
          where:
            d.tenant_id == ^source.tenant_id and d.agent_id == ^agent_id and is_nil(d.revoked_at),
          select: d.id
      )

    Enum.uniq(recorded ++ live)
  end

  # Checked before AND after the revoke: a review that committed between the first read and the
  # revocation is caught by the second, so its verdict is never followed by a fresh key. A
  # verdict by the revision's agent counts too, whichever of its dispatches recorded it.
  defp no_verdict(tenant_id, dispatch_ids, agent_id) do
    if Repo.exists?(
         from rr in ReviewRecord,
           where:
             rr.tenant_id == ^tenant_id and
               (rr.reviewer_dispatch_id in ^dispatch_ids or rr.reviewer_agent_id == ^agent_id)
       ),
       do: {:error, {:rejected, 409, "review_already_recorded"}},
       else: :ok
  end

  defp revoke_all(tenant_id, dispatch_ids) do
    Enum.reduce_while(dispatch_ids, :ok, fn id, :ok ->
      case Dispatches.revoke(tenant_id, id) do
        {:ok, _count} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # The revision's reviewer identity. `ON CONFLICT DO NOTHING` then a read, so two first mints
  # for one revision do not fail each other.
  defp reviewer_agent(tenant_id, source_id, change_id, revision) do
    name = agent_name(source_id, change_id, revision)
    now = DateTime.utc_now()

    Repo.insert_all(
      Agent,
      [
        %{
          id: Ecto.UUID.generate(),
          tenant_id: tenant_id,
          name: name,
          agent_type: :orchestrator,
          status: :active,
          last_seen_at: now,
          metadata: %{"source_id" => source_id, "change_id" => change_id, "revision" => revision},
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :name]
    )

    case Repo.one(
           from a in Agent,
             where: a.tenant_id == ^tenant_id and a.name == ^name,
             select: a.id
         ) do
      nil -> {:error, :reviewer_agent_not_resolved}
      id -> {:ok, id}
    end
  end

  # The mint committed on AdminRepo already, apart from this Repo transaction. So a failure
  # here revokes the new dispatch before rolling back: a rolled-back mint leaves no live key no
  # row records. (A crash between the two is covered by the next mint for the revision, which
  # revokes every live dispatch of the revision's agent.)
  defp record!(source, repo, change_id, revision, dispatch) do
    row = %ReviewDispatch{
      tenant_id: source.tenant_id,
      source_id: source.id,
      repo: repo,
      change_id: change_id,
      revision: revision,
      dispatch_id: dispatch.id
    }

    with {:ok, _row} <- Repo.insert(row),
         {:ok, entry} <- audit(source, repo, change_id, revision, dispatch) do
      entry
    else
      {:error, reason} ->
        _ = Dispatches.revoke(source.tenant_id, dispatch.id)
        Repo.rollback({:audit_failed, reason})
    end
  end

  defp audit(source, repo, change_id, revision, dispatch) do
    AuditChain.append_in_tenant_transaction(source.tenant_id, %{
      action: "chg_review_dispatch_minted",
      actor_lineage: [],
      entity_type: "dispatch",
      entity_id: dispatch.id,
      payload: %{
        "source_id" => source.id,
        "repo" => repo,
        "change_id" => change_id,
        "revision" => revision,
        "dispatch_id" => dispatch.id
      }
    })
  end
end
