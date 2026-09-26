defmodule Loopctl.Progress do
  @moduledoc """
  Context module for two-tier progress tracking.

  Implements the core trust model where:
  - **Only agents** can write `agent_status` (contract, claim, start, report, unclaim)
  - **Only orchestrators** can write `verified_status` (verify, reject)

  All state transitions are atomic (Ecto.Multi) with audit logging and
  pessimistic locking where needed for concurrency safety.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Artifacts.ArtifactReport
  alias Loopctl.Artifacts.ReviewRecord
  alias Loopctl.Artifacts.VerificationResult
  alias Loopctl.Audit
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Capabilities
  alias Loopctl.Delivery.DispatchLease
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches
  alias Loopctl.Repo
  alias Loopctl.Runners.Capacity
  alias Loopctl.Tenants
  alias Loopctl.TokenUsage
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.WorkBreakdown.Dependencies
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ReviewKnowledgeWorker
  alias Loopctl.Workers.WebhookDeliveryWorker

  # --- Agent Status Transitions (US-7.1) ---

  @doc """
  Contracts a story: agent acknowledges the story's ACs.

  Transitions agent_status from `pending` to `contracted`.
  The agent must echo the story_title and ac_count to prove they read the story.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `params` -- map with `story_title` (string) and `ac_count` (integer)
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if not in pending state
  - `{:error, :story_held}` if its delivery stage row is at a held stage — `escalated`, `done`
    or `failed` (`Loopctl.Delivery.Stages.held_story_ids/2`)
  - `{:error, :title_mismatch}` if echoed title doesn't match
  - `{:error, :ac_count_mismatch}` if echoed AC count doesn't match
  """
  @spec contract_story(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Story.t()}
          | {:error, atom() | {:contract_mismatch, map()} | {:invalid_transition, map()}}
  def contract_story(tenant_id, story_id, params, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    skip_contract_check = Keyword.get(opts, :skip_contract_check, false)

    story_title = Map.get(params, "story_title") || Map.get(params, :story_title)
    ac_count = Map.get(params, "ac_count") || Map.get(params, :ac_count)

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes ->
        lock_story(tenant_id, story_id)
      end)
      |> Multi.run(:validate, fn _repo, %{lock: story} ->
        with :ok <- validate_transition_ctx(story, :contracted, "contract"),
             :ok <- maybe_validate_contract(story, story_title, ac_count, skip_contract_check) do
          {:ok, story}
        end
      end)
      |> Multi.run(:not_held, fn _repo, %{lock: story} -> not_held(tenant_id, story.id) end)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        now = DateTime.utc_now()

        story
        |> Ecto.Changeset.change(%{
          agent_status: :contracted,
          updated_at: now
        })
        |> AdminRepo.update()
      end)
      |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
        contract_audit_attrs(tenant_id, updated, old, actor_id, actor_label, agent_id)
      end)
      |> EventGenerator.generate_events(:webhook_events, fn %{story: updated, lock: old} ->
        contract_event_params(tenant_id, updated, old, agent_id)
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :lock, reason, _} -> {:error, reason}
      {:error, :validate, reason, _} -> {:error, reason}
      {:error, :not_held, reason, _} -> {:error, reason}
      {:error, :story, changeset, _} -> {:error, changeset}
    end
  end

  # The audit entry and webhook a `pending -> contracted` writes, built in ONE place for both
  # writers of it: `contract_story/4` and `recontract_in_transaction/3`.
  defp contract_audit_attrs(tenant_id, updated, old, actor_id, actor_label, agent_id) do
    %{
      tenant_id: tenant_id,
      entity_type: "story",
      entity_id: updated.id,
      action: "status_changed",
      actor_type: "api_key",
      actor_id: actor_id,
      actor_label: actor_label,
      old_state: %{"agent_status" => to_string(old.agent_status)},
      new_state: %{
        "agent_status" => to_string(updated.agent_status),
        "agent_id" => agent_id
      }
    }
  end

  defp contract_event_params(tenant_id, updated, old, agent_id) do
    %{
      tenant_id: tenant_id,
      event_type: "story.status_changed",
      project_id: updated.project_id,
      payload: %{
        "event" => "story.status_changed",
        "story_id" => updated.id,
        "project_id" => updated.project_id,
        "epic_id" => updated.epic_id,
        "old_status" => to_string(old.agent_status),
        "new_status" => to_string(updated.agent_status),
        "agent_id" => agent_id,
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
      }
    }
  end

  @doc """
  Re-contracts a RELEASED story — `pending -> contracted` — as a write inside the caller's
  `AdminRepo` transaction (US-44.4, #877). `Loopctl.Delivery.Stages.recontract_released/4` is
  the caller: every claim release that leaves a delivery story's stage row at `queued`, as a
  step of the release's own transaction, so the release and the re-contract commit together or
  not at all.

  NOT `contract_story/4`, which is a transaction of its own with its own lock, its own refusals
  and its own error shapes, and which nested inside a release was one more set of shapes every
  release's result `case` had to know. This takes no lock (the release already holds the
  story `FOR UPDATE`), and opens no transaction. The UPDATE is GUARDED on
  `agent_status = pending`: a story that is not pending is left exactly as it is and
  returned. It writes the same audit entry and `story.status_changed` webhook
  `contract_story/4` writes, from the same builders, attributed to `actor_label` with no key
  or agent — the release's system act, as it was when this went through `contract_story/4`.

  Returns `{:ok, story}` as it now stands — re-contracted, or untouched when it was not
  pending. There is no refusal to return: the audit entry is built from literals and
  `story.id`, so its changeset is valid by construction, and it is inserted with `insert!` —
  a database refusal raises and rolls back the caller's transaction, every caller's alike. A
  webhook row that cannot be written is logged and skipped, as for every non-`Multi` event
  writer here (`insert_events_with_delivery/4`).

  Raises `ArgumentError` outside a transaction, like `Stages.follow_release/5`: on its own the
  UPDATE and the audit insert would commit separately.
  """
  @spec recontract_in_transaction(Ecto.UUID.t(), Story.t(), String.t() | nil) :: {:ok, Story.t()}
  def recontract_in_transaction(tenant_id, %Story{} = story, actor_label) do
    unless AdminRepo.in_transaction?(),
      do:
        raise(ArgumentError, "recontract_in_transaction/3 runs inside the releasing transaction")

    from(s in Story,
      where: s.id == ^story.id and s.tenant_id == ^tenant_id and s.agent_status == :pending,
      select: s
    )
    |> AdminRepo.update_all(set: [agent_status: :contracted, updated_at: DateTime.utc_now()])
    |> case do
      {1, [contracted]} ->
        tenant_id
        |> contract_audit_attrs(contracted, story, nil, actor_label, nil)
        |> Map.delete(:tenant_id)
        |> AuditLog.create_changeset()
        |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
        |> AdminRepo.insert!()

        event = contract_event_params(tenant_id, contracted, story, nil)
        insert_events_with_delivery(tenant_id, event.event_type, event.project_id, event.payload)
        {:ok, contracted}

      {0, []} ->
        {:ok, story}
    end
  end

  @doc """
  Claims a story: assigns the agent to a contracted story.

  Transitions agent_status from `contracted` to `assigned`.
  Uses pessimistic locking (SELECT FOR UPDATE) to prevent race conditions.

  The claim carries a LEASE and a FENCE (#803): `claimed_until` is set to now plus
  `claim_lease_seconds/0`, and `claim_epoch` is incremented, both inside the same
  transaction as the transition. The claimant keeps the claim by calling
  `renew_claim/3` before the lease runs out; otherwise
  `Loopctl.Workers.ReclaimExpiredClaimsWorker` releases it (`reclaim_expired_claim/3`).
  The returned story carries both, and the claimant echoes `claim_epoch` on later
  calls so a message from a claim that has since ended is refused.

  ## A lease capped at a dispatch deadline (#879)

  With `lease_until:` the claim's lease is that instant instead of now plus
  `claim_lease_seconds/0`, and the same instant is stored as `claim_lease_cap`: no renewal
  moves `claimed_until` (`renew_claim/3`, `grant_renewal_grace/2`), and the
  `stories_claim_lease_within_cap` CHECK holds every other writer to it. Only
  `Loopctl.Delivery.Placement` passes it, and it is the dispatch's `deadline_at`: the runner
  stops the session by it, so a claim outliving it would hold the story for a session that no
  longer exists. The cap moves only forward, only while the claim is live, and only on the
  dispatch's own events — the runner's ACCEPTANCE and a RESUME of the dispatch
  (`reanchor_dispatch_lease/3`). Without the option nothing changes: the global lease, and a
  NULL cap.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`, and optionally
    `:lease_until` (a `DateTime`, see above)

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if not in contracted state
  - `{:error, :story_held}` if its delivery stage row is at a held stage
    (`Loopctl.Delivery.Stages.held_story_ids/2`): `escalated`, which is claimable again once
    `Loopctl.Delivery.Escalations.resolve/3` sends it to `queued`, or `done` / `failed`,
    which never are
  """
  @spec claim_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Story.t()} | {:error, atom() | {:invalid_transition, map()}}
  def claim_story(tenant_id, story_id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes ->
        lock_story(tenant_id, story_id)
      end)
      |> Multi.run(:validate, fn _repo, %{lock: story} ->
        case validate_transition_ctx(story, :assigned, "claim") do
          :ok -> {:ok, story}
          error -> error
        end
      end)
      |> Multi.run(:not_held, fn _repo, %{lock: story} -> not_held(tenant_id, story.id) end)
      |> Multi.run(:check_deps, fn _repo, %{lock: story} ->
        check_claim_dependencies(tenant_id, story)
      end)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        now = DateTime.utc_now()
        dispatch_id = Keyword.get(opts, :dispatch_id)

        changes =
          Map.merge(
            %{
              agent_status: :assigned,
              assigned_agent_id: agent_id,
              assigned_at: now
            },
            claim_lease_change(story, now, Keyword.get(opts, :lease_until))
          )

        # US-26.2.2 AC-3: record implementer's dispatch at claim time
        changes =
          if dispatch_id,
            do: Map.put(changes, :implementer_dispatch_id, dispatch_id),
            else: changes

        story
        |> Ecto.Changeset.change(changes)
        |> AdminRepo.update()
      end)
      # US-26.3.1 AC-5: mint the start_cap the claimer needs for POST /start.
      #
      # INSIDE the transaction, deliberately. It used to run after the commit, so
      # a mint failure on a KEYED tenant left a CLAIMED story with no capability
      # and no way back: `start` demands one, `GET /capabilities` only delivers
      # tokens that were already minted, and `recover-cap` needs an
      # `implementer_dispatch_id` a legacy bearer claim never writes. The agent
      # held a story it could not start and could not recover.
      #
      # Rolling the claim back instead leaves the story exactly where it was, so
      # the remedy is the one thing the agent can always do: claim again. The cost
      # is that a secret-store blip fails the claim rather than half-completing it
      # — which is the correct trade for an operation whose whole output is a
      # credential.
      # #803: a claim bumps the epoch too, so the stage row follows it in THIS transaction.
      # Its stage does not change — the loop's own advance(queued -> claimed) does that —
      # but a row left at the old epoch (a story claimed while still at `detected` or
      # `triaged`) would be refused on every advance with nothing able to move it.
      |> Multi.run(:stage, fn _repo, %{story: updated} ->
        Stages.follow_claim(tenant_id, updated.id, updated.claim_epoch, actor_label: actor_label)
      end)
      |> Multi.run(:mint_cap, fn _repo, %{story: updated} ->
        mint_cap(tenant_id, "start_cap", updated.id, Keyword.get(opts, :lineage, []))
      end)
      |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: updated.id,
          action: "status_changed",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{"agent_status" => to_string(old.agent_status)},
          new_state: %{
            "agent_status" => to_string(updated.agent_status),
            "assigned_agent_id" => agent_id,
            "agent_id" => agent_id,
            "claimed_until" => DateTime.to_iso8601(updated.claimed_until),
            "claim_lease_cap" => iso8601_or_nil(updated.claim_lease_cap),
            "claim_epoch" => updated.claim_epoch
          }
        }
      end)
      |> EventGenerator.generate_events(:webhook_events, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          event_type: "story.status_changed",
          project_id: updated.project_id,
          payload: %{
            "event" => "story.status_changed",
            "story_id" => updated.id,
            "project_id" => updated.project_id,
            "epic_id" => updated.epic_id,
            "old_status" => to_string(old.agent_status),
            "new_status" => to_string(updated.agent_status),
            "agent_id" => agent_id,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)

    multi |> AdminRepo.transaction() |> claim_result()
  end

  # Contract's and claim's refusal of a story whose delivery stage is held — `escalated`,
  # `done` or `failed` — through the one definition in `Loopctl.Delivery.Stages`. Asked under
  # the story lock each caller already holds: every stage transition takes the story FOR
  # SHARE first, so none can land between this read and the caller's commit.
  defp not_held(tenant_id, story_id) do
    if MapSet.member?(Stages.held_story_ids(tenant_id, [story_id]), story_id),
      do: {:error, :story_held},
      else: {:ok, :not_held}
  end

  defp claim_result({:ok, %{story: updated, mint_cap: cap}}) do
    # #621: the token is returned on the struct's virtual :minted_capability
    # field so the caller can present it to POST /start.
    {:ok, %{updated | minted_capability: cap}}
  end

  # Already logged with the underlying reason in mint_cap/4. The story is
  # untouched — nothing was claimed. A transient mint failure is retryable; a key
  # that is absent or superseded is not, and answering that one as retryable made
  # agents hot-loop a claim only an operator can unblock.
  defp claim_result({:error, :mint_cap, {:capability_key_unavailable, _reason}, _changes}),
    do: {:error, :capability_key_unavailable}

  defp claim_result({:error, :mint_cap, {:capability_mint_failed, _reason}, _changes}),
    do: {:error, :capability_mint_failed}

  # The steps whose failure IS the caller's answer: the story is not there
  # (`:lock`), the transition is illegal (`:validate`), its stage is held (`:not_held`), its
  # dependencies are unmet (`:check_deps`), or its own changeset did not validate (`:story`).
  defp claim_result({:error, step, reason, _changes})
       when step in [:lock, :validate, :not_held, :check_deps],
       do: {:error, reason}

  defp claim_result({:error, :story, changeset, _changes}), do: {:error, changeset}

  # Every OTHER failing step (`:audit`, `:webhook_events`, whatever the multi grows
  # next) failed SERVER-side and rolled the claim back, so it answers ONE stable
  # reason instead of its own. Forwarding the raw term only MOVED the 500: the
  # caller's `case` enumerates reasons, so a FunctionClauseError here came back as
  # a CaseClauseError one frame later — and an audit-log changeset forwarded to the
  # fallback told the caller its request body was invalid, naming columns it never
  # sent. The term goes to the log; the caller gets the code.
  defp claim_result({:error, step, reason, _changes}) do
    Logger.error(
      "claim_step_failed: the claim rolled back and nothing was changed — " <>
        "step=#{inspect(step)} reason=#{inspect(reason)}"
    )

    {:error, :claim_failed}
  end

  # An `Ecto.Multi` step: mints a capability token so the caller can hand it to
  # the agent that will need it for the next custody op.
  #
  # Issue #621: this used to discard the token "to keep the return type
  # backward-compatible", and no other path delivered it either — so every
  # keyed tenant's next lifecycle call hit `:missing_capability` (see
  # maybe_consume_cap/6). The token is now returned and surfaced on the story
  # struct's virtual :minted_capability field.
  #
  # A mint failure is only tolerable for a PRE-V2 (keyless) tenant, where
  # maybe_consume_cap/6 lets a nil cap through — that tenant is not GOING to
  # present a capability, so a nil is the correct, complete outcome. For a KEYED
  # tenant the capability is MANDATORY, so the failure ABORTS the enclosing
  # transaction rather than committing a claim the agent cannot act on. It is
  # loud on the way out either way: an operator needs to see a secret store that
  # stopped answering, and a rolled-back claim on its own looks like a transient
  # conflict.
  #
  # It runs inside the caller's transaction, which means the (ETS-cached)
  # `TenantKeys` lookup happens while the story row lock is held. That is one
  # cached read on the common path and at worst one secret-store round trip on a
  # miss, against a per-story lock on an infrequent operation.
  defp mint_cap(tenant_id, typ, story_id, lineage) do
    case Capabilities.mint(tenant_id, typ, story_id, lineage) do
      {:ok, cap} ->
        {:ok, cap}

      {:error, reason} ->
        if tenant_has_audit_key?(tenant_id) do
          class = Capabilities.mint_failure_class(reason)

          Logger.error(
            "#{class}: KEYED tenant could not mint a capability, so the enclosing custody " <>
              "transaction was ROLLED BACK — nothing was claimed. " <>
              mint_failure_remedy(class) <>
              " tenant_id=#{tenant_id} story_id=#{story_id} cap_type=#{typ} " <>
              "reason=#{inspect(reason)}"
          )

          :telemetry.execute(
            [:loopctl, :custody, :cap_mint_failed],
            %{count: 1},
            %{tenant_id: tenant_id, story_id: story_id, cap_type: typ, reason: reason}
          )

          {:error, {class, reason}}
        else
          {:ok, nil}
        end
    end
  end

  defp mint_failure_remedy(:capability_key_unavailable),
    do:
      "The tenant's audit signing key is ABSENT or SUPERSEDED — retrying cannot clear it; " <>
        "an operator must restore it."

  defp mint_failure_remedy(_class), do: "The agent should retry."

  # US-26.6.2: Computes the lazy-bastard score from token usage reports
  # and stores it in the story's metadata. Non-blocking — failures are logged.
  defp compute_and_store_lazy_score(tenant_id, story) do
    alias Loopctl.TokenUsage.LazyScore

    reports =
      from(r in "token_usage_reports",
        where: r.tenant_id == ^tenant_id and r.story_id == ^story.id,
        select: %{
          total_tokens:
            fragment("COALESCE(?, 0) + COALESCE(?, 0)", r.input_tokens, r.output_tokens),
          tool_call_count: r.tool_call_count,
          cot_length_tokens: r.cot_length_tokens,
          tests_run_count: r.tests_run_count
        }
      )
      |> AdminRepo.all()

    if reports != [] do
      aggregated = %{
        total_tokens: Enum.sum(Enum.map(reports, & &1.total_tokens)),
        estimated_hours: story.estimated_hours && Decimal.to_float(story.estimated_hours),
        tool_call_count:
          reports |> Enum.map(& &1.tool_call_count) |> Enum.reject(&is_nil/1) |> Enum.sum(),
        cot_length_tokens:
          reports |> Enum.map(& &1.cot_length_tokens) |> Enum.reject(&is_nil/1) |> Enum.sum(),
        tests_run_count:
          reports |> Enum.map(& &1.tests_run_count) |> Enum.reject(&is_nil/1) |> Enum.sum()
      }

      {score, reasons} = LazyScore.compute(aggregated)

      metadata =
        Map.merge(story.metadata || %{}, %{
          "lazy_score" => score,
          "lazy_reasons" => reasons,
          "lazy_flagged" => LazyScore.flagged?(score)
        })

      # If flagged: route to re-review by resetting verifier
      changes =
        if LazyScore.flagged?(score) do
          Logger.warning("Lazy-bastard flagged: story=#{story.id} score=#{score}")
          %{metadata: metadata, verifier_needed: true, verifier_dispatch_id: nil}
        else
          %{metadata: metadata}
        end

      story
      |> Ecto.Changeset.change(changes)
      |> AdminRepo.update()
    end
  rescue
    error ->
      Logger.warning("compute_and_store_lazy_score failed: #{Exception.message(error)}")
      :ok
  end

  # Adds a cap consumption step to an Ecto.Multi.
  # When cap_id is nil: rejects with :missing_capability if the tenant
  # has an audit key (v2 tenant). Pre-v2 tenants (no audit key) pass
  # through for backward compatibility during migration.
  defp maybe_consume_cap(multi, tenant_id, story_id, nil, typ, _lineage) do
    Multi.run(multi, :consume_cap, fn _repo, _changes ->
      if tenant_has_audit_key?(tenant_id) do
        {:error, :missing_capability}
      else
        # OBSERVABILITY: taking this branch means L1 (capability tokens) is NOT
        # enforced for this custody op. It is silent-by-default otherwise, so an
        # operator would never learn that a tenant (e.g. one whose audit key was
        # cleared by a failed rotation) dropped to pre-v2 custody strength.
        Logger.warning(
          "pre_v2_custody_bypass: capability enforcement skipped — tenant has no audit " <>
            "signing key tenant_id=#{tenant_id} story_id=#{story_id} cap_type=#{typ}"
        )

        :telemetry.execute(
          [:loopctl, :custody, :pre_v2_bypass],
          %{count: 1},
          %{tenant_id: tenant_id, story_id: story_id, cap_type: typ}
        )

        {:ok, :pre_v2_tenant}
      end
    end)
  end

  # A forged signature and a double-spent token are refusals of the TOKEN ITSELF, not of a
  # token gone stale. Every other refusal — expired, bound to another lineage, wrong
  # story/type, unknown id — is an ordinary client error: the caller sat on a token past its
  # 1h TTL, or its dispatch rotated. Only the first pair is answered as `:cap_rejected`.
  # NOTE: this set is NOT the byzantine set — see `record_cap_refusal/4`, where a replay is
  # explicitly not one.
  #
  # `:signing_key_unavailable` is deliberately OUTSIDE this set. It is what
  # `Capabilities.check_signature/2` returns when there is no key to check against at all,
  # which is the tenant's key state and not a property of the presented token — the caller
  # could not have avoided it and an authentic token fails the same way.
  @cap_rejected_refusals [:invalid_signature, :replay]

  defp maybe_consume_cap(multi, tenant_id, story_id, cap_id, typ, lineage) do
    Multi.run(multi, :consume_cap, fn _repo, _changes ->
      with {:ok, cap} <-
             Capabilities.verify(tenant_id, %{
               "cap_id" => cap_id,
               "typ" => typ,
               "story_id" => story_id,
               "lineage" => lineage
             }),
           {:ok, consumed} <- Capabilities.consume(cap) do
        {:ok, consumed}
      else
        {:error, reason} -> {:error, cap_refusal(reason)}
      end
    end)
  end

  # `{:cap_rejected, _}` is answered by FallbackController with a plain 403 plus
  # `[:loopctl, :custody, :cap_rejected]` telemetry — it does NOT halt and does NOT
  # count toward one (#629): a single-use token with a bounded TTL produces a
  # rejection from an ordinary retry, a resumed agent or an audit-key rotation.
  # The split still matters, because the two classes mean different things and are
  # recorded under different actions: the byzantine set is a FORGED signature or a
  # double-spend, everything else is the caller's own token going stale.
  defp cap_refusal(reason) when reason in @cap_rejected_refusals, do: {:cap_rejected, reason}
  defp cap_refusal(reason), do: {:cap_unusable, reason}

  # Every capability refusal gets a durable trace, and the BYZANTINE ones get at least
  # as strong a one as the benign ones. That was backwards: `:wrong_lineage` and
  # `:wrong_story` were hash-chained while `:invalid_signature` — a forged signature,
  # the single highest-signal event this subsystem can observe — left only a log line
  # and a telemetry tick, both of which a log-retention window disposes of. Since
  # `cap_rejected` no longer halts, the audit-chain entry IS the durable record of it.
  #
  # Runs AFTER the transaction rolled back, so the entry survives; a refusal appended
  # inside the multi dies with it.
  defp record_cap_refusal(tenant_id, story_id, reason, ctx) do
    action = cap_refusal_action(reason)
    # Derived from the ACTION, not from the rejected set: a replay is reachable by an
    # ordinary retry, so it is recorded under its own action and is NOT byzantine. Naming
    # it one and then flagging it `byzantine: true` renamed the accusation, it did not
    # withdraw it — a consumer keying off the flag still read a retry as a forgery.
    byzantine? = action == "capability_forged"

    Logger.warning(cap_refusal_log(action, tenant_id, story_id, reason, ctx))

    :telemetry.execute(
      [:loopctl, :custody, :cap_refused],
      %{count: 1},
      %{
        tenant_id: tenant_id,
        story_id: story_id,
        cap_type: ctx.cap_type,
        reason: reason,
        byzantine: byzantine?
      }
    )

    tenant_id
    |> Loopctl.AuditChain.append(%{
      action: action,
      actor_lineage: ctx.lineage,
      entity_type: "story",
      entity_id: story_id,
      payload: %{
        "reason" => to_string(reason),
        "byzantine" => byzantine?,
        "cap_type" => ctx.cap_type,
        "cap_id" => ctx.cap_id,
        "api_key_id" => ctx.actor_id,
        "agent_id" => ctx.agent_id
      }
    })
    # Post-commit (post-rollback) append, and this entry IS the durable record the
    # log line was supposed to stop being. A discarded failure would lose the
    # highest-signal event in the subsystem silently. See AuditChain.log_append_failure/4.
    |> Loopctl.AuditChain.log_append_failure(action, tenant_id, story_id)

    :ok
  end

  # `:replay` is worth COUNTING — the double-spend signal is a spike — but it is not a
  # forgery, and `capability_forged` is a permanent accusation in an append-only log.
  # FallbackController states the opposite of that accusation: a replayed single-use token
  # is reachable by an ordinary retry. So a double-spend takes its own action, and only a
  # signature that failed to verify is recorded as forged (and flagged byzantine).
  #
  # Cost accepted: a retry loop appends one chained entry per attempt, each taking the
  # tenant's chain-head lock. That is the shape the benign refusals (`:wrong_story`,
  # `:wrong_lineage`) already had; the spike is the signal, and dropping the entry
  # would put a double-spend back on log retention.
  defp cap_refusal_action(:replay), do: "capability_replayed"

  # The tenant had NO key to check the signature against — cleared, or replaced
  # without a history row covering the token's issuance. An authentic token would
  # have failed identically, so this says nothing whatsoever about the caller. It
  # is the operator's key state, and it takes an operator-shaped action instead of
  # the permanent forgery accusation `capability_forged` writes into a log that
  # cannot be retracted. `Capabilities.check_signature/2` decides which of the two
  # applies, from server state only.
  defp cap_refusal_action(:signing_key_unavailable), do: "capability_key_unavailable"

  defp cap_refusal_action(reason) when reason in @cap_rejected_refusals,
    do: "capability_forged"

  defp cap_refusal_action(_reason), do: "capability_refused"

  defp cap_refusal_log("capability_forged", tenant_id, story_id, reason, ctx) do
    "capability_forged: #{reason} — the presented token did not verify against the " <>
      "tenant's audit signing key. This is not a stale token; investigate the caller. " <>
      cap_refusal_fields(tenant_id, story_id, ctx)
  end

  defp cap_refusal_log("capability_key_unavailable", tenant_id, story_id, reason, ctx) do
    "capability_key_unavailable: #{reason} — the tenant's audit signing key for this " <>
      "token's issuance instant is not available (cleared, or rotated without a " <>
      "tenant_audit_key_history row covering it), so the signature could not be checked " <>
      "at all. This is an OPERATOR key-state fault, NOT a claim about the caller: do not " <>
      "read it as a forgery. Remediation: restore or re-archive the audit key, then have " <>
      "the agent re-mint via POST /stories/:id/recover-cap. " <>
      cap_refusal_fields(tenant_id, story_id, ctx)
  end

  defp cap_refusal_log("capability_replayed", tenant_id, story_id, reason, ctx) do
    "capability_replayed: #{reason} — a single-use token was presented twice. A retry " <>
      "of a request whose first attempt already consumed it produces this; the " <>
      "double-spend signal is a SPIKE, not one occurrence. " <>
      cap_refusal_fields(tenant_id, story_id, ctx)
  end

  defp cap_refusal_log(_action, tenant_id, story_id, reason, ctx) do
    "capability_unusable: #{reason} — the caller must re-mint via " <>
      "POST /stories/:id/recover-cap; GET /stories/:id/capabilities delivers only LIVE " <>
      "tokens already issued, so it cannot serve an expired or misbound one. " <>
      cap_refusal_fields(tenant_id, story_id, ctx)
  end

  defp cap_ctx(cap_id, lineage, actor_id, agent_id) do
    %{
      cap_type: "start_cap",
      cap_id: cap_id,
      lineage: lineage,
      actor_id: actor_id,
      agent_id: agent_id
    }
  end

  defp cap_refusal_fields(tenant_id, story_id, ctx) do
    "tenant_id=#{tenant_id} story_id=#{story_id} cap_type=#{ctx.cap_type} " <>
      "cap_id=#{inspect(ctx.cap_id)} api_key_id=#{inspect(ctx.actor_id)} " <>
      "agent_id=#{inspect(ctx.agent_id)}"
  end

  # US-26.2.2 AC-4: loopctl selects the verifier, not the orchestrator
  defp assign_rotating_verifier(tenant_id, story_id, story) do
    impl_lineage =
      if story.implementer_dispatch_id,
        do: get_dispatch_lineage(tenant_id, story.implementer_dispatch_id),
        else: []

    case Dispatches.select_verifier(tenant_id, story_id, impl_lineage) do
      {:ok, verifier} ->
        # NOT fire-and-forget: a silently failed write leaves verifier_dispatch_id
        # nil, which downgrades validate_not_self_verify/2 from lineage separation
        # to plain agent-id equality. On failure, fall back to flagging the story
        # so an operator/re-review picks it up instead of losing the gate silently.
        case story
             |> Ecto.Changeset.change(verifier_dispatch_id: verifier.id)
             |> AdminRepo.update() do
          {:ok, _updated} ->
            # No verify_cap is minted: see verify_story/4 for why L1 cannot gate
            # verify. The selection itself is the gate — it writes
            # verifier_dispatch_id, which validate_not_self_verify/2 enforces.
            tenant_id
            |> Loopctl.AuditChain.append(%{
              action: "verifier_selected",
              actor_lineage: [],
              entity_type: "story",
              entity_id: story_id,
              payload: %{"verifier_dispatch_id" => verifier.id}
            })
            # Post-commit append: the verifier_dispatch_id write above has already
            # committed, so a discarded failure would leave the chain missing an entry
            # for a custody decision that DID happen. See AuditChain.log_append_failure/4.
            |> Loopctl.AuditChain.log_append_failure("verifier_selected", tenant_id, story_id)

          {:error, reason} ->
            flag_verifier_needed(tenant_id, story_id, story, "assign_failed", reason)
        end

      # `:no_independent_root` is reported distinctly on purpose: it is not a shortage
      # but the single-root tenant shape, and its remedy is an operator action (mint an
      # independently-rooted verifier tree), not waiting.
      {:error, reason}
      when reason in [
             :no_eligible_verifier,
             :no_independent_root,
             :verifier_seed_unavailable
           ] ->
        flag_verifier_needed(tenant_id, story_id, story, to_string(reason), nil)
    end
  end

  # Marks a story as needing a verifier, loudly. Both callers are outside a
  # transaction, so the write itself can fail — log and record it either way so a
  # missing verifier_dispatch_id is never invisible.
  defp flag_verifier_needed(tenant_id, story_id, story, reason, error) do
    result = story |> Ecto.Changeset.change(verifier_needed: true) |> AdminRepo.update()

    if match?({:error, _}, result) do
      Logger.error(
        "verifier_needed_write_failed: could not flag story=#{story_id} tenant=#{tenant_id} " <>
          "reason=#{reason} error=#{inspect(result)}"
      )
    else
      Logger.warning(
        "verifier_not_assigned: story=#{story_id} tenant=#{tenant_id} reason=#{reason}" <>
          if(error, do: " error=#{inspect(error)}", else: "")
      )
    end

    tenant_id
    |> Loopctl.AuditChain.append(%{
      action: "verifier_not_assigned",
      actor_lineage: [],
      entity_type: "story",
      entity_id: story_id,
      payload: %{"reason" => reason}
    })
    |> Loopctl.AuditChain.log_append_failure("verifier_not_assigned", tenant_id, story_id)

    result
  end

  defp tenant_has_audit_key?(tenant_id) do
    case AdminRepo.get(Loopctl.Tenants.Tenant, tenant_id) do
      %{audit_signing_public_key: key} when not is_nil(key) -> true
      _ -> false
    end
  end

  # LCP-1 §9.4 audit binding: when a custody gate ran under a VERIFIED signed claim
  # (stashed by RequireSignedClaim into `opts[:custody_claim]`), record the
  # agent_pubkey + claim_sig in the tenant's HASH-CHAINED, STH-covered audit chain,
  # ATOMICALLY with the gate decision. This is the durable cryptographic residue that
  # lets a third party re-check authorship offline and prevents a malicious operator
  # from fabricating an agent-signed record indistinguishable from a genuine one.
  # A bearer/legacy (unsigned) gate adds no such step — nothing to bind.
  defp maybe_chain_signed_claim(multi, tenant_id, story_id, opts) do
    case Keyword.get(opts, :custody_claim) do
      %{gate: gate} = claim ->
        Multi.run(multi, :signed_claim_chain, fn _repo, _changes ->
          Loopctl.AuditChain.append(tenant_id, %{
            action: "signed_custody_claim",
            actor_lineage: signed_claim_lineage(opts),
            entity_type: "story",
            entity_id: story_id,
            payload: %{
              "gate" => gate,
              "agent_pubkey" => claim.agent_pubkey_hex,
              "alg" => claim.alg,
              "claim_sig" => claim.claim_sig,
              "claimed_at" => claim.claimed_at
            }
          })
        end)

      _ ->
        multi
    end
  end

  defp signed_claim_lineage(opts) do
    Keyword.get(opts, :reporter_lineage) || Keyword.get(opts, :reviewer_lineage) ||
      Keyword.get(opts, :verifier_lineage) || []
  end

  @doc """
  Starts work on a story.

  Transitions agent_status from `assigned` to `implementing`.
  Only the assigned agent can start work.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if not in assigned state
  - `{:error, :not_assigned_agent}` if calling agent is not the assigned agent
  - `{:error, :stale_claim_epoch}` if `:claim_epoch` is given and is not the story's
    current epoch — the caller's claim has ended (#803). Omitting it skips the check,
    which is what every client written before the fence does.
  """
  @spec start_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Story.t()} | {:error, atom() | {:invalid_transition, map()}}
  def start_story(tenant_id, story_id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    cap_id = Keyword.get(opts, :cap_id)
    lineage = Keyword.get(opts, :lineage, [])

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes ->
        lock_story(tenant_id, story_id)
      end)
      |> Multi.run(:validate, fn _repo, %{lock: story} ->
        with :ok <- validate_optional_claim_epoch(story, Keyword.get(opts, :claim_epoch)),
             :ok <- validate_transition_ctx(story, :implementing, "start"),
             :ok <- validate_assigned_agent(story, agent_id) do
          {:ok, story}
        end
      end)
      |> maybe_consume_cap(tenant_id, story_id, cap_id, "start_cap", lineage)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        story
        |> Ecto.Changeset.change(%{
          agent_status: :implementing
        })
        |> AdminRepo.update()
      end)
      |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: updated.id,
          action: "status_changed",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{"agent_status" => to_string(old.agent_status)},
          new_state: %{
            "agent_status" => to_string(updated.agent_status),
            "agent_id" => agent_id
          }
        }
      end)
      |> EventGenerator.generate_events(:webhook_events, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          event_type: "story.status_changed",
          project_id: updated.project_id,
          payload: %{
            "event" => "story.status_changed",
            "story_id" => updated.id,
            "project_id" => updated.project_id,
            "epic_id" => updated.epic_id,
            "old_status" => to_string(old.agent_status),
            "new_status" => to_string(updated.agent_status),
            "agent_id" => agent_id,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} ->
        # #621: NO report_cap is minted here any more, deliberately.
        #
        # It used to be minted bound to the STARTER's (implementer's) lineage, to
        # be consumed by POST /report. But `report` is a chain-of-custody gate: it
        # must be called by a DIFFERENT principal from the implementer
        # (validate_not_self_report/3, `self_report_blocked`), and
        # Capabilities.verify/2 requires an EXACT lineage match. So the only
        # principal the token authorized was the one principal forbidden to use
        # it, and every keyed tenant's report failed `cap_rejected: wrong_lineage`.
        #
        # The token could not be rebound: the reporter is by definition not known
        # when the implementer starts. Binding it loosely (any separated lineage)
        # would still require the implementer to HAND the token to the reporter,
        # opening a channel between the two principals the model exists to keep
        # apart — and letting the implementer decide whether review can happen.
        #
        # Report is therefore gated by L4 structural separation alone, which is
        # what actually enforces "nobody reports their own work": agent-id AND
        # dispatch-lineage comparison, fail-closed on a custody-unattributed story
        # or an unresolvable dispatch. The same argument retired `verify_cap` —
        # see verify_story/4. `start_cap` is the one capability still in use, and
        # the only one whose holder IS the principal permitted to spend it.
        {:ok, updated}

      {:error, :lock, reason, _} ->
        {:error, reason}

      {:error, :validate, reason, _} ->
        {:error, reason}

      # There is no USABLE key to check the token against. Answering it as
      # `missing_capability` told the caller to go get a capability, whose
      # documented remedy is `POST /stories/:id/recover-cap` — which mints through
      # the SAME unusable key and fails identically. That is a loop no client can
      # exit, so the key state gets its own code naming the OPERATOR action.
      {:error, :consume_cap, {:cap_unusable, :signing_key_unavailable}, _} ->
        record_cap_refusal(
          tenant_id,
          story_id,
          :signing_key_unavailable,
          cap_ctx(cap_id, lineage, actor_id, agent_id)
        )

        {:error, :capability_key_unavailable}

      {:error, :consume_cap, {:cap_unusable, reason}, _} ->
        record_cap_refusal(
          tenant_id,
          story_id,
          reason,
          cap_ctx(cap_id, lineage, actor_id, agent_id)
        )

        {:error, :missing_capability}

      # A forged signature or a double-spend. It answers a plain 403 like any other
      # cap refusal, but it is the one worth going back and finding later, so it takes
      # the SAME hash-chained record the benign refusals take — previously it took
      # none at all.
      {:error, :consume_cap, {:cap_rejected, reason}, _} ->
        record_cap_refusal(
          tenant_id,
          story_id,
          reason,
          cap_ctx(cap_id, lineage, actor_id, agent_id)
        )

        {:error, {:cap_rejected, reason}}

      {:error, :consume_cap, reason, _} ->
        {:error, reason}

      {:error, :story, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Reports a story as done.

  Transitions agent_status from `implementing` to `reported_done`.
  Optionally accepts an artifact report that is created atomically.
  A DIFFERENT agent from the implementer must call this (chain-of-custody enforcement).
  The calling agent is recorded as `reported_by_agent_id`.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`
  - `artifact_params` -- optional map with artifact report data

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if not in implementing state
  - `{:error, :self_report_blocked}` if calling agent is the same as the assigned agent,
    or lies on the implementer's dispatch lineage chain (pass the caller's
    server-resolved lineage as `:reporter_lineage`)
  - `{:error, :caller_lineage_required}` if a key no dispatch minted reports
    dispatch-minted work — its separation cannot be shown (fails closed)
  - `{:error, :missing_assigned_agent}` if the story has neither an assigned agent
    nor an implementer dispatch (custody-unattributed — fails closed)
  - `{:error, :unresolvable_dispatch_lineage}` if the story's declared implementer
    dispatch cannot be resolved (e.g. a cross-tenant id) — a lineage-integrity
    failure that fails closed (LCP-1 §7.5)
  - `{:error, :stale_claim_epoch}` if `:claim_epoch` is given and is not the story's
    current epoch (#803); omitting it skips the check
  - `{:error, %Ecto.Changeset{}}` if artifact validation fails
  """
  @spec report_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword(), map() | nil) ::
          {:ok, Story.t()}
          | {:error, atom() | {:invalid_transition, map()} | Ecto.Changeset.t()}
          | {:error, :unprocessable_entity, String.t()}
  def report_story(tenant_id, story_id, opts \\ [], artifact_params \\ nil) do
    token_usage_params = Keyword.get(opts, :token_usage)

    # Enforce skill_version tenant-ownership BEFORE the report transaction, the
    # SAME guard the standalone TokenUsage.create_report/3 path runs. A
    # cross-tenant (or non-existent) skill_version_id is rejected here, so no
    # report row is ever stored. The 3-tuple maps to a 422 via FallbackController.
    with :ok <- validate_token_usage_ownership(tenant_id, token_usage_params) do
      do_report_story(tenant_id, story_id, opts, artifact_params)
    end
  end

  defp do_report_story(tenant_id, story_id, opts, artifact_params) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)
    token_usage_params = Keyword.get(opts, :token_usage)

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes ->
        lock_story(tenant_id, story_id)
      end)
      |> Multi.run(:validate, fn _repo, %{lock: story} ->
        with :ok <- validate_optional_claim_epoch(story, Keyword.get(opts, :claim_epoch)),
             :ok <- validate_transition_ctx(story, :reported_done, "report"),
             :ok <-
               validate_not_self_report(
                 story,
                 agent_id,
                 Keyword.get(opts, :reporter_lineage, [])
               ) do
          {:ok, story}
        end
      end)
      # #621: no capability is consumed here — see the comment in start_story/3
      # for why a report_cap could not be bound to a legitimate holder. The
      # custody gate above (validate_not_self_report/3) is the enforcement.
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        now = DateTime.utc_now()

        story
        |> Ecto.Changeset.change(%{
          agent_status: :reported_done,
          reported_done_at: now,
          reported_by_agent_id: agent_id
        })
        |> AdminRepo.update()
      end)
      |> maybe_create_artifact(tenant_id, story_id, agent_id, artifact_params)
      |> maybe_create_token_usage_report(tenant_id, story_id, agent_id, token_usage_params)
      |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: updated.id,
          action: "status_changed",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{"agent_status" => to_string(old.agent_status)},
          new_state: %{
            "agent_status" => to_string(updated.agent_status),
            "reported_done_at" => to_string(updated.reported_done_at),
            "agent_id" => agent_id
          }
        }
      end)
      |> maybe_audit_token_usage(tenant_id, actor_id, actor_label, token_usage_params)
      |> maybe_chain_signed_claim(tenant_id, story_id, opts)
      |> EventGenerator.generate_events(:webhook_events, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          event_type: "story.status_changed",
          project_id: updated.project_id,
          payload: %{
            "event" => "story.status_changed",
            "story_id" => updated.id,
            "project_id" => updated.project_id,
            "epic_id" => updated.epic_id,
            "old_status" => to_string(old.agent_status),
            "new_status" => to_string(updated.agent_status),
            "agent_id" => agent_id,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated} = results} ->
        # Run budget threshold checks AFTER commit, through the SAME shared
        # entry point the standalone create_report path uses — firing budget
        # warning/exceeded webhooks + threshold_crossed audit entries and
        # flipping warning_fired/exceeded_fired. No-op when no token usage
        # was reported.
        maybe_check_token_budget_thresholds(tenant_id, results)
        {:ok, updated}

      {:error, :lock, reason, _} ->
        {:error, reason}

      {:error, :validate, reason, _} ->
        {:error, reason}

      {:error, :story, changeset, _} ->
        {:error, changeset}

      {:error, :artifact, changeset, _} ->
        {:error, changeset}

      {:error, :token_usage_report, changeset, _} ->
        {:error, changeset}
    end
  end

  # Enforce skill_version tenant-ownership on the report_story path, mirroring
  # the standalone TokenUsage.create_report/3 guard. Reads skill_version_id out
  # of the raw token_usage params (JSON string keys), treating "" as absent.
  defp validate_token_usage_ownership(_tenant_id, nil), do: :ok

  defp validate_token_usage_ownership(tenant_id, params) when is_map(params) do
    skill_version_id =
      case Map.get(params, "skill_version_id", Map.get(params, :skill_version_id)) do
        "" -> nil
        id -> id
      end

    TokenUsage.validate_skill_version_ownership(tenant_id, skill_version_id)
  end

  # Fires budget threshold alerting for the freshly-created token usage report
  # (if any) via the shared TokenUsage entry point. No-op when the report
  # transaction created no token usage report.
  defp maybe_check_token_budget_thresholds(tenant_id, %{token_usage_report: report}) do
    TokenUsage.check_budget_thresholds_for_report(tenant_id, report)
  end

  defp maybe_check_token_budget_thresholds(_tenant_id, _results), do: :ok

  @doc """
  Signals that the assigned agent has finished implementation and requests review.

  Does NOT change agent_status. Fires a `story.review_requested` webhook event.
  Only the assigned agent can call this. Story must be in `implementing` status.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :not_assigned_agent}` if caller is not the assigned agent
  - `{:error, {:invalid_transition, map()}}` if story is not in implementing status
  """
  @spec request_review(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Story.t()} | {:error, atom() | {:invalid_transition, map()}}
  def request_review(tenant_id, story_id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)

    query =
      Story
      |> where([s], s.id == ^story_id and s.tenant_id == ^tenant_id)

    case AdminRepo.one(query) do
      nil ->
        {:error, :not_found}

      story ->
        with :ok <- validate_story_implementing(story),
             :ok <- validate_assigned_agent(story, agent_id),
             {:ok, story} <- mark_review_requested(story, agent_id) do
          insert_events_with_delivery(tenant_id, "story.review_requested", story.project_id, %{
            "event" => "story.review_requested",
            "story_id" => story_id,
            "project_id" => story.project_id,
            "epic_id" => story.epic_id,
            "agent_id" => agent_id,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          })

          # US-26.2.2 AC-4: rotating verifier selection
          assign_rotating_verifier(tenant_id, story_id, story)

          # US-26.6.2: compute and store lazy-bastard score
          compute_and_store_lazy_score(tenant_id, story)

          {:ok, story}
        end
    end
  end

  @doc """
  Unclaims a story: resets it to pending.

  Only the assigned agent can unclaim (unless already pending).
  Works from any agent_status except pending.

  A DELIVERY story (one with a stage row the release requeues) does not stay `pending`: giving
  a claimed story back spent an attempt, so it is re-contracted below the retry ceiling and
  escalated at it (`Loopctl.Delivery.Stages.follow_release/5`, US-44.4). The story returned is
  the story as it stands after that.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`, and
    `:actor_lineage` — the caller's SERVER-resolved lineage, recorded on the chain entry if the
    release escalates the story; defaults to `[]`, the shape a key no dispatch minted has

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if already pending
  - `{:error, :not_assigned_agent}` if calling agent is not the assigned agent
  """
  @spec unclaim_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Story.t()} | {:error, atom() | Ecto.Changeset.t()}
  def unclaim_story(tenant_id, story_id, opts \\ []) do
    # ONE CLAUSE PER MULTI STEP and no catch-all, as in `force_unclaim_story/3`: a step added to
    # `unclaim_multi/3` without a clause here is caught by
    # `test/loopctl/progress/unclaim_result_coverage_test.exs`, not by a CaseClauseError out of
    # the agent's unclaim. `:stage` refuses `:audit_chain_append_failed` when a release's
    # escalation could not append its chain entry, which rolls the whole release back, so the
    # story is still claimed.
    case AdminRepo.transaction(unclaim_multi(tenant_id, story_id, opts)) do
      {:ok, %{recontract: story, stage: released}} ->
        Stages.announce_release(released)
        {:ok, story}

      {:error, :lock, reason, _} ->
        {:error, reason}

      {:error, :validate, reason, _} ->
        {:error, reason}

      {:error, :story, changeset, _} ->
        {:error, changeset}

      {:error, step, reason, _} when step in [:stage, :audit, :webhook_events, :recontract] ->
        {:error, reason}
    end
  end

  @doc """
  The `Ecto.Multi` `unclaim_story/3` runs. Builds nothing and executes no query.

  Public for the same reason as `force_unclaim_multi/3`, and for nothing else: so
  `test/loopctl/progress/unclaim_result_coverage_test.exs` can read the steps off the value the
  transaction runs and fail when one has no clause in `unclaim_story/3`'s result `case`.
  """
  @spec unclaim_multi(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: Multi.t()
  def unclaim_multi(tenant_id, story_id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    Multi.new()
    |> Multi.run(:lock, fn _repo, _changes ->
      lock_story(tenant_id, story_id)
    end)
    |> Multi.run(:validate, fn _repo, %{lock: story} ->
      case validate_unclaim(story, agent_id) do
        :ok -> {:ok, story}
        error -> error
      end
    end)
    |> Multi.run(:story, fn _repo, %{lock: story} ->
      story
      |> Ecto.Changeset.change(release_claim_changes(story))
      |> AdminRepo.update()
    end)
    # #803: the stage row follows the release in this transaction (see follow_release/5).
    # The claimant giving a claimed story back spent an attempt (US-44.4).
    |> Multi.run(:stage, fn _repo, %{story: updated} ->
      Stages.follow_release(tenant_id, updated.id, updated.claim_epoch, :claim_released,
        cause: :attempt,
        actor_lineage: Keyword.get(opts, :actor_lineage, []),
        actor_label: actor_label
      )
    end)
    |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
      %{
        tenant_id: tenant_id,
        entity_type: "story",
        entity_id: updated.id,
        action: "status_changed",
        actor_type: "api_key",
        actor_id: actor_id,
        actor_label: actor_label,
        old_state: %{
          "agent_status" => to_string(old.agent_status),
          "assigned_agent_id" => old.assigned_agent_id
        },
        new_state: %{"agent_status" => "pending", "agent_id" => agent_id}
      }
    end)
    |> EventGenerator.generate_events(:webhook_events, fn %{story: updated, lock: old} ->
      %{
        tenant_id: tenant_id,
        event_type: "story.status_changed",
        project_id: updated.project_id,
        payload: %{
          "event" => "story.status_changed",
          "story_id" => updated.id,
          "project_id" => updated.project_id,
          "epic_id" => updated.epic_id,
          "old_status" => to_string(old.agent_status),
          "new_status" => "pending",
          "agent_id" => agent_id,
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
        }
      }
    end)
    # AFTER the release's own audit and webhook (see `Stages.recontract_released/4`).
    |> Multi.run(:recontract, fn _repo, %{story: updated, stage: released} ->
      Stages.recontract_released(tenant_id, released, updated, actor_label)
    end)
  end

  # #803: requesting review ENDS the implementer's lease. The story stays `implementing`
  # until a DIFFERENT principal reports it, and only the implementer — whose session is
  # usually gone by then — can renew. Left armed, a review that outlasted the lease had
  # the reclaimer reset finished work to `pending` under the reviewer, whose report then
  # failed `invalid_transition`.
  #
  # A MARKER rather than NULLing `claimed_until`: a runner renews on a timer, and a
  # renewal after review was requested would silently re-arm a nulled lease, recreating
  # the defect. The marker holds whatever renew writes, and both the sweep and
  # `lease_expired?/3` under the row lock refuse a story that carries it. Cleared by every
  # release (`claim_release_change/1`), so a re-claimed story starts with a live lease.
  #
  # A conditional UPDATE, so it cannot land on a story the reclaimer released between the
  # read above and this write: after that release the row no longer matches, zero rows
  # update, and the caller gets the refusal the fresh row warrants. The FIRST request is
  # kept (`coalesce`).
  defp mark_review_requested(%Story{} = story, agent_id) do
    now = DateTime.utc_now()

    query =
      from(s in Story,
        where:
          s.id == ^story.id and s.tenant_id == ^story.tenant_id and
            s.agent_status == :implementing and s.assigned_agent_id == ^agent_id,
        select: s,
        update: [
          set: [
            review_requested_at:
              fragment("coalesce(?, ?)", s.review_requested_at, type(^now, :utc_datetime_usec))
          ]
        ]
      )

    case AdminRepo.update_all(query, []) do
      {1, [updated]} ->
        {:ok, updated}

      {0, _} ->
        review_request_lost(story, agent_id)
    end
  end

  # Zero rows: the claim changed between the caller's read and the conditional UPDATE.
  # Answer from the fresh row, as if the request had arrived after the change.
  defp review_request_lost(story, agent_id) do
    case AdminRepo.get_by(Story, id: story.id, tenant_id: story.tenant_id) do
      nil ->
        {:error, :not_found}

      current ->
        with :ok <- validate_story_implementing(current),
             :ok <- validate_assigned_agent(current, agent_id),
             do: {:error, :not_assigned_agent}
    end
  end

  # --- Claim lease and fence (#803) ---

  # A claim held by a session that crashed after its UPDATE used to hold the story
  # forever: nothing released it. The lease is the releaser's trigger and the epoch is
  # what makes the release stick against a session that comes back.
  #
  # The default is LONG on purpose. A lease keyed on wall time fires on long HEALTHY
  # work, not just on abandoned work, and the two errors are not symmetric: a lease
  # too short releases a story an agent is still implementing (duplicate work — the
  # thing a claim exists to prevent), while a lease too long only delays reopening a
  # story whose session is already gone. KB 1531d275 measured the first on the
  # coordination bus's handoff claims. A claimant renews well inside the window.
  @default_claim_lease_seconds 86_400

  # The statuses in which a story is HELD by its claimant. `reported_done` is not one:
  # once reported, the work is in custody review and a lapsed lease must not reset it.
  @claimed_statuses [:assigned, :implementing]

  @doc """
  The claim lease length in seconds: `:story_claim_lease_seconds`, set from
  `STORY_CLAIM_LEASE_SECONDS`, default #{@default_claim_lease_seconds} (24 hours).
  A value that is not a positive integer falls back to the default.
  """
  @spec claim_lease_seconds() :: pos_integer()
  def claim_lease_seconds do
    case Application.get_env(:loopctl, :story_claim_lease_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_claim_lease_seconds
    end
  end

  @doc """
  The lease-and-epoch change a CLAIM writes: a fresh lease from `now` and the next epoch.

  With a `lease_until` (#879) the lease IS that instant and it is recorded as the claim's
  `claim_lease_cap`; with `nil` the lease is now plus `claim_lease_seconds/0` and the cap is
  written NULL — explicitly, so a stale cap can never ride into an uncapped claim.

  Public because `Loopctl.BulkOperations.bulk_claim/4` claims too and must write the
  identical change (it never passes a cap).
  """
  @spec claim_lease_change(Story.t(), DateTime.t(), DateTime.t() | nil) :: map()
  def claim_lease_change(story, now, lease_until \\ nil)

  def claim_lease_change(%Story{claim_epoch: epoch}, %DateTime{} = now, nil) do
    %{
      claimed_until: DateTime.add(now, claim_lease_seconds(), :second),
      claim_lease_cap: nil,
      claim_epoch: epoch + 1
    }
  end

  def claim_lease_change(%Story{claim_epoch: epoch}, %DateTime{}, %DateTime{} = lease_until) do
    %{claimed_until: lease_until, claim_lease_cap: lease_until, claim_epoch: epoch + 1}
  end

  # A capped claim whose cap is not after `now` has nothing left to renew, and a 200 would
  # read as time granted. Refused instead, so the session learns its claim is ending (#879).
  defp validate_lease_cap_ahead(%Story{claim_lease_cap: %DateTime{} = cap}, now) do
    if DateTime.after?(cap, now), do: :ok, else: {:error, :lease_cap_reached}
  end

  defp validate_lease_cap_ahead(%Story{}, _now), do: :ok

  @doc """
  Moves a driver-placed claim's cap FORWARD to `anchored_at + wall_clock_seconds +
  Loopctl.Delivery.DispatchLease.grace_seconds/0`, with `claimed_until` moved to the same
  instant (#879, US-44.5). Two callers, each inside a transaction it owns on `repo`:

  - `Loopctl.Runners.DispatchLedger.record_reply/3`, anchored at the runner's `replied_at`
    for an ACCEPTANCE — where `Loopctl.Runners.Capacity` anchors its own bound on the
    session — so the move commits or rolls back with the acceptance.
  - `reanchor_resumed_dispatch_lease/3`, anchored at NOW for a RESUME of the dispatch
    (`Loopctl.Delivery.Placement`), before the frame is pushed, so the `deadline_at` it
    carries leaves the resumed session its whole wall clock.

  `story` is the row as the caller read it IN THAT TRANSACTION under `FOR NO KEY UPDATE` (or
  stronger), or `nil` when there was none. Nothing here takes a lock, so the row judged is
  the row written.

  - `{:ok, story}` for a LIVE claim at `claim_epoch` — in a claimed status, its lease not run
    out. Moved when it carries a cap and the new cap is later; otherwise returned as it is (an
    uncapped claim, or a cap already later: never moved earlier).
  - `{:error, :stale_claim_epoch}` when the story is gone or at another epoch.
  - `{:error, :claim_not_live}` when the claim at that epoch has ended — no longer in a
    claimed status, or its lease past. It is never revived.
  - `{:error, changeset}` when the write or its audit entry is refused. Nothing here raises;
    the caller rolls its transaction back.

  A move bumps `updated_at` and writes a `claim_lease_reanchored` audit-log entry with both
  leases and both caps.
  """
  @spec reanchor_dispatch_lease(Ecto.Repo.t(), Story.t() | nil, %{
          claim_epoch: non_neg_integer(),
          anchored_at: DateTime.t(),
          wall_clock_seconds: pos_integer(),
          actor_label: String.t()
        }) ::
          {:ok, Story.t()}
          | {:error, :stale_claim_epoch | :claim_not_live | Ecto.Changeset.t()}
  def reanchor_dispatch_lease(repo, story, %{
        claim_epoch: epoch,
        anchored_at: %DateTime{} = anchored_at,
        wall_clock_seconds: wall_clock_seconds,
        actor_label: actor_label
      }) do
    case story do
      %Story{claim_epoch: ^epoch} ->
        if live_claim?(story, DateTime.utc_now()),
          do:
            move_cap_forward(
              repo,
              story,
              DispatchLease.cap(anchored_at, wall_clock_seconds),
              actor_label
            ),
          else: {:error, :claim_not_live}

      _gone_or_another_claim ->
        {:error, :stale_claim_epoch}
    end
  end

  @doc """
  `reanchor_dispatch_lease/3` for a RESUME, in a transaction of its own: the story locked
  `FOR NO KEY UPDATE`, then moved. On `Loopctl.Repo` under the tenant's RLS context, the repo
  the resume's push is recorded on next. Every error rolls the transaction back, so a refused
  audit entry leaves the lease where it was.
  """
  @spec reanchor_resumed_dispatch_lease(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, Story.t()}
          | {:error, :stale_claim_epoch | :claim_not_live | Ecto.Changeset.t()}
  def reanchor_resumed_dispatch_lease(tenant_id, story_id, attrs) do
    Repo.with_tenant(tenant_id, fn ->
      story =
        Repo.one(
          from s in Story,
            where: s.id == ^story_id and s.tenant_id == ^tenant_id,
            lock: "FOR NO KEY UPDATE"
        )

      case reanchor_dispatch_lease(Repo, story, attrs) do
        {:ok, story} -> story
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # A NULL lease is a claim made before leases existed, which nothing expires.
  defp live_claim?(%Story{agent_status: status, claimed_until: until}, now)
       when status in @claimed_statuses,
       do: is_nil(until) or DateTime.after?(until, now)

  defp live_claim?(%Story{}, _now), do: false

  defp move_cap_forward(repo, %Story{claim_lease_cap: %DateTime{} = current} = story, cap, label) do
    if DateTime.after?(cap, current) do
      with {:ok, updated} <-
             story
             |> Ecto.Changeset.change(claim_lease_cap: cap, claimed_until: cap)
             |> repo.update(),
           {:ok, _entry} <-
             Audit.create_log_entry(
               story.tenant_id,
               %{
                 entity_type: "story",
                 entity_id: story.id,
                 action: "claim_lease_reanchored",
                 actor_type: "system",
                 actor_label: label,
                 old_state: %{
                   "claimed_until" => iso8601_or_nil(story.claimed_until),
                   "claim_lease_cap" => DateTime.to_iso8601(current)
                 },
                 new_state: %{
                   "claimed_until" => DateTime.to_iso8601(updated.claimed_until),
                   "claim_lease_cap" => DateTime.to_iso8601(updated.claim_lease_cap),
                   "claim_epoch" => updated.claim_epoch
                 }
               },
               repo
             ) do
        {:ok, updated}
      end
    else
      {:ok, story}
    end
  end

  # An uncapped claim — one not taken for a runner dispatch — has no cap to move.
  defp move_cap_forward(_repo, %Story{} = story, _cap, _label), do: {:ok, story}

  @doc """
  The change every RELEASE writes: no lease, no lease cap, and the next epoch. And no
  `lease_reclaim_failed_at`: that stamp describes the lease that ended, not the next claim's.

  The bump is what fences the released claimant. Were a release to leave the epoch
  alone, a session still holding it would pass `check_claim_epoch/3` on a story it no
  longer holds, all the way until somebody claimed it again. Public because
  `Loopctl.BulkOperations` releases too (bulk reject's auto-reset).
  """
  @spec claim_release_change(Story.t()) :: map()
  def claim_release_change(%Story{claim_epoch: epoch}),
    do: %{
      claimed_until: nil,
      claim_lease_cap: nil,
      claim_epoch: epoch + 1,
      review_requested_at: nil,
      lease_reclaim_failed_at: nil
    }

  @doc """
  Clears a story's `implementer_dispatch_id` when the dispatch it names NEVER IMPLEMENTED
  ANYTHING — the placement compensation path (`Loopctl.Delivery.Placement`, #803) and nothing
  else.

  `release_claim_changes/1` deliberately does not clear it: an unclaimed or reclaimed story
  keeps the provenance of who was working on it, which is what the L4 gates compare. The one
  case where that provenance is VACUOUS is a placement that claimed a story, failed before any
  session started, and released it again — the recorded dispatch did nothing.

  ## What a stale id actually costs, corrected (#833 round 3)

  This docstring used to say that a REVOKED recorded dispatch resolves to an empty lineage and
  is therefore worse than an unrevoked one. **That is false and nothing in the code ever did
  it.** `lineage_status/2` resolves through `get_dispatch_lineage/2` -> `Dispatches.get_dispatch/2`,
  a plain `get_by` with NO `revoked_at` filter, and `Dispatches.revoke/2` stamps `revoked_at`
  and leaves `lineage_path` intact — so a revoked dispatch resolves exactly like a live one.
  `:unresolvable` comes only from a MISSING or FOREIGN row. The confusion was with
  `Dispatches.lineage_for_api_key/2`, which DOES exclude revoked dispatches, but that is the
  CALLER side, not the story side.

  So revocation changes nothing here, and the real cost of a stale id is the same either way:
  the next claimant is judged against a dispatch that did nothing. An UNLINEAGED claimant (a
  legacy bearer key, a runner's own enrollment key) is refused `caller_lineage_required`; one
  whose lineage happens to share a chain with the stale dispatch is refused
  `self_report_blocked`. Both are a story nobody can report.

  Anything that later relies on "revoking a dispatch neutralises the custody claim on a story"
  is wrong, and this paragraph is here because two of us asserted it to each other and neither
  checked.

  ## The WHERE is the dispatch id and the tenant, and that is ALL it needs

  There was an `agent_status == :pending` condition here, to leave a story somebody re-claimed
  between the release and this call alone. It was wrong, and the case it was protecting does
  not exist: a re-claim THROUGH A DISPATCH overwrites `implementer_dispatch_id`, so the id
  predicate already declines those; a re-claim with a LEGACY BEARER key writes no dispatch id
  at all, so the story keeps THIS one — and there the stale id is just as poisonous for the new
  claimant, who is exactly the unlineaged caller the gate refuses. Clearing is right in every
  case the id predicate admits.

  Dropping it also removed a dependency on the release having SUCCEEDED, which was a live bug:
  `release_claim/4` swallows every failure, so the story could still be `:assigned` when this
  ran, the condition missed, and the stale id survived the lease — which
  `release_claim_changes/1` never clears either.

  The id predicate stays load-bearing and may not be relaxed: it is what stops this erasing a
  DIFFERENT implementer's provenance.
  """
  @spec clear_unused_implementer_dispatch(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, :cleared | :unchanged}
  def clear_unused_implementer_dispatch(tenant_id, story_id, dispatch_id)
      when is_binary(tenant_id) and is_binary(story_id) and is_binary(dispatch_id) do
    {count, _} =
      from(s in Story,
        where: s.tenant_id == ^tenant_id and s.id == ^story_id,
        where: s.implementer_dispatch_id == ^dispatch_id
      )
      |> AdminRepo.update_all(set: [implementer_dispatch_id: nil])

    if count == 1 do
      audit_dispatch_cleared(tenant_id, story_id, dispatch_id)
      {:ok, :cleared}
    else
      {:ok, :unchanged}
    end
  end

  # `update_all` bypasses changesets, so nothing would otherwise record that the story STOPPED
  # naming this dispatch — while the hash chain still carries `dispatch_created` and
  # `story_stage_claimed` naming it. An operator reading the chain alone would conclude the
  # story is still attributed to a dispatch it no longer names.
  #
  # The audit LOG rather than the chain: the chain is for custody-critical TRANSITIONS
  # (`StageMachine.chained?/3`) and appending needs a `Repo` transaction plus a resolved actor
  # lineage, neither of which a compensation step has. This is the tier `force_unclaim_story/3`
  # writes its own release to, and it is enough to answer "where did the provenance go".
  defp audit_dispatch_cleared(tenant_id, story_id, dispatch_id) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "story",
      entity_id: story_id,
      action: "implementer_dispatch_cleared",
      actor_type: "system",
      actor_label: "placement:compensation",
      old_state: %{"implementer_dispatch_id" => dispatch_id},
      new_state: %{"implementer_dispatch_id" => nil}
    })
  end

  # The one release shape shared by unclaim, force-unclaim and the lease reclaimer.
  defp release_claim_changes(story) do
    Map.merge(
      %{
        agent_status: :pending,
        assigned_agent_id: nil,
        assigned_at: nil,
        reported_done_at: nil,
        reported_by_agent_id: nil,
        # Durable record that this story WAS worked — the dispatch markers being
        # cleared right here is exactly what backfill would otherwise read as
        # "never dispatched". A COLUMN no changeset casts, so a PATCH cannot
        # erase it. See guard_no_lifecycle_history/2.
        lifecycle_entered_at: lifecycle_stamp(story)
      },
      claim_release_change(story)
    )
  end

  @doc """
  Renews the caller's claim: extends `claimed_until` to now plus `claim_lease_seconds/0`.

  The new lease runs from NOW, not from the old `claimed_until`, so renewing often
  cannot bank an unbounded lease. Renewing a claim made before leases existed (NULL
  `claimed_until`) gives it one, and from then on the reclaimer can release it.

  A claim taken for a runner dispatch carries a `claim_lease_cap` (#879), and its lease
  already IS that cap: the claim, and every move of the cap (`reanchor_dispatch_lease/3`),
  write the two together. So renewing a driver-placed claim writes NOTHING — no lease and no
  `claim_renewed` entry — and answers the story with its lease as it stands, which is the
  dispatch deadline. Once the cap has passed it is refused `:lease_cap_reached` instead.

  ## Options

  - `:agent_id` -- the caller's agent (must be the story's assigned agent)
  - `:claim_epoch` -- the epoch the caller was given by its claim
  - `:actor_id`, `:actor_label` -- audit attribution

  ## Returns

  - `{:ok, %Story{}}` on success — renewed, or for a capped claim as it stands
  - `{:error, :not_found}` if the story is not in the tenant
  - `{:error, :not_claimed}` if the story is not `assigned` or `implementing`
  - `{:error, :stale_claim_epoch}` if the presented epoch is not the current one —
    the caller's claim ended (released, reclaimed, or claimed again)
  - `{:error, :not_claimant}` if the caller is not the story's assigned agent
  - `{:error, :lease_cap_reached}` if the claim's `claim_lease_cap` is not after now: a
    renewal could only write a lease already in the past, so none is written
  """
  @spec renew_claim(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Story.t()}
          | {:error,
             :not_found | :not_claimed | :stale_claim_epoch | :not_claimant | :lease_cap_reached}
          | {:error, Ecto.Changeset.t()}
  def renew_claim(tenant_id, story_id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    epoch = Keyword.get(opts, :claim_epoch)

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes ->
        lock_story(tenant_id, story_id)
      end)
      |> Multi.run(:validate, fn _repo, %{lock: story} ->
        # `now` is read AFTER the lock: a renewal that waited on it (behind an acceptance's
        # re-anchor, say) would otherwise judge the cap, and write the lease, from the instant
        # it started waiting. The one value serves both, so they cannot disagree.
        now = DateTime.utc_now()

        # Epoch before identity: a session whose claim ended learns THAT, which is the
        # one fact it can act on, even when a peer now holds the story.
        with :ok <- validate_claimed(story),
             :ok <- validate_claim_epoch(story, epoch),
             :ok <- validate_claimant(story, agent_id),
             :ok <- validate_lease_cap_ahead(story, now) do
          {:ok, {story, now}}
        end
      end)
      |> Multi.merge(fn %{validate: {story, now}} -> renewal(tenant_id, story, now, opts) end)

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :lock, reason, _} -> {:error, reason}
      {:error, :validate, reason, _} -> {:error, reason}
      {:error, :story, changeset, _} -> {:error, changeset}
    end
  end

  # A CAPPED claim has nothing to renew: its lease already is its cap (see `renew_claim/3`),
  # so it is answered as it stands, with no write and no `claim_renewed` entry.
  defp renewal(_tenant_id, %Story{claim_lease_cap: %DateTime{}} = story, _now, _opts),
    do: Multi.put(Multi.new(), :story, story)

  defp renewal(tenant_id, %Story{} = old, now, opts) do
    agent_id = Keyword.get(opts, :agent_id)

    Multi.new()
    |> Multi.update(
      :story,
      Ecto.Changeset.change(old, claimed_until: DateTime.add(now, claim_lease_seconds(), :second))
    )
    |> Audit.log_in_multi(:audit, fn %{story: updated} ->
      %{
        tenant_id: tenant_id,
        entity_type: "story",
        entity_id: updated.id,
        action: "claim_renewed",
        actor_type: "api_key",
        actor_id: Keyword.get(opts, :actor_id),
        actor_label: Keyword.get(opts, :actor_label),
        old_state: %{"claimed_until" => iso8601_or_nil(old.claimed_until)},
        new_state: %{
          "claimed_until" => DateTime.to_iso8601(updated.claimed_until),
          "claim_epoch" => updated.claim_epoch,
          "agent_id" => agent_id
        }
      }
    end)
  end

  @doc "A story's current `claim_epoch`, or nil when it does not exist in the tenant."
  @spec current_claim_epoch(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer() | nil
  def current_claim_epoch(tenant_id, story_id) do
    from(s in Story,
      where: s.id == ^story_id and s.tenant_id == ^tenant_id,
      select: s.claim_epoch
    )
    |> AdminRepo.one()
  end

  @doc """
  The claim fence: `:ok` when `epoch` is the story's current `claim_epoch`.

  For the runner channel (#803) to require on every runner-to-control message about a
  story. Every claim and every release bumps the epoch, so equality means no release
  has happened since the sender's claim — a session resurrected after its claim was
  reclaimed (or released and re-claimed) presents an older epoch and is refused.

  The epoch is a FENCE against a stale sender, not a credential: it is readable on the
  story, and the identity checks on each operation still apply.
  """
  @spec check_claim_epoch(Ecto.UUID.t(), Ecto.UUID.t(), integer()) ::
          :ok | {:error, :stale_claim_epoch | :not_found}
  def check_claim_epoch(tenant_id, story_id, epoch) do
    current =
      from(s in Story,
        where: s.id == ^story_id and s.tenant_id == ^tenant_id,
        select: s.claim_epoch
      )
      |> AdminRepo.one()

    case current do
      nil -> {:error, :not_found}
      ^epoch -> :ok
      _other -> {:error, :stale_claim_epoch}
    end
  end

  @doc """
  Releases a claim whose lease has run out. Called by
  `Loopctl.Workers.ReclaimExpiredClaimsWorker` with the `claim_epoch` it read.

  Everything is re-checked under the story's row lock, so the sweep's read is only a
  candidate list: a claim RENEWED since that read (its `claimed_until` moved into the
  future), released or re-claimed (its epoch moved), or reported done (it left the
  claimed statuses) is left alone with `{:error, :claim_not_expired}`. That also makes
  two concurrent sweeps safe: the second one locks after the first commits, reads
  `:pending`, and skips.

  The release is force-unclaim's: back to `:pending`, assignment cleared,
  `lifecycle_entered_at` stamped (so the backfill launder guard keeps refusing the
  story), lease cleared and epoch bumped. Recorded as a `claim_lease_expired` audit
  entry by the system actor, and announced as `story.force_unclaimed` with
  `reason: "claim_lease_expired"`. A delivery stage row in flight is moved back to
  `queued` in the same transaction (`Loopctl.Delivery.Stages.follow_release/5`), and the lost
  lease counts as a spent attempt: below `DISPATCH_MAX_ATTEMPTS` the story is re-contracted so
  the driver places it again, at the ceiling it is escalated over `:attempts_exhausted`
  (US-44.4). The story returned is the story as it stands after that.

  A story with NO lease (`claimed_until` NULL — claimed before leases existed, and
  never renewed since) is never reclaimed: nothing renews those claims, so a lease
  applied retroactively would release in-flight work. Nor is a story whose review has
  been requested (`review_requested_at` set): the implementer's lease stopped applying
  when it handed the work to review.

  A tenant whose claimants CANNOT RENEW is refused, read under a `FOR SHARE` lock on
  the tenant row taken BEFORE the story lock: a custody HALT (`{:error, :custody_halted}`
  — `renew-claim` is custody surface) or any status other than `:active`
  (`{:error, :tenant_inactive}` — `ResolveApiKey` 403s every request from such a tenant,
  renew-claim included). The share lock means a halt or suspension that lands after the
  sweep's read still wins, and the tenant-then-story order matches
  `Loopctl.Tenants.clear_custody_halt/1` and `Loopctl.Tenants.activate_tenant/1`, which
  update the tenant and then the leases.

  ## A budget-killed session's claim is never re-queued here

  THE RECLAIM IS THE RE-DRIVER OF A BUDGET KILL (US-44.3 review round 3). When the claim
  about to be released ran under an ACCEPTED dispatch whose runner recorded a budget kill in
  `session_ended` (`runner_dispatches.session_ended_reason` `wall_clock_exceeded` or
  `max_turns_exceeded`), the channel's own escalation of it did not complete — the lease
  would not have run out otherwise — so the reclaim takes the SAME escalation first, through
  the one function the channel uses (`Loopctl.Delivery.RunnerStages.redrive_recorded_session_end/4`,
  in-flight row -> `escalated` over `:budget_reported`), and only then releases the claim.
  The row is then no longer in flight, so the release only rebinds it: the story is
  `pending` behind an `escalated` row, which is held (`Loopctl.Delivery.Stages.held_story_ids/2`),
  and never back in the queue. That release is audited as the session end it is —
  `claim_session_ended` with the reported `session_ended_reason`, webhook reason
  `session_ended:<reason>` — by the system actor that ran it, not as a lease expiry.

  If the escalation is REFUSED again — a tenant chain that still refuses appends, a lock that
  was not free — nothing is released: the claim stays held, the refusal is logged at error,
  and `{:error, :budget_escalation_refused}` is returned. The next sweep finds the same
  expired lease and tries again, so the story is escalated once an operator has repaired the
  chain, and "a budget-killed story is never re-queued" holds on every path.
  """
  @spec reclaim_expired_claim(Ecto.UUID.t(), Ecto.UUID.t(), non_neg_integer()) ::
          {:ok, Story.t()}
          | {:error,
             :not_found
             | :claim_not_expired
             | :custody_halted
             | :tenant_inactive
             | :budget_escalation_refused
             | :usage_hold_busy
             | :audit_chain_append_failed
             | Ecto.Changeset.t()}
  def reclaim_expired_claim(tenant_id, story_id, expected_epoch) do
    now = DateTime.utc_now()
    label = "worker:reclaim_expired_claims"

    lease = %{
      gate: fn -> lock_tenant_if_claims_renewable(tenant_id) end,
      held?: &lease_expired?(&1, expected_epoch, now),
      not_held: :claim_not_expired,
      actor_type: "system",
      actor_id: nil,
      actor_label: label,
      # A lease that ran out is an attempt spent and lost (US-44.4).
      cause: :attempt
    }

    case RunnerStages.redrive_recorded_session_end(tenant_id, story_id, expected_epoch, label) do
      :none ->
        runner_lost_release(
          tenant_id,
          story_id,
          Map.merge(lease, %{
            action: "claim_lease_expired",
            webhook_reason: "claim_lease_expired",
            new_state: %{}
          })
        )

      # An exhausted subscription, its machine held out: released as that session end, and
      # spending no attempt.
      {:ok, "usage_exhausted" = reason} ->
        runner_lost_release(
          tenant_id,
          story_id,
          Map.merge(lease, %{
            action: "claim_session_ended",
            webhook_reason: "session_ended:" <> reason,
            new_state: %{"session_ended_reason" => reason},
            cause: :usage_exhausted
          })
        )

      # The hold needs a lock: nothing released, the next sweep retries.
      {:error, {:usage_hold, :busy}} ->
        {:error, :usage_hold_busy}

      {:ok, reason} ->
        runner_lost_release(
          tenant_id,
          story_id,
          Map.merge(lease, %{
            action: "claim_session_ended",
            webhook_reason: "session_ended:" <> reason,
            new_state: %{"session_ended_reason" => reason}
          })
        )

      {:error, refusal} ->
        Logger.error(
          "reclaim left a budget-killed claim HELD: its escalation was refused again, and " <>
            "the next sweep retries it — tenant_id=#{tenant_id} story_id=#{story_id} " <>
            "claim_epoch=#{expected_epoch} refusal=#{inspect(refusal)}"
        )

        {:error, :budget_escalation_refused}
    end
  end

  @doc """
  Releases a claim whose runner REPORTED that its session ended — `crashed`,
  `usage_exhausted` or a budget kill (`wall_clock_exceeded`, `max_turns_exceeded`) in a
  `session_ended` message (US-44.3, runner contract 1.16.0) — without waiting for the lease.

  It is `reclaim_expired_claim/3` with the lease taken out of the question and nothing else
  changed: the same release (`release_claim_changes/1` — back to `:pending`, assignment
  cleared, `lifecycle_entered_at` stamped, lease cleared, epoch bumped), the same
  `:runner_lost` edge on the delivery stage row in the same transaction
  (`Loopctl.Delivery.Stages.follow_release/5`), and the same audit entry and webhook, built by
  the one private function both call. What differs is only what is TRUE: the entry's `action`
  is `claim_session_ended`, not `claim_lease_expired`, because no lease expired, and its
  `new_state` names the reported reason, because a crash and an exhausted subscription are
  different things to an operator reading the log. The entry is attributed to the runner's
  credential — `actor_type` `"api_key"`, `actor_id` the runner's key (`:actor_id`) — because
  its label names the runner and it was the runner's message that ended the claim; the
  reclaim's `"system"` is true only of the worker that times a lease out.

  What the stage row does is `follow_release/5`'s rule, unchanged: an in-flight row goes back
  to `queued` — counted in its `attempts` when `:cause` is `:attempt` — and a row elsewhere is
  only rebound to the new epoch. A requeued story is then re-contracted, or for a counted
  release that reaches the retry ceiling, escalated over `:attempts_exhausted` (US-44.4).
  WHETHER a re-queue is an attempt is the CALLER's decision, passed as `:cause` (required,
  `:attempt` or `:usage_exhausted`), never re-derived here from the reason:
  `Loopctl.Delivery.RunnerStages` decides it from the same function that writes the dispatch
  ledger's `counts_toward_retry_ceiling`, so the two records cannot disagree. A budget kill's row
  has already been escalated by then (`Loopctl.Delivery.RunnerStages.end_session/4` escalates
  first, and calls this only once that escalation has landed or had nothing to change), so it
  stays `escalated`: ending the claim never re-queues a story the budget stopped. When the
  escalation does not land, the claim is left held and `reclaim_expired_claim/3` re-drives it.

  THE CLAIM MUST BE THE ONE THE SESSION RAN UNDER: held (`:assigned` or `:implementing`), at
  exactly `expected_epoch` — the reporting dispatch's own — and not handed to review. Anything
  else is `{:error, :claim_not_held}` and nothing is written, because each of those means the
  claim this report is about has already ended, or was never this session's to give back: a
  lease reclaim, an operator's unclaim or a re-claim moved the epoch, and a claim whose review
  was requested stopped being the implementer's when it was handed over. The epoch is what
  makes a late or replayed report harmless — it can never release a claim that started after
  the session it describes.

  NO TENANT GATE, unlike the reclaim, and deliberately. The reclaim refuses a halted or
  inactive tenant because its claimants CANNOT RENEW, and releasing a lease they could not
  have kept would punish them for the halt. Here nobody is being timed out: the claimant
  itself reported that its session is gone, so there is nothing to protect, and a halt stops
  custody PROGRESS while a release gives a claim back.

  WHICH reasons end a claim is the caller's decision, not re-checked here:
  `Loopctl.Delivery.RunnerStages` calls this only from the clauses of its session-end action
  that end one, and never for `completed`.
  """
  @spec release_ended_session(Ecto.UUID.t(), Ecto.UUID.t(), non_neg_integer(), keyword()) ::
          {:ok, Story.t()}
          | {:error,
             :not_found
             | :claim_not_held
             | :audit_chain_append_failed
             | Ecto.Changeset.t()}
  def release_ended_session(tenant_id, story_id, expected_epoch, opts) do
    session_reason = Keyword.fetch!(opts, :session_reason)
    actor_label = Keyword.fetch!(opts, :actor_label)
    actor_id = Keyword.fetch!(opts, :actor_id)

    runner_lost_release(tenant_id, story_id, %{
      # BOUNDED, unlike the reclaim's wait: this runs in the runner channel's own process, and
      # a wait without end behind a story lock would hold the socket every session on that
      # machine shares. A wait that runs out raises `lock_not_available`, which the caller
      # answers as a retry — nothing here has committed.
      gate: fn -> {:ok, Capacity.set_lock_timeout!(AdminRepo)} end,
      held?: &claim_held_at?(&1, expected_epoch),
      not_held: :claim_not_held,
      action: "claim_session_ended",
      actor_type: "api_key",
      actor_id: actor_id,
      actor_label: actor_label,
      webhook_reason: "session_ended:" <> session_reason,
      new_state: %{"session_ended_reason" => session_reason},
      cause: Keyword.fetch!(opts, :cause)
    })
  end

  # THE ONE `:runner_lost` RELEASE, shared by the lease reclaim and a reported session end so
  # the two cannot drift: a gate, the story locked and re-checked, then released, its stage
  # row following in the same transaction, one audit entry and one webhook. `spec` carries
  # only what differs between them — the gate run first (`gate`, a `{:ok, _} | {:error, _}`
  # thunk), the predicate the locked story must satisfy (`held?`) and the refusal when it does
  # not (`not_held`), the action, the actor, the webhook's reason, any keys the audit entry
  # adds to `new_state` on top of the ones every release records, and WHY the claim was
  # released (`cause`), which decides where the story goes next (`Stages.follow_release/5`).
  defp runner_lost_release(tenant_id, story_id, spec) do
    Multi.new()
    |> Multi.run(:gate, fn _repo, _changes -> spec.gate.() end)
    |> Multi.run(:lock, fn _repo, _changes -> lock_story(tenant_id, story_id) end)
    |> Multi.run(:validate, fn _repo, %{lock: story} ->
      if spec.held?.(story), do: {:ok, story}, else: {:error, spec.not_held}
    end)
    |> Multi.run(:story, fn _repo, %{lock: story} ->
      story
      |> Ecto.Changeset.change(release_claim_changes(story))
      |> AdminRepo.update()
    end)
    # #803: the claimant is gone, so its delivery stage row follows the release in THIS
    # transaction — the two commit together or not at all. A row left behind the new epoch
    # would be refused on every advance with nothing able to move it.
    |> Multi.run(:stage, fn _repo, %{story: updated} ->
      Stages.follow_release(tenant_id, updated.id, updated.claim_epoch, :runner_lost,
        cause: spec.cause,
        # Both principals behind this release hold no dispatch lineage: the reclaim worker is
        # the system, and a runner's credential is a plain `api_keys` row no dispatch minted.
        actor_lineage: [],
        actor_label: spec.actor_label
      )
    end)
    |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
      %{
        tenant_id: tenant_id,
        entity_type: "story",
        entity_id: updated.id,
        action: spec.action,
        actor_type: spec.actor_type,
        actor_id: spec.actor_id,
        actor_label: spec.actor_label,
        old_state: %{
          "agent_status" => to_string(old.agent_status),
          "assigned_agent_id" => old.assigned_agent_id,
          "claimed_until" => iso8601_or_nil(old.claimed_until),
          "claim_epoch" => old.claim_epoch
        },
        new_state:
          Map.merge(
            %{"agent_status" => "pending", "claim_epoch" => updated.claim_epoch},
            spec.new_state
          )
      }
    end)
    |> EventGenerator.generate_events(:webhook_events, fn %{story: updated, lock: old} ->
      %{
        tenant_id: tenant_id,
        event_type: "story.force_unclaimed",
        project_id: updated.project_id,
        payload: %{
          "event" => "story.force_unclaimed",
          "reason" => spec.webhook_reason,
          "story_id" => updated.id,
          "project_id" => updated.project_id,
          "epic_id" => updated.epic_id,
          "old_status" => to_string(old.agent_status),
          "new_status" => "pending",
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
        }
      }
    end)
    # AFTER the release's own audit and webhook (see `Stages.recontract_released/4`).
    |> Multi.run(:recontract, fn _repo, %{story: updated, stage: released} ->
      Stages.recontract_released(tenant_id, released, updated, spec.actor_label)
    end)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{recontract: story, stage: released}} ->
        Stages.announce_release(released)
        {:ok, story}

      # EVERY step, not the four this used to name: a refusal at `:stage`, `:audit` or
      # `:webhook_events` raised `CaseClauseError`, which on the session-end path is inside the
      # runner channel's process. Each step's error is already the caller's reason — an atom
      # (`:audit_chain_append_failed` from `:stage`), or the changeset `:story` or `:audit`
      # refused.
      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # The claim a session ran under, still held: `lease_expired?/3` without the lease. The same
  # statuses, the same epoch, and the same exclusion of a claim handed to review.
  defp claim_held_at?(
         %Story{agent_status: status, claim_epoch: epoch, review_requested_at: nil},
         expected_epoch
       )
       when status in @claimed_statuses,
       do: epoch == expected_epoch

  defp claim_held_at?(_story, _expected_epoch), do: false

  # "Can this tenant's claimants renew right now?" — the one condition every lease release
  # depends on. Two things make the answer no, and both are refused: a custody halt
  # (renew-claim is custody surface) and a tenant that is not `:active` (ResolveApiKey
  # 403s every request, renew-claim included — suspended, deactivated, or never enrolled).
  #
  # SHARE-locks the tenant row for the rest of the reclaim's transaction, so a halt or a
  # status change (an UPDATE of that row) cannot commit between this check and the release.
  defp lock_tenant_if_claims_renewable(tenant_id) do
    from(t in Tenants.Tenant,
      where: t.id == ^tenant_id,
      select: {t.status, t.custody_halted_at},
      lock: "FOR SHARE"
    )
    |> AdminRepo.one()
    |> case do
      nil -> {:error, :not_found}
      {_status, %DateTime{}} -> {:error, :custody_halted}
      {:active, nil} -> {:ok, :renewable}
      {_inactive, nil} -> {:error, :tenant_inactive}
    end
  end

  @doc """
  Seconds of renewal grace every live lease gets when a tenant's claimants become able to
  renew again — a custody halt cleared, or the tenant returned to `:active`: one full
  lease, `claim_lease_seconds/0`.

  `renew-claim` is unreachable for the whole halt or suspension, so without this every
  lease that ran out during it would be reclaimed by the first sweep afterwards — before a
  single claimant could renew. One LEASE rather than a fixed number of minutes, because
  the lease is by definition the window a claimant is expected to renew within, and it
  moves with `STORY_CLAIM_LEASE_SECONDS`; a fixed grace shorter than a claimant's renewal
  cadence would recreate the defect.
  """
  @spec renewal_grace_seconds() :: pos_integer()
  def renewal_grace_seconds, do: claim_lease_seconds()

  @doc """
  Extends every live, leased claim in the tenant to at least `now` plus
  `renewal_grace_seconds/0`. A lease already past that point is left alone, and a NULL
  lease stays NULL. Returns how many leases moved.

  A claim with a `claim_lease_cap` (#879) is not touched and not counted: its lease already
  IS its cap (`renew_claim/3` says why), and no renewal moves a lease past the dispatch
  deadline.

  Called INSIDE the transaction of each transition that makes renewal possible again —
  `Loopctl.Tenants.clear_custody_halt/1` and `Loopctl.Tenants.activate_tenant/1` — after
  the tenant row is updated: the same tenant-then-story lock order
  `reclaim_expired_claim/3` takes, so they cannot deadlock and no sweep can see the
  renewable tenant with the old leases.
  """
  @spec grant_renewal_grace(Ecto.UUID.t(), DateTime.t()) :: non_neg_integer()
  def grant_renewal_grace(tenant_id, %DateTime{} = now \\ DateTime.utc_now()) do
    floor = DateTime.add(now, renewal_grace_seconds(), :second)

    {count, _} =
      from(s in Story,
        where:
          s.tenant_id == ^tenant_id and s.agent_status in ^@claimed_statuses and
            not is_nil(s.claimed_until) and s.claimed_until < ^floor and
            is_nil(s.claim_lease_cap)
      )
      |> AdminRepo.update_all(set: [claimed_until: floor])

    if count > 0 do
      Logger.info(
        "claim_lease_renewal_grace: extended #{count} claim lease(s) to " <>
          "#{DateTime.to_iso8601(floor)} as renewal became possible again tenant_id=#{tenant_id}"
      )
    end

    count
  end

  # Every clause is load-bearing and re-read under the lock: the status (a reported or
  # released story is not a held claim), a lease that exists at all (NULL is never
  # reclaimed), a lease still in the past (a renewal between the sweep's read and this
  # lock moved it), and the epoch the sweep read (a release plus a re-claim in that
  # window started a DIFFERENT claim, whose lease is not the one that expired), and no
  # review requested (once handed to review, the implementer's lease no longer applies).
  defp lease_expired?(
         %Story{
           agent_status: status,
           claimed_until: %DateTime{} = until,
           claim_epoch: epoch,
           review_requested_at: nil
         },
         expected_epoch,
         now
       )
       when status in @claimed_statuses do
    epoch == expected_epoch and DateTime.compare(until, now) == :lt
  end

  defp lease_expired?(_story, _expected_epoch, _now), do: false

  defp validate_claimed(%Story{agent_status: status}) when status in @claimed_statuses, do: :ok
  defp validate_claimed(_story), do: {:error, :not_claimed}

  defp validate_claim_epoch(%Story{claim_epoch: epoch}, epoch) when is_integer(epoch), do: :ok
  defp validate_claim_epoch(_story, _presented), do: {:error, :stale_claim_epoch}

  # start/report accept the epoch OPTIONALLY: absent, they behave exactly as they did
  # before the fence, so existing MCP clients keep working. The delivery-loop runner
  # path will send it on every call, and that path is where it becomes mandatory.
  defp validate_optional_claim_epoch(_story, nil), do: :ok
  defp validate_optional_claim_epoch(story, epoch), do: validate_claim_epoch(story, epoch)

  defp validate_claimant(_story, nil), do: {:error, :not_claimant}
  defp validate_claimant(%Story{assigned_agent_id: agent_id}, agent_id), do: :ok
  defp validate_claimant(_story, _agent_id), do: {:error, :not_claimant}

  defp iso8601_or_nil(nil), do: nil
  defp iso8601_or_nil(%DateTime{} = at), do: DateTime.to_iso8601(at)

  # --- Review Records ---

  @doc """
  Records that an independent review was completed for a story.

  Creates a `review_record` proving the review pipeline ran. The `verify_story/4`
  function checks for the existence of a valid review record (completed AFTER
  `reported_done_at`) before allowing verification to proceed.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `params` -- map with `review_type` (required), optional `findings_count`,
    `fixes_count`, `summary`, `completed_at`
  - `opts` -- keyword list with `:reviewer_agent_id`, `:actor_id`, `:actor_label`,
    and `:reviewer_lineage` (the caller's dispatch lineage path, resolved
    server-side — used to block a sub-agent dispatched by the implementer)

  ## Returns

  - `{:ok, %ReviewRecord{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :story_not_reported_done}` if story is not in reported_done status
  - `{:error, :self_review_blocked}` if the reviewer is the assigned agent or lies on
    the implementer's dispatch lineage chain
  - `{:error, :caller_lineage_required}` if a key no dispatch minted reviews
    dispatch-minted work (the nil-reviewer human-operator permit requires BOTH a nil
    `:reviewer_agent_id` and an empty `:reviewer_lineage`)
  - `{:error, :missing_assigned_agent}` on a custody-orphaned story (fails closed)
  - `{:error, :unresolvable_dispatch_lineage}` if the story's declared implementer
    dispatch cannot be resolved (lineage-integrity failure, fails closed — LCP-1 §7.5)
  - `{:error, %Ecto.Changeset{}}` on validation failure
  """
  @spec record_review(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, ReviewRecord.t()} | {:error, atom() | Ecto.Changeset.t()}
  def record_review(tenant_id, story_id, params, opts \\ []) do
    reviewer_agent_id = Keyword.get(opts, :reviewer_agent_id)

    with {:ok, story} <- fetch_story_for_review(tenant_id, story_id),
         :ok <- validate_story_reported_done(story),
         :ok <-
           validate_not_self_review(
             story,
             reviewer_agent_id,
             Keyword.get(opts, :reviewer_lineage, [])
           ) do
      attrs = build_review_attrs(params)

      changeset =
        %ReviewRecord{
          tenant_id: tenant_id,
          story_id: story_id,
          reviewer_agent_id: reviewer_agent_id,
          # INVARIANT 2: bind this review to the report generation it reviewed by
          # snapshotting the story's CURRENT reported_done_at. Programmatic (never
          # cast from client input). verify_story/4 + bulk_verify later require
          # this to match the story's reported_done_at at verify time.
          reviewed_report_at: story.reported_done_at
        }
        |> ReviewRecord.create_changeset(attrs)

      multi =
        Multi.new()
        |> Multi.insert(:review_record, changeset)
        |> enqueue_knowledge_extraction(tenant_id)
        |> maybe_chain_signed_claim(tenant_id, story_id, opts)

      handle_review_transaction(
        AdminRepo.transaction(multi),
        tenant_id,
        story,
        attrs,
        reviewer_agent_id
      )
    end
  end

  defp build_review_attrs(params) do
    %{
      review_type: Map.get(params, "review_type") || Map.get(params, :review_type),
      findings_count: Map.get(params, "findings_count") || Map.get(params, :findings_count, 0),
      fixes_count: Map.get(params, "fixes_count") || Map.get(params, :fixes_count, 0),
      disproved_count: Map.get(params, "disproved_count") || Map.get(params, :disproved_count, 0),
      summary: Map.get(params, "summary") || Map.get(params, :summary),
      completed_at:
        Map.get(params, "completed_at") || Map.get(params, :completed_at) || DateTime.utc_now()
    }
  end

  defp enqueue_knowledge_extraction(multi, tenant_id) do
    Multi.run(multi, :enqueue_knowledge_worker, fn _repo, %{review_record: rr} ->
      tenant = AdminRepo.get(Tenants.Tenant, tenant_id)

      if knowledge_auto_extract_enabled?(tenant) do
        ReviewKnowledgeWorker.new(%{review_record_id: rr.id, tenant_id: tenant_id})
        |> Oban.insert()
      else
        {:ok, :skipped}
      end
    end)
  end

  defp knowledge_auto_extract_enabled?(nil), do: true

  defp knowledge_auto_extract_enabled?(%Tenants.Tenant{} = tenant) do
    Tenants.get_tenant_settings(tenant, "knowledge_auto_extract", true) != false
  end

  defp handle_review_transaction(
         {:ok, %{review_record: review_record}},
         tenant_id,
         story,
         attrs,
         reviewer_agent_id
       ) do
    insert_events_with_delivery(tenant_id, "story.review_completed", story.project_id, %{
      "event" => "story.review_completed",
      "story_id" => story.id,
      "project_id" => story.project_id,
      "epic_id" => story.epic_id,
      "reviewer_agent_id" => reviewer_agent_id,
      "review_type" => attrs.review_type,
      "findings_count" => attrs.findings_count,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    })

    {:ok, review_record}
  end

  defp handle_review_transaction({:error, :review_record, changeset, _}, _, _, _, _) do
    {:error, changeset}
  end

  defp handle_review_transaction({:error, :enqueue_knowledge_worker, reason, _}, _, _, _, _) do
    {:error, reason}
  end

  defp fetch_story_for_review(tenant_id, story_id) do
    query =
      Story
      |> where([s], s.id == ^story_id and s.tenant_id == ^tenant_id)

    case AdminRepo.one(query) do
      nil -> {:error, :not_found}
      story -> {:ok, story}
    end
  end

  defp validate_story_reported_done(%Story{agent_status: :reported_done}), do: :ok

  defp validate_story_reported_done(_story), do: {:error, :story_not_reported_done}

  # --- Orchestrator Verification (US-7.2) ---

  @doc """
  Verifies a story: orchestrator marks it as passing verification.

  Sets verified_status to `verified` and creates a verification_result
  record with result=pass. Uses pessimistic locking to prevent duplicate
  verifications. Requires agent_status to be `reported_done`.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `params` -- map with `summary` (required), optional `findings`, `review_type`
  - `opts` -- keyword list with `:orchestrator_agent_id`, `:actor_id`,
    `:actor_label`, and `:verifier_lineage` (the CALLER's dispatch lineage,
    resolved server-side — never client-supplied)

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if story is not reported_done
  - `{:error, :self_verify_blocked}` if the verifier is the assigned agent or lies on
    the implementer's dispatch lineage chain
  - `{:error, :caller_lineage_required}` if a key no dispatch minted tries to certify
    dispatch-minted work (fails closed; an ordinary refusal, not a byzantine signal)
  - `{:error, :missing_assigned_agent}` on a custody-orphaned story (fails closed)
  - `{:error, :unresolvable_dispatch_lineage}` if a dispatch the story references
    (implementer or verifier) cannot be resolved (lineage-integrity failure, fails
    closed — LCP-1 §7.4.1)
  """
  @spec verify_story(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Story.t()} | {:error, atom() | {:invalid_transition, map()}}
  def verify_story(tenant_id, story_id, params, opts \\ []) do
    orchestrator_agent_id = Keyword.get(opts, :orchestrator_agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    verification_params = extract_verification_params(params)

    # #621: verify consumes NO capability, for the same reason report does not
    # (see start_story/3). A verify_cap was minted to the lineage
    # Dispatches.select_verifier/3 picks, and Capabilities.verify/2 demands an
    # EXACT lineage match — but that pick is not the principal who calls verify:
    # the pool includes :agent-role dispatches while this endpoint is
    # exact_role: :orchestrator, a legacy env-var orchestrator key resolves to
    # lineage [] and can hold no cap at all, and in a single-root tenant no
    # candidate is eligible so nothing is minted. Every one of those left the
    # story permanently unverifiable, and the bulk path (verify_all_in_epic/4)
    # never carried a cap at all. Verify is gated by L4 structural separation
    # instead — validate_not_self_verify/3, which compares the CALLER's
    # server-resolved lineage (`:verifier_lineage`) against the implementer's
    # exactly as report and review-complete do, plus the loopctl-SELECTED
    # verifier_dispatch_id when request-review recorded one — plus
    # exact_role: :orchestrator. The cap's exact-lineage match bound only the
    # story's recorded verifier; the caller comparison binds the principal that
    # actually makes the call, on EVERY path including the one that skips the
    # optional request-review.
    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes -> lock_story(tenant_id, story_id) end)
      |> Multi.run(:self_verify_check, fn _repo, %{lock: story} ->
        validate_not_self_verify(
          story,
          orchestrator_agent_id,
          Keyword.get(opts, :verifier_lineage, []),
          :verify
        )
      end)
      |> Multi.run(:validate, fn _repo, %{lock: story} ->
        validate_verifiable(story)
      end)
      |> Multi.run(:check_review_record, fn _repo, %{lock: story} ->
        validate_review_record_exists(tenant_id, story_id, story)
      end)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        apply_verified_status(story)
      end)
      |> insert_verification_result(
        tenant_id,
        orchestrator_agent_id,
        verification_params.result,
        verification_params
      )
      |> audit_verification(tenant_id, "verified", actor_id, actor_label, orchestrator_agent_id)
      |> maybe_chain_signed_claim(tenant_id, story_id, opts)
      |> EventGenerator.generate_events(:webhook_events_verified, fn %{story: updated} ->
        %{
          tenant_id: tenant_id,
          event_type: "story.verified",
          project_id: updated.project_id,
          payload: %{
            "event" => "story.verified",
            "story_id" => updated.id,
            "project_id" => updated.project_id,
            "epic_id" => updated.epic_id,
            "orchestrator_agent_id" => orchestrator_agent_id,
            "summary" => verification_params.summary,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)
      |> maybe_complete_epic(tenant_id, actor_id, actor_label)

    unwrap_verification_transaction(multi)
  end

  @doc """
  Chain-of-custody guard for the bulk-verify path.

  Returns `:ok` when `orchestrator_agent_id` is permitted to verify `story`, or
  `{:error, :self_verify_blocked}` when the verifier shares dispatch lineage /
  agent identity with the implementer. A nil `orchestrator_agent_id` is treated
  as an untrusted identity and is always blocked. A custody-orphaned story
  returns `{:error, :missing_assigned_agent}`, and a story whose declared
  implementer dispatch cannot be resolved fails CLOSED with
  `{:error, :unresolvable_dispatch_lineage}` (passed through from
  `verify_lineage_separated/4`).

  `caller_lineage` is the CALLER's dispatch lineage, resolved SERVER-SIDE from the
  authenticating key — never client-supplied. It is REQUIRED: passing `[]` because a
  path did not bother to resolve it used to silence the entire L4 caller comparison and
  leave only agent-id inequality, which an orchestrator key satisfies trivially. On
  dispatch-minted work `[]` now returns `{:error, :caller_lineage_required}` instead.

  `gate` is `:verify` (default) or `:reject`; reject exempts the unlineaged caller so
  bad work can always be sent back (see `unlineaged_caller/3`).

  Exposed so `Loopctl.BulkOperations` enforces the SAME self-verify invariant as
  the single-story `verify_story/4` path — otherwise bulk verify is a chain-of-custody bypass.
  """
  @spec ensure_verify_allowed(Story.t(), Ecto.UUID.t() | nil, [Ecto.UUID.t()], :verify | :reject) ::
          :ok
          | {:error,
             :self_verify_blocked
             | :missing_assigned_agent
             | :unresolvable_dispatch_lineage
             | :caller_lineage_required}
  def ensure_verify_allowed(story, orchestrator_agent_id, caller_lineage, gate \\ :verify) do
    case validate_not_self_verify(story, orchestrator_agent_id, caller_lineage, gate) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns `:ok` when an independent review record exists for `story` after it
  was reported done, else `{:error, :review_not_conducted}`. Mirrors the
  `verify_story/4` review-record requirement for the bulk path.
  """
  @spec ensure_review_conducted(Ecto.UUID.t(), Ecto.UUID.t(), Story.t()) ::
          :ok | {:error, :review_not_conducted}
  def ensure_review_conducted(tenant_id, story_id, story) do
    case validate_review_record_exists(tenant_id, story_id, story) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Structural custody guard for the bulk mark-complete (backfill) path.

  Returns `:ok` only when `story` never entered the dispatch lifecycle — no
  dispatch markers AND no lifecycle history in the audit log — including a
  never-dispatched story already at `agent_status: :reported_done` (e.g. imported
  with `initial_agent_status: "reported_done"`), for which mark-complete is the
  correct remediation. Matches `backfill_story/4`. Prevents mark-complete from
  being used to self-verify dispatched work.

  `lifecycle_ids` is the batch's precomputed lifecycle-history set (see
  `stories_with_lifecycle_history/2`), so a 50-story batch costs one audit query
  rather than 50 inside the locking transaction.
  """
  @spec ensure_mark_complete_allowed(Story.t(), MapSet.t()) ::
          :ok
          | {:error,
             :already_verified
             | :story_rejected
             | :story_has_dispatch_lineage
             | :story_entered_lifecycle
             | :story_in_progress}
  def ensure_mark_complete_allowed(story, lifecycle_ids) do
    case guard_backfillable(story, lifecycle_ids) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Backfills a story's status when the work was completed outside loopctl.

  Sets both `agent_status` and `verified_status` to fully-done values in one
  shot, BUT only for stories that never entered loopctl's dispatch lifecycle
  (`assigned_agent_id IS NULL` and `verified_status` not already `:verified`
  or `:rejected`). This structural guard is what keeps backfill from being a
  chain-of-custody shortcut: if a story was dispatched to an agent, the
  normal report/review/verify flow must be used — NOT backfill.

  Records a provenance marker in `metadata.backfill` and writes an audit
  event with `action: "backfilled"` (source: `"pre_loopctl"`) so the trust
  chain is legible: the work is marked done but explicitly labeled as
  pre-existing rather than loopctl-verified. Emits `story.backfilled` on
  the webhook channel.

  ## Parameters

    * `tenant_id` — the tenant UUID
    * `story_id` — the story UUID
    * `params` — map with `reason` (required, string), optional `evidence_url`, `pr_number`
    * `opts` — keyword list with `:actor_id`, `:actor_label`

  ## Returns

    * `{:ok, %Story{}}` on success
    * `{:error, :not_found}` — story not in tenant
    * `{:error, :reason_required}` — `reason` missing or blank
    * `{:error, :already_verified}` — story already `:verified` (idempotent no-op)
    * `{:error, :story_rejected}` — story is `:rejected`; investigate instead of papering over
    * `{:error, :story_has_dispatch_lineage}` — story has a dispatch marker
      (`assigned_agent_id`, `implementer_dispatch_id`, or `verifier_dispatch_id`);
      use the normal report/review/verify flow
    * `{:error, :story_entered_lifecycle}` — the story's own lifecycle stamp or the
      audit log records that it was worked inside loopctl, even though its dispatch
      markers are now clear; use report/review/verify
    * `{:error, :story_in_progress}` — story is mid-lifecycle (e.g. `:contracted`)
      with no dispatch lineage yet; it is being worked, not pre-existing done work
    * `{:error, %Ecto.Changeset{}}` — persistence error surfaced from Multi step
  """
  @spec backfill_story(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Story.t()}
          | {:error,
             :not_found
             | :reason_required
             | :reason_too_long
             | :invalid_pr_number
             | :invalid_evidence_url
             | :evidence_url_too_long
             | :already_verified
             | :story_rejected
             | :story_has_dispatch_lineage
             | :story_entered_lifecycle
             | :story_in_progress
             | Ecto.Changeset.t()}
  def backfill_story(tenant_id, story_id, params, opts \\ []) do
    reason = params |> Map.get("reason") |> normalize_string()

    with :ok <- validate_backfill_reason(reason),
         {:ok, pr_number} <- cast_pr_number(Map.get(params, "pr_number")),
         {:ok, evidence_url} <-
           validate_evidence_url(params |> Map.get("evidence_url") |> normalize_string()) do
      do_backfill(tenant_id, story_id, reason, evidence_url, pr_number, opts)
    end
  end

  defp validate_backfill_reason(nil), do: {:error, :reason_required}

  defp validate_backfill_reason(reason) when byte_size(reason) > 2_000,
    do: {:error, :reason_too_long}

  defp validate_backfill_reason(_reason), do: :ok

  defp cast_pr_number(nil), do: {:ok, nil}
  defp cast_pr_number(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp cast_pr_number(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid_pr_number}
    end
  end

  defp cast_pr_number(_), do: {:error, :invalid_pr_number}

  defp validate_evidence_url(nil), do: {:ok, nil}

  defp validate_evidence_url(url) when is_binary(url) do
    cond do
      byte_size(url) > 2_000 ->
        {:error, :evidence_url_too_long}

      not String.match?(url, ~r{\Ahttps?://}) ->
        {:error, :invalid_evidence_url}

      # Reject userinfo (user:password@) — common place for leaked tokens
      String.match?(url, ~r{\Ahttps?://[^/]*@}) ->
        {:error, :invalid_evidence_url}

      true ->
        {:ok, url}
    end
  end

  defp do_backfill(tenant_id, story_id, reason, evidence_url, pr_number, opts) do
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    multi =
      Multi.new()
      |> Multi.run(:lock, fn _repo, _changes -> lock_story(tenant_id, story_id) end)
      |> Multi.run(:guard, fn _repo, %{lock: story} -> guard_backfillable(story) end)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        apply_backfill_status(story, reason, evidence_url, pr_number)
      end)
      |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
        %{
          tenant_id: tenant_id,
          entity_type: "story",
          entity_id: updated.id,
          action: "backfilled",
          actor_type: "api_key",
          actor_id: actor_id,
          actor_label: actor_label,
          old_state: %{
            "agent_status" => to_string(old.agent_status),
            "verified_status" => to_string(old.verified_status)
          },
          new_state: %{
            "agent_status" => to_string(updated.agent_status),
            "verified_status" => to_string(updated.verified_status),
            "source" => "pre_loopctl",
            "reason" => reason,
            "evidence_url" => evidence_url,
            "pr_number" => pr_number
          }
        }
      end)
      # LCP-1 §9.4: backfill reaches the same `verified_status: :verified` terminal
      # state as verify and mounts the same RequireSignedClaim gate, so it records the
      # same durable cryptographic residue. Verifying a signature and then dropping it
      # is half a control: the signature evaporates at request end and the record it
      # authorized becomes indistinguishable from one an operator fabricated.
      |> maybe_chain_signed_claim(tenant_id, story_id, opts)
      |> EventGenerator.generate_events(:webhook_events, fn %{story: updated} ->
        %{
          tenant_id: tenant_id,
          event_type: "story.backfilled",
          project_id: updated.project_id,
          payload: %{
            "event" => "story.backfilled",
            "story_id" => updated.id,
            "project_id" => updated.project_id,
            "epic_id" => updated.epic_id,
            "source" => "pre_loopctl",
            "actor_id" => actor_id,
            "actor_label" => actor_label,
            "reason" => reason,
            "evidence_url" => evidence_url,
            "pr_number" => pr_number,
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          }
        }
      end)

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} ->
        handle_backfill_success(updated)

      {:error, :guard, :already_verified, %{lock: story}} ->
        idempotent_check(
          story,
          tenant_id,
          story_id,
          reason,
          evidence_url,
          pr_number,
          actor_id,
          actor_label
        )

      {:error, _step, err, _changes} ->
        {:error, err}
    end
  end

  # Idempotency: if the story is already verified AND its existing backfill
  # metadata matches the incoming params, treat the retry as success and
  # return 200 instead of 422. This makes backfill_story safe to retry after
  # a client-side timeout.
  defp idempotent_check(
         story,
         _tenant_id,
         _story_id,
         reason,
         evidence_url,
         pr_number,
         _actor_id,
         _actor_label
       ) do
    existing = get_in(story.metadata, ["backfill"]) || %{}

    same_payload? =
      Map.get(existing, "reason") == reason and
        Map.get(existing, "evidence_url") == evidence_url and
        Map.get(existing, "pr_number") == pr_number

    if same_payload? do
      {:ok, story}
    else
      {:error, :already_verified}
    end
  end

  defp handle_backfill_success(story), do: {:ok, story}

  # Backfill / bulk mark-complete is ONLY for stories that never entered loopctl's
  # dispatch lifecycle. "Never dispatched" is defined by the ABSENCE of dispatch
  # markers (assigned_agent_id, implementer_dispatch_id, verifier_dispatch_id) —
  # NOT by agent_status == :pending. This matters because a story imported with
  # `initial_agent_status: "reported_done"` (or a prior mark-complete) is
  # never-dispatched work sitting at agent_status == :reported_done with NULL
  # dispatch markers; backfill/mark-complete must remain its correct remediation
  # (it sets verified_status without needing an agent, preserving reported_done_at
  # provenance). Without this, INVARIANT 1's custody-orphaned guard would strand
  # such a story — verify/review fail closed AND backfill wrongly refused.
  #
  # Refusal conditions, in order:
  #   - verified (nothing to do) / rejected (investigate, don't paper over)
  #   - ANY dispatch marker set — genuine dispatch lineage; use the normal
  #     report → review → verify flow. These are the "ever-dispatched" markers
  #     force_unclaim_story does NOT clear, so relying on assigned_agent_id alone
  #     is bypassable; all three are checked.
  #   - otherwise, only :pending or :reported_done (never-dispatched) are
  #     backfillable, AND only if the story has no lifecycle history (see
  #     guard_no_lifecycle_history/2); a story mid-lifecycle (:contracted
  #     with no dispatch yet) is being worked, not pre-existing done work — an
  #     ACCURATE reason, not a false "dispatch lineage" claim.
  #
  # `lookup` is `:query` on the single-story path and a precomputed MapSet on the
  # batch path.
  defp guard_backfillable(story), do: guard_backfillable(story, :query)

  defp guard_backfillable(%{verified_status: :verified}, _lookup),
    do: {:error, :already_verified}

  defp guard_backfillable(%{verified_status: :rejected}, _lookup), do: {:error, :story_rejected}

  defp guard_backfillable(%{assigned_agent_id: agent_id}, _lookup) when not is_nil(agent_id),
    do: {:error, :story_has_dispatch_lineage}

  defp guard_backfillable(%{implementer_dispatch_id: id}, _lookup) when not is_nil(id),
    do: {:error, :story_has_dispatch_lineage}

  defp guard_backfillable(%{verifier_dispatch_id: id}, _lookup) when not is_nil(id),
    do: {:error, :story_has_dispatch_lineage}

  # No dispatch markers from here down.
  defp guard_backfillable(%{agent_status: status} = story, lookup)
       when status in [:pending, :reported_done],
       do: guard_no_lifecycle_history(story, lookup)

  defp guard_backfillable(_story, _lookup), do: {:error, :story_in_progress}

  # The dispatch markers above record the story's CURRENT shape, and one of them is
  # erasable: `force_unclaim_story/3` clears `assigned_agent_id`. For a story claimed
  # with a key that no dispatch minted, `implementer_dispatch_id` is never written
  # either, so after a force-unclaim a genuinely worked story presents with all three
  # markers NULL and `agent_status: :pending` — indistinguishable, by state alone,
  # from work that predates loopctl. Backfill would then certify it with no report, no
  # review record and no independent verifier: the entire custody chain skipped by two
  # ordinary calls.
  #
  # Three sources answer "did this story ever enter the lifecycle", and the longer-lived
  # one is the story row itself. `stories.lifecycle_entered_at` is stamped by every
  # call that can clear `assigned_agent_id` on a worked story — `unclaim_story/3`,
  # `force_unclaim_story/3`, `perform_auto_reset/4` and
  # `BulkOperations.auto_reset_agent_status/1` (bulk reject) — and no lifecycle path
  # clears it, so unlike the audit log it is not on a retention timer.
  #
  # It is a COLUMN, not a `metadata` key, and that is the whole point. The marker first
  # shipped inside `metadata`, which `Story.update_changeset/2` casts and
  # `PATCH /api/v1/stories/:id` REPLACES wholesale — so a single ordinary request erased
  # it and handed the launder path straight back. `:lifecycle_entered_at` appears in no
  # `cast` list, so no request body can reach it; only `Progress` writes it, through
  # `Ecto.Changeset.change/2` on the struct. Do NOT add it to a cast list, and do not
  # "simplify" it back into `metadata`.
  #
  # The legacy `metadata` clause below is kept for stories stamped between the two
  # shapes whose metadata was replaced before the migration's backfill ran: it can only
  # make the guard refuse MORE, never less.
  #
  # The `audit_log` query is the THIRD source, and it is retention-BOUNDED, not
  # permanent: `Loopctl.Workers.AuditPartitionWorker` DROPs monthly partitions older
  # than `:audit_retention_days` (default 90). Relying on it alone reopened the launder
  # path on a timer — after the window the lifecycle rows are gone and a
  # force-unclaimed story reads as never-dispatched again. It is kept because it also
  # covers stories force-unclaimed BEFORE the marker existed, within the window — and
  # the column migration converts that window's evidence into a permanent stamp, so a
  # story evidenced at deploy time stays refused after its partitions are dropped.
  #
  # Never-dispatched work is untouched: `created`, `imported` and `merge_imported` are
  # not lifecycle actions, so a story imported with
  # `initial_agent_status: "reported_done"` remains backfillable — which is the case
  # backfill exists for. Indexed by `audit_log_tenant_entity_idx`.
  @lifecycle_audit_actions ["status_changed", "force_unclaimed", "auto_reset"]
  @lifecycle_marker "lifecycle_entered_at"

  defp guard_no_lifecycle_history(%{lifecycle_entered_at: %DateTime{}}, _lookup),
    do: {:error, :story_entered_lifecycle}

  defp guard_no_lifecycle_history(%{metadata: %{@lifecycle_marker => stamp}}, _lookup)
       when not is_nil(stamp),
       do: {:error, :story_entered_lifecycle}

  defp guard_no_lifecycle_history(%{id: id}, lookup)
       when is_binary(id) and is_struct(lookup, MapSet) do
    if MapSet.member?(lookup, id), do: {:error, :story_entered_lifecycle}, else: {:ok, :ok}
  end

  defp guard_no_lifecycle_history(%{id: id, tenant_id: tenant_id}, :query)
       when is_binary(id) and is_binary(tenant_id) do
    if MapSet.member?(stories_with_lifecycle_history(tenant_id, [id]), id) do
      {:error, :story_entered_lifecycle}
    else
      {:ok, :ok}
    end
  end

  # A story we cannot identify cannot be shown to be never-dispatched. Fail closed.
  defp guard_no_lifecycle_history(_story, _lookup), do: {:error, :story_entered_lifecycle}

  @doc """
  The subset of `ids` whose audit log shows lifecycle history — the set
  `backfill_story/4` and `ensure_mark_complete_allowed/2` refuse.

  Hoisted out of the per-story guard so the bulk mark-complete path pays ONE query
  per batch instead of one per story while holding `FOR UPDATE` locks on all of them
  and one of AdminRepo's deliberately tiny (3-connection) pool.
  """
  @spec stories_with_lifecycle_history(Ecto.UUID.t(), [Ecto.UUID.t()]) :: MapSet.t()
  def stories_with_lifecycle_history(tenant_id, ids) do
    from(a in AuditLog,
      where:
        a.tenant_id == ^tenant_id and a.entity_type == "story" and a.entity_id in ^ids and
          a.action in ^@lifecycle_audit_actions,
      select: a.entity_id,
      distinct: true
    )
    |> AdminRepo.all()
    |> MapSet.new()
  end

  # Evidence that a story already at :pending was WORKED. Row markers first, then the
  # audit log — which is what a story force-unclaimed before the column existed has,
  # and only until its partition is dropped. Converting that expiring evidence into
  # the permanent stamp is the whole point of re-running force-unclaim.
  #
  # "force_unclaimed" is deliberately absent from the actions consulted: force-unclaiming
  # a never-dispatched pending story writes one, so reading it here would let the remedy
  # permanently refuse the backfill it exists to permit. Only actions a story reaches by
  # MOVING through the lifecycle count.
  @worked_markers [
    :reported_done_at,
    :implementer_dispatch_id,
    :verifier_dispatch_id,
    :rejected_at
  ]
  @worked_audit_actions ["status_changed", "auto_reset"]

  defp retro_stamp_lifecycle(%{lifecycle_entered_at: nil} = story) do
    if worked_before?(story) do
      story
      |> Ecto.Changeset.change(%{lifecycle_entered_at: DateTime.utc_now()})
      |> AdminRepo.update()
    else
      # The remedy CANNOT close what it has no evidence of, and a 200 must not be read as
      # if it had. A story force-unclaimed with a non-dispatch-minted key before the column
      # existed keeps no evidence at all once its audit partition is dropped at
      # `:audit_retention_days`: the row markers were cleared, "force_unclaimed" is not read
      # here (see above), and the lifecycle rows are gone. That story stays backfillable,
      # and the operator learns it here rather than from a silent no-op.
      Logger.warning(
        "lifecycle_retro_stamp_skipped: nothing showed this story was ever worked, so it " <>
          "remains backfillable. If it WAS worked, its lifecycle audit rows have expired — " <>
          "reject it (verified_status: :rejected) instead. story_id=#{story.id}"
      )

      {:ok, story}
    end
  end

  defp retro_stamp_lifecycle(story), do: {:ok, story}

  defp worked_before?(story) do
    Enum.any?(@worked_markers, &(not is_nil(Map.get(story, &1)))) or
      AdminRepo.exists?(
        from(a in AuditLog,
          where:
            a.tenant_id == ^story.tenant_id and a.entity_type == "story" and
              a.entity_id == ^story.id and a.action in ^@worked_audit_actions
        )
      )
  end

  @doc """
  Proof that a story entered the dispatch lifecycle, stamped where the erasure
  happens. Idempotent in the sense that matters: the FIRST entry is the one worth
  keeping, so a story that already carries the marker is not re-stamped.

  Public because `Loopctl.BulkOperations` clears `assigned_agent_id` too
  (bulk reject's auto-reset) and must leave the identical durable proof.
  """
  @spec lifecycle_stamp(Story.t() | map()) :: DateTime.t()
  def lifecycle_stamp(%{lifecycle_entered_at: %DateTime{} = existing}), do: existing
  def lifecycle_stamp(_story), do: DateTime.utc_now()

  @doc """
  The marker change for a reject auto-reset — EMPTY when there was no dispatch marker to
  erase.

  The stamp records that markers existed and were cleared. A story imported with
  `initial_agent_status: "reported_done"` carries none, so rejecting it erases nothing,
  and the marker is permanent and uncleanable: stamping it would refuse that story the
  backfill it is entitled to for good, the moment a rejection is reversed. Same evidence
  `retro_stamp_lifecycle/1` reads, on the PRE-reset struct.
  """
  @spec lifecycle_stamp_change(Story.t() | map()) :: map()
  def lifecycle_stamp_change(%{assigned_agent_id: nil, implementer_dispatch_id: nil}), do: %{}
  def lifecycle_stamp_change(story), do: %{lifecycle_entered_at: lifecycle_stamp(story)}

  defp apply_backfill_status(story, reason, evidence_url, pr_number) do
    now = DateTime.utc_now()

    backfill_meta = %{
      "reason" => reason,
      "evidence_url" => evidence_url,
      "pr_number" => pr_number,
      "backfilled_at" => DateTime.to_iso8601(now)
    }

    new_metadata = Map.put(story.metadata || %{}, "backfill", backfill_meta)

    story
    |> Ecto.Changeset.change(%{
      agent_status: :reported_done,
      verified_status: :verified,
      reported_done_at: story.reported_done_at || now,
      verified_at: now,
      metadata: new_metadata
    })
    |> AdminRepo.update()
  end

  defp normalize_string(nil), do: nil
  defp normalize_string(""), do: nil

  defp normalize_string(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  @doc """
  Rejects a story: orchestrator marks it as failing verification.

  Sets verified_status to `rejected` and creates a verification_result
  record with result=fail. Uses pessimistic locking. Can be called on
  reported_done or verified stories (allowing re-rejection).

  Requires a non-empty reason.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `params` -- map with `reason` (required), optional `findings`, `review_type`
  - `opts` -- keyword list with `:orchestrator_agent_id`, `:actor_id`, `:actor_label`,
    and `:verifier_lineage` (the CALLER's dispatch lineage, resolved server-side)

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if story is not reported_done or verified
  - `{:error, :reason_required}` if reason is missing or blank
  """
  @spec reject_story(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Story.t()} | {:error, atom() | {:invalid_transition, map()}}
  def reject_story(tenant_id, story_id, params, opts \\ []) do
    orchestrator_agent_id = Keyword.get(opts, :orchestrator_agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    reason = Map.get(params, "reason") || Map.get(params, :reason)
    rejection_params = extract_rejection_params(params)

    with :ok <- validate_reason(reason) do
      multi =
        Multi.new()
        |> Multi.run(:lock, fn _repo, _changes -> lock_story(tenant_id, story_id) end)
        |> Multi.run(:self_verify_check, fn _repo, %{lock: story} ->
          # Reject reaches the TERMINAL `verified_status: :rejected` and auto-resets
          # the agent status, so it takes the same caller-lineage comparison verify
          # does — minus the unlineaged refusal, which would strand bad work with no
          # way back (see unlineaged_caller/3).
          validate_not_self_verify(
            story,
            orchestrator_agent_id,
            Keyword.get(opts, :verifier_lineage, []),
            :reject
          )
        end)
        |> Multi.run(:validate, fn _repo, %{lock: story} ->
          validate_rejectable(story)
        end)
        |> Multi.run(:story, fn _repo, %{lock: story} ->
          apply_rejected_status(story, reason)
        end)
        |> insert_verification_result(tenant_id, orchestrator_agent_id, :fail, rejection_params)
        |> audit_verification(tenant_id, "rejected", actor_id, actor_label, orchestrator_agent_id)
        |> EventGenerator.generate_events(:webhook_events_rejected, fn %{story: updated} ->
          %{
            tenant_id: tenant_id,
            event_type: "story.rejected",
            project_id: updated.project_id,
            payload: %{
              "event" => "story.rejected",
              "story_id" => updated.id,
              "project_id" => updated.project_id,
              "epic_id" => updated.epic_id,
              "orchestrator_agent_id" => orchestrator_agent_id,
              "reason" => reason,
              "findings" => rejection_params.findings,
              "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
            }
          }
        end)
        |> maybe_auto_reset(
          tenant_id,
          orchestrator_agent_id,
          Keyword.get(opts, :verifier_lineage, [])
        )

      unwrap_verification_transaction(multi)
    end
  end

  @doc """
  Verifies all reported_done stories in an epic in a single operation.

  Finds all stories in the epic with agent_status=reported_done and
  verified_status=unverified, then verifies each one using the same
  logic as `verify_story/4`. Requires orchestrator role.

  Stories that fail verification (e.g., self-verify block) are skipped
  and reported in the errors list.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `epic_id` -- the epic UUID
  - `params` -- map with `summary` and `review_type` (same as single verify)
  - `opts` -- keyword list with `:orchestrator_agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %{verified_count: integer, skipped_count: integer, errors: [map()]}}` on success
  """
  @spec verify_all_in_epic(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()}
  def verify_all_in_epic(tenant_id, epic_id, params, opts \\ []) do
    stories_to_verify = fetch_eligible_stories_for_verify(tenant_id, epic_id)
    results = Enum.map(stories_to_verify, &verify_single(tenant_id, &1, params, opts))

    verified = Enum.count(results, &match?({:ok, _}, &1))
    errors = results |> Enum.filter(&match?({:error, _}, &1)) |> Enum.map(&elem(&1, 1))

    {:ok,
     %{
       verified_count: verified,
       skipped_count: length(errors),
       total_eligible: length(stories_to_verify),
       errors: errors
     }}
  end

  defp fetch_eligible_stories_for_verify(tenant_id, epic_id) do
    Story
    |> where(
      [s],
      s.tenant_id == ^tenant_id and
        s.epic_id == ^epic_id and
        s.agent_status == :reported_done and
        s.verified_status == :unverified
    )
    |> AdminRepo.all()
  end

  defp verify_single(tenant_id, story, params, opts) do
    case verify_story(tenant_id, story.id, params, opts) do
      {:ok, _updated} -> {:ok, story.id}
      {:error, reason} -> {:error, %{story_id: story.id, reason: inspect(reason)}}
    end
  end

  @doc """
  Lists verification results for a story.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID

  ## Returns

  - `{:ok, [%VerificationResult{}]}` on success
  """
  @spec list_verifications(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [VerificationResult.t()]}
  def list_verifications(tenant_id, story_id) do
    results =
      VerificationResult
      |> where([v], v.tenant_id == ^tenant_id and v.story_id == ^story_id)
      |> order_by([v], desc: v.inserted_at)
      |> AdminRepo.all()

    {:ok, results}
  end

  @doc """
  Checks if all stories in an epic are verified.

  Returns false for empty epics (zero stories).
  """
  @spec all_stories_verified?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def all_stories_verified?(tenant_id, epic_id) do
    total = count_stories_in_epic(tenant_id, epic_id)
    unverified = count_unverified_in_epic(tenant_id, epic_id)
    total > 0 and unverified == 0
  end

  # --- Orchestrator Force-Unclaim (US-7.5) ---

  @doc """
  Force-unclaims a story: orchestrator resets it to pending.

  Resets agent_status to `pending`, clears assigned_agent_id and
  assigned_at. Does NOT reset verified_status. Idempotent on
  already-pending stories. Works from any agent_status.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:orchestrator_agent_id`, `:actor_id`, `:actor_label`,
    `:actor_lineage`, `:release_cause`

  `:release_cause` is WHY the claim is being taken back, and it decides where a DELIVERY story
  goes next (US-44.4, #877) — a story whose stage row the release leaves at `queued`:

  - `:operator` (the default) — a human took the story back, so a human decides what it does
    next: the row is escalated over `{queued, escalated, :operator_released}` and the story is
    left `:pending`, resolved from `escalated` like any other. It spends no attempt. Every
    operator-facing caller (`POST /stories/:id/force-unclaim`, `Loopctl.Delivery.Escalations`)
    takes the default.
  - `:placement_refused` — `Loopctl.Delivery.Placement.undo_claim/5` giving back a claim its
    placement could not push because the RUNNER was not available for it (gone, busy, at
    capacity). The runner refused before any work and the next pass may find it free, so it
    spends no attempt and the story is re-contracted for the driver to place again.
  - `:attempt` — the same undo for a refusal that will recur on every pass (a payload the
    contract rejects, a story that could not be attached): it COUNTS toward the retry ceiling,
    so the story is re-contracted below it and escalated at it rather than placed, refused and
    released for ever.

  A story with no delivery stage row, or one whose row is anywhere but `queued` after the
  release, is released exactly as before either way.

  `:actor_lineage` is LOAD-BEARING and defaults to `[]`. Since #862 this function revokes the
  released session's dispatch credential, and that revocation appends a `dispatch_revoked`
  entry to the immutable, hash-chained audit log naming this lineage as its actor — so an
  omitted `:actor_lineage` does not merely lose attribution, it writes `[]`, which is the
  shape the tenant's own operator key writes. Pass the caller's SERVER-RESOLVED lineage
  (`Dispatches.lineage_for_api_key/2`); pass an explicit `[]` only when the caller genuinely
  has none. Two of the three call sites silently took the default (#862 review round 2,
  finding 3), which is why it is documented here rather than left to the reader of
  `revoke_released_session_credential/3`.

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, %Ecto.Changeset{}}` if the release write itself is refused
  - `{:error, :audit_chain_append_failed}` if the release's escalation could not append its
    chain entry (`:stage`) — the whole release rolled back
  - `{:error, :force_unclaim_failed}` if `:stage` refuses for any other reason, or
    `:recontract`, `:audit` or `:webhook_events` refuses — see the result `case` below for why
    none can today

  The changeset shape is why this spec is not the `{:error, atom()}` it used to claim: the
  `:story` clause has handed back a changeset since this function was written, so the spec
  and the code disagreed. This is an OPERATOR'S REMEDY for a parked story — the one call
  that unsticks a claim nothing else will release — so every refusal it can produce has to
  be a value the caller can report, and a `@spec` it does not honour is the first step
  towards a caller that believes it.
  """
  @spec force_unclaim_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Story.t()} | {:error, atom() | Ecto.Changeset.t()}
  def force_unclaim_story(tenant_id, story_id, opts \\ []) do
    release_cause = Keyword.get(opts, :release_cause, :operator)

    unless release_cause in [:operator, :placement_refused, :attempt] do
      raise ArgumentError,
            "force_unclaim_story/3: :release_cause is :operator, :placement_refused or " <>
              ":attempt, not #{inspect(release_cause)}"
    end

    multi = force_unclaim_multi(tenant_id, story_id, opts)

    # ONE CLAUSE PER MULTI STEP, and deliberately NO catch-all. This once matched three of the
    # Multi's steps, so a refusal at `:stage`, `:audit` or `:webhook_events` was
    # a `CaseClauseError` — an exception out of the one call an operator makes to unstick a
    # parked story, and one that contradicted this function's own `@spec` (846.8, AC-5).
    #
    # A catch-all would have been the wrong repair and is what this house style refuses (see
    # `LoopctlWeb.DispatchController.revoke_ceiling/3`): it hides the SIXTH step somebody adds
    # later, which is exactly how the defect arrived. `test/loopctl/progress/
    # force_unclaim_result_coverage_test.exs` fails when a step name appears in the Multi and
    # not here, so adding a step without deciding what its failure means is caught at the gate
    # rather than in production. It reads the STEPS off the `%Ecto.Multi{}`
    # `force_unclaim_multi/3` returns and the CLAUSES off this `case`'s AST — neither is a
    # text scan, which is what it used to be and what kept having blind spots; the guard's own
    # moduledoc states the two things it still cannot see, and both of those fail loud.
    #
    # ## What each of those steps can and cannot see
    #
    #   * `:stage` — `Stages.follow_release/5` returns `{:error, :audit_chain_append_failed}`
    #     when the escalation a release decides (`:operator_released`, `:attempts_exhausted`)
    #     could not append its chain entry (US-44.4): the release rolls back and the story is
    #     still claimed, and the caller is told exactly that. Its other failures are `true = `
    #     and `{1, [updated]} = ` MATCHES and unguarded `AdminRepo` statements, so they raise
    #     and abort the transaction instead.
    #   * `:recontract` — `Progress.recontract_in_transaction/3` returns only `{:ok, story}`;
    #     its audit insert is an `insert!`, so a refusal raises.
    #   * `:audit` — `Audit.log_in_multi/3` inserts an `AuditLog.create_changeset/1` whose four
    #     required fields (`entity_type`, `entity_id`, `action`, `actor_type`) are all set here
    #     from literals or from `updated.id`, so the changeset is valid by construction. There
    #     is no `unique_constraint` on that changeset either, so a database refusal raises.
    #   * `:webhook_events` — `EventGenerator.generate_events/3` ends `{:ok, events}` on every
    #     path and hard-matches `{:ok, _}` on the inserts underneath, so it too raises instead.
    #
    # So what reaches a caller from those steps, beyond `:stage`'s one named reason, is an
    # EXCEPTION, which
    # `Placement.release_claim/5` rescues by design; those clauses exist for the step that is
    # added next. The log line is what tells an operator which step it was — the returned atom
    # names none of them, because `:webhook_events` is not a fact about the story.
    case AdminRepo.transaction(multi) do
      {:ok, %{recontract: story, stage: released}} ->
        Stages.announce_release(released)
        revoke_released_session_credential(tenant_id, story, opts)
        {:ok, story}

      {:error, :lock, reason, _} ->
        {:error, reason}

      {:error, :story, changeset, _} ->
        {:error, changeset}

      # ANY reason, for every one of these steps: a clause pinning one reason covers that reason
      # and leaves the step's next one a `CaseClauseError`, which is why the coverage guard
      # counts only an any-reason clause. The escalation's chain entry being refused (logged by
      # `Stages`) is answered as itself, like every other release path; the release rolled back
      # and the story is still claimed.
      {:error, step, reason, _} when step in [:stage, :recontract, :audit, :webhook_events] ->
        force_unclaim_refused(tenant_id, story_id, step, reason)
    end
  end

  defp force_unclaim_refused(_tenant_id, _story_id, :stage, :audit_chain_append_failed),
    do: {:error, :audit_chain_append_failed}

  defp force_unclaim_refused(tenant_id, story_id, step, reason) do
    Logger.error(
      "force_unclaim rolled back at a step that is not supposed to be able to refuse. " <>
        "The story is UNCHANGED — still claimed, still held — and the remedy has to be " <>
        "re-run. tenant_id=#{tenant_id} story_id=#{story_id} step=#{inspect(step)} " <>
        "reason=#{inspect(reason)}",
      tenant_id: tenant_id,
      story_id: story_id
    )

    {:error, :force_unclaim_failed}
  end

  @doc """
  The `Ecto.Multi` `force_unclaim_story/3` runs. Builds nothing in the database and executes
  no query; every step is a closure the transaction runs later.

  PUBLIC SO THE STEPS CAN BE READ WITHOUT RUNNING THEM (846.8 review round 2), which is the
  one thing that makes the drift guard in
  `test/loopctl/progress/force_unclaim_result_coverage_test.exs` unable to MISS a step. That
  guard exists because a step was once added here and the result `case` was not revisited;
  it used to find the steps by scanning this file's text with a regex, and three review
  rounds found three different spellings that scan could not see — a formatter-broken pipe,
  an atom carrying a digit, and a step added anywhere other than a literal pipe in this
  function. Every one of them failed SILENTLY GREEN, in the direction the guard exists to
  prevent. `Ecto.Multi.to_list/1` on the value this returns is not a reading of the source,
  it is the operation list itself, so that class of hole is gone rather than narrowed.

  Same seam, and same justification, as `Loopctl.Delivery.Placement.escalate_unreleased_claim/6`
  and `Loopctl.Delivery.StoryPayload.settle_if_parked/3`: published for a test that cannot
  otherwise reach the state, with one production caller. Nothing else should call it —
  running this Multi outside `force_unclaim_story/3` skips the credential revoke that
  follows the commit.
  """
  @spec force_unclaim_multi(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: Multi.t()
  def force_unclaim_multi(tenant_id, story_id, opts \\ []) do
    orchestrator_agent_id = Keyword.get(opts, :orchestrator_agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    Multi.new()
    |> Multi.run(:lock, fn _repo, _changes ->
      lock_story(tenant_id, story_id)
    end)
    |> Multi.run(:story, fn _repo, %{lock: story} ->
      # Idempotent on STATE, not on the marker. A worked story can already sit at
      # :pending with no stamp (reset before the column existed), and re-running
      # force-unclaim is the operator's remedy for exactly that — returning the
      # struct untouched made the remedy a no-op.
      if story.agent_status == :pending do
        retro_stamp_lifecycle(story)
      else
        story
        |> Ecto.Changeset.change(release_claim_changes(story))
        |> AdminRepo.update()
      end
    end)
    # #803: the stage row follows the release in this transaction. On the idempotent
    # :pending branch the epoch did not move, and this rebinds a row a release left behind
    # before follow_release/5 existed — the same operator remedy as the retro-stamp above.
    |> Multi.run(:stage, fn _repo, %{story: updated} ->
      Stages.follow_release(tenant_id, updated.id, updated.claim_epoch, :claim_released,
        cause: Keyword.get(opts, :release_cause, :operator),
        actor_lineage: Keyword.get(opts, :actor_lineage, []),
        actor_label: actor_label
      )
    end)
    |> Audit.log_in_multi(:audit, fn %{story: updated, lock: old} ->
      %{
        tenant_id: tenant_id,
        entity_type: "story",
        entity_id: updated.id,
        action: "force_unclaimed",
        actor_type: "api_key",
        actor_id: actor_id,
        actor_label: actor_label,
        old_state: %{
          "agent_status" => to_string(old.agent_status),
          "assigned_agent_id" => old.assigned_agent_id
        },
        new_state: %{
          "agent_status" => "pending",
          "orchestrator_agent_id" => orchestrator_agent_id
        }
      }
    end)
    |> EventGenerator.generate_events(:webhook_events, fn %{story: updated, lock: old} ->
      %{
        tenant_id: tenant_id,
        event_type: "story.force_unclaimed",
        project_id: updated.project_id,
        payload: %{
          "event" => "story.force_unclaimed",
          "story_id" => updated.id,
          "project_id" => updated.project_id,
          "epic_id" => updated.epic_id,
          "old_status" => to_string(old.agent_status),
          "new_status" => "pending",
          "orchestrator_agent_id" => orchestrator_agent_id,
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
        }
      }
    end)
    # AFTER the release's own audit and webhook (see `Stages.recontract_released/4`). Only a
    # placement undo leaves the row at `queued`; an operator's release escalates it.
    |> Multi.run(:recontract, fn _repo, %{story: updated, stage: released} ->
      Stages.recontract_released(tenant_id, released, updated, actor_label)
    end)
  end

  # Taking a story back kills the credential the previous holder had. AFTER the commit,
  # deliberately, on three counts: the release is what the caller asked for and must not be
  # rolled back by a revoke failure; `Dispatches.revoke/3` runs its own AdminRepo transaction
  # and busts the api-key cache when it returns, so running it inside this one would bust the
  # cache BEFORE the release commits; and a revoke is idempotent, so re-running force-unclaim
  # is still the operator's remedy.
  #
  # It runs on the IDEMPOTENT `:pending` branch too. That is not an oversight: a story already
  # back at `pending` whose session key was never revoked is exactly the state this exists to
  # clear, and re-running force-unclaim is the documented remedy for the residue of a failed
  # compensation (`Placement.undo_claim/5`).
  #
  # `revoke_story_session/4` revokes ONLY a dispatch minted FOR this story, so a general agent
  # dispatch that merely claimed it keeps its key — see that function for why the cascade makes
  # the wide case unacceptable. It does NOT clear `implementer_dispatch_id`: that is custody
  # provenance, `get_dispatch_lineage/2` reads a revoked row exactly as it reads a live one, and
  # every L4 comparison is therefore unchanged by this.
  #
  # NOT CLEARING IT HAS A COST, and it is stated here rather than left for a reader to
  # discover: when this call is the remedy for a placement whose compensation could not revoke
  # (`Delivery.Placement.undo_claim/5`), the credential dies but the story goes on naming the
  # dispatch that never ran — so the next claimant is still refused on report if it holds a key
  # no dispatch minted (`caller_lineage_required`) or one sharing that dispatch's chain
  # (`self_report_blocked`), until a claim THROUGH A DISPATCH overwrites the column.
  #
  # Clearing it here would be worse, and the asymmetry is why this is not a TODO. Force-unclaim
  # is the operator's release for ANY claimed story; from inside it, a story whose dispatch did
  # nothing and one whose dispatch genuinely implemented it are the same shape. Clearing would
  # therefore drop real provenance and reduce a dispatch-minted story to the pre-dispatch shape,
  # where `lineage_status/2` returns `:ok` on the nil and the gates fall back to
  # `assigned_agent_id` equality alone — letting a key in the implementer's own chain, on a
  # different agent, report the work that chain did. `force_unclaim` is `exact_role:
  # :orchestrator`, which is precisely the role that could arrange it. A narrower rule was
  # looked for and none holds: `lifecycle_entered_at` is stamped by BOTH cases, and a second
  # force-unclaim of an already-`pending` worked story is indistinguishable from the residue.
  #
  # AND IT SWALLOWS A RAISE, not only an `{:error, _}`. `Dispatches.revoke/3` returns tuples
  # from its own Multi, but the statements under it are ordinary AdminRepo calls on a
  # 3-connection pool with no `lock_timeout`, so a DBConnection error is a RAISE. Unrescued,
  # that turns a release that ALREADY COMMITTED into a 500: the caller is told the story was
  # not freed when it was, and re-runs a compensation that had already succeeded. The caller is
  # owed the outcome of the release it asked for, not the outcome of the cleanup that followed
  # it. Same reasoning, and the same shape, as `Placement.release_claim/4`.
  defp revoke_released_session_credential(tenant_id, story, opts) do
    actor_lineage = Keyword.get(opts, :actor_lineage, [])

    case Dispatches.revoke_story_session(
           tenant_id,
           story.id,
           story.implementer_dispatch_id,
           actor_lineage: actor_lineage
         ) do
      {:ok, count} when is_integer(count) ->
        :ok

      # NOTHING TO REVOKE, and nothing stranded by it: the story names no implementer
      # dispatch, so there is no credential holding an `api_keys_one_role_per_agent_idx`
      # slot. Every force-unclaim of a story that was never dispatch-claimed lands here,
      # which is why it is the one outcome that stays at `:debug`.
      {:ok, :no_dispatch} ->
        Logger.debug(
          "force_unclaim had no session credential to revoke: tenant_id=#{tenant_id} " <>
            "story_id=#{story.id}"
        )

        :ok

      # THE TWO CASES WHERE FORCE-UNCLAIM DOES NOT FREE THE SLOT — the whole point of the
      # change — so they are the ones an operator must be able to read. They were at
      # `:debug` while `config/dev.exs` and `config/prod.exs` both set `level: :info`,
      # i.e. invisible in every environment that runs: the operator saw the story freed,
      # then hit the same 422 on the next placement with nothing in the log saying why.
      # `dispatches.ex` calls these "left alone and REPORTED, never silently skipped";
      # `:warning` is what makes that sentence true.
      {:ok, skipped} ->
        Logger.warning(
          "force_unclaim did NOT revoke this story's session credential, so the agent's " <>
            "one-key-per-role slot may still be occupied and the next dispatch mint for it " <>
            "can be refused 422 'agent already has an active key with this role'. " <>
            "#{skip_explanation(skipped)} tenant_id=#{tenant_id} story_id=#{story.id} " <>
            "implementer_dispatch_id=#{inspect(story.implementer_dispatch_id)}",
          tenant_id: tenant_id,
          story_id: story.id
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "force_unclaim could not revoke the released session's key. It stays usable until " <>
            "its TTL, and it OCCUPIES this agent's one-key-per-role slot until then, so every " <>
            "later dispatch mint for the agent is refused 422 'agent already has an active " <>
            "key with this role'. Revoke it directly: POST /api/v1/dispatches/:id/revoke " <>
            "(MCP revoke_dispatch). tenant_id=#{tenant_id} story_id=#{story.id} " <>
            "implementer_dispatch_id=#{inspect(story.implementer_dispatch_id)} " <>
            "revoke_error=#{inspect(reason)}",
          tenant_id: tenant_id,
          story_id: story.id
        )

        :ok
    end
  rescue
    error ->
      Logger.error(
        "force_unclaim RAISED while revoking the released session's key; the release itself " <>
          "COMMITTED and the story is free. The key stays usable until its TTL and occupies " <>
          "this agent's one-key-per-role slot until then, so later dispatch mints for the " <>
          "agent are refused 422. Revoke it directly: POST /api/v1/dispatches/:id/revoke " <>
          "(MCP revoke_dispatch). tenant_id=#{tenant_id} story_id=#{story.id} " <>
          "implementer_dispatch_id=#{inspect(story.implementer_dispatch_id)} " <>
          "error=#{inspect(error)}",
        tenant_id: tenant_id,
        story_id: story.id
      )

      :ok
  end

  # Each skip has a DIFFERENT remedy, so the line names which one it is rather than
  # printing a bare atom the operator has to go and look up.
  #
  # TOTAL over what reaches it, and deliberately with NO catch-all: the `{:ok, skipped}`
  # branch above sees exactly the two atoms below, since `revoke_story_session/4` returns
  # an integer or one of three atoms and `:no_dispatch` has its own clause. Dialyzer
  # proved a catch-all unreachable (`pattern_match_cov`), and an unreachable clause that
  # reads as a guard is worse than none — if a fourth outcome is ever added, the crash is
  # what says so.
  defp skip_explanation(:not_story_session),
    do:
      "reason=not_story_session: the dispatch this story names was not minted FOR it " <>
        "(`story_id` differs), and revoking it would cascade to that agent's whole subtree, " <>
        "so it is deliberately left alone. Revoke it yourself if it really is stranded: " <>
        "POST /api/v1/dispatches/:id/revoke (MCP revoke_dispatch)."

  defp skip_explanation(:dispatch_not_found),
    do:
      "reason=dispatch_not_found: the story names a dispatch row that no longer resolves in " <>
        "this tenant, so nothing was revoked. Its api_key, if any, is unreachable from here " <>
        "and will be swept at its TTL by RevokeExpiredApiKeysWorker."

  # --- Verification/Rejection helpers ---

  # NO default for `caller_lineage` HERE. A defaulted [] made "this path resolved the
  # caller's lineage and it is empty" indistinguishable from "this path forgot to
  # resolve it", and lineage_status/2 used to treat [] as :ok — so every forgetful call
  # site (verify-all, bulk verify/reject, reject) silently skipped the whole L4 caller
  # comparison. The public `verify_story/4` / `reject_story/4` opts boundary still
  # DEFAULTS `:verifier_lineage` to [] (every current call site passes it), so the
  # guarantee is not "omission is a compile error" — it is that [] no longer DEGRADES:
  # on dispatch-minted work it is now `:unlineaged`, which verify refuses.
  #
  # nil orchestrator identity: untrusted (US-26.1.3)
  defp validate_not_self_verify(_story, nil, _caller_lineage, _gate),
    do: {:error, :self_verify_blocked}

  defp validate_not_self_verify(story, orchestrator_agent_id, caller_lineage, gate) do
    # INVARIANT 1 (fail closed / §2.2 "nil is never permissive"): a story that
    # is reported_done but not yet verified, with NO assigned agent and NO
    # dispatch lineage, has no implementer to compare the verifier against — the
    # checks below would pass VACUOUSLY (a non-nil verifier is never == a nil
    # implementer). Reject rather than allow a custody-orphaned verify. (The DB
    # CHECK stories_reported_done_requires_agent only covers the DISPATCHED
    # case — its `implementer_dispatch_id IS NULL` disjunct leaves exactly this
    # shape legal — so this predicate is the ONLY guard for a never-dispatched
    # agentless story, not mere defense in depth. Backfilled stories are
    # already verified and never reach here.)
    if custody_orphaned?(story) do
      log_custody_orphaned(story, orchestrator_agent_id, "verify")
      {:error, :missing_assigned_agent}
    else
      verify_caller_separation(story, orchestrator_agent_id, caller_lineage, gate)
    end
  end

  @doc """
  Whether a story's RECORDED custody permits an unattended merge (issue #803, design §9).

  The design's rule is one sentence: *merge requires `verified_status = :verified` set by a
  verifier dispatch with a different lineage.* This is that sentence, and it is deliberately
  NOT a second lineage comparison — the separation half delegates to
  `verify_recorded_separation/2`, the same L4 clause `verify` itself runs, so a change to
  what "separate lineage" means moves both at once.

  It differs from the verify gate in what it does with MISSING provenance, and only there.
  `verify` may legitimately reach a story with no verifier dispatch, because `request-review`
  is optional, and its caller-side lineage clause is what gates that path. A MERGE has no
  caller to compare: it asks about a decision already recorded, so a story with no
  implementer dispatch or no verifier dispatch has nothing to show separation WITH, and both
  are refused rather than falling through to `verify_recorded_separation/2`'s `{:ok, story}`.
  That fall-through is correct where a live caller is being judged and vacuous here.

  `nil` is passed for the caller's agent id for the same reason: there is no caller. The
  `assigned_agent_id` equality clauses inside the comparison are inert against `nil`, which
  is what leaves the lineage comparison as the whole of the test.

  Returns `:ok`, or `{:error, code}` where `code` is one of `:not_verified`,
  `:missing_implementer_dispatch`, `:missing_verifier_dispatch`,
  `:unresolvable_dispatch_lineage` (an unloadable dispatch row on either side, fail closed)
  or `:self_verify_blocked` (the recorded verifier shares the implementer's lineage ROOT).
  """
  @spec merge_custody_status(Story.t()) :: :ok | {:error, atom()}
  def merge_custody_status(%Story{} = story) do
    cond do
      story.verified_status != :verified ->
        {:error, :not_verified}

      is_nil(story.implementer_dispatch_id) ->
        {:error, :missing_implementer_dispatch}

      is_nil(story.verifier_dispatch_id) ->
        {:error, :missing_verifier_dispatch}

      true ->
        case verify_recorded_separation(story, nil) do
          {:ok, %Story{}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # CALLER separation (LCP-1 §7.5) — the same comparison report and review-complete
  # run, and the ONLY clause here that says anything about the principal actually
  # making this call: the verifier's lineage is resolved SERVER-SIDE from the
  # authenticating key, so an ancestor or a sub-agent in the implementer's chain is
  # blocked even when its agent_id differs. The story-side clauses compare RECORDED
  # dispatches, which are silent about the caller — and `verifier_dispatch_id` is only
  # written by the OPTIONAL request-review, so without this the common path degraded
  # to a single agent-id inequality.
  #
  # The CALLER comparison is `lineage_same_chain?/2`, the SAME distance report and
  # review-complete demand — an ancestor or a descendant of the implementer is blocked,
  # a SIBLING is not. Demanding a separate ROOT here made verify unreachable in the
  # documented single-root tenant (operator root -> orchestrator -> implementer): every
  # dispatch-minted key shares the one root, so no principal could certify anything,
  # while report and review-complete were relaxed to `:chain` for that exact reason.
  # The stricter ROOT separation is still enforced where it can be satisfied by
  # construction — `select_verifier/3` will not NOMINATE a same-root verifier, and
  # `verify_recorded_separation/2` compares the RECORDED verifier at root distance.
  defp verify_caller_separation(story, orchestrator_agent_id, caller_lineage, gate) do
    case lineage_status(story, caller_lineage) do
      :unresolvable -> {:error, :unresolvable_dispatch_lineage}
      :conflict -> {:error, :self_verify_blocked}
      :unlineaged -> unlineaged_caller(story, orchestrator_agent_id, gate)
      :ok -> verify_recorded_separation(story, orchestrator_agent_id)
    end
  end

  # An EMPTY caller lineage is a key no dispatch minted (a legacy env-var key, OQ2
  # deprecation window). On dispatch-minted work it cannot be SHOWN separate from the
  # implementer, leaving verify nothing but `assigned_agent_id` inequality — which two
  # env-var keys with distinct agent_ids in one process satisfy trivially. So verify
  # refuses it, under its OWN code: `:caller_lineage_required` is an ordinary
  # configuration refusal (409, no violation recorded), NOT `self_verify_blocked`,
  # which is an L6 byzantine signal that escalates to a tenant-wide custody halt.
  #
  # REJECT is exempt. Sending work back is the remediation path, not a certification —
  # refusing it strands a bad story at reported_done with no way out — and the recorded
  # and agent-id comparisons below still apply.
  defp unlineaged_caller(story, orchestrator_agent_id, :reject),
    do: verify_recorded_separation(story, orchestrator_agent_id)

  defp unlineaged_caller(_story, _orchestrator_agent_id, :verify),
    do: {:error, :caller_lineage_required}

  # The STORY-side half of the gate: loopctl's SELECTED verifier against the
  # implementer when request-review recorded one, else agent-id equality.
  defp verify_recorded_separation(story, orchestrator_agent_id) do
    cond do
      # Lineage-based check (preferred): compare dispatch lineage paths
      not is_nil(story.implementer_dispatch_id) and not is_nil(story.verifier_dispatch_id) ->
        impl = get_dispatch_lineage(story.tenant_id, story.implementer_dispatch_id)
        verifier = get_dispatch_lineage(story.tenant_id, story.verifier_dispatch_id)

        verify_lineage_separated(story, orchestrator_agent_id, impl, verifier)

      # Fallback: agent_id comparison for pre-dispatch stories
      not is_nil(story.assigned_agent_id) and story.assigned_agent_id == orchestrator_agent_id ->
        {:error, :self_verify_blocked}

      true ->
        {:ok, story}
    end
  end

  # The lineage clause of validate_not_self_verify/3, kept fail-CLOSED.
  #
  # `get_dispatch_lineage/2` maps an unloadable dispatch row to `[]`, and
  # `lineage_shares_prefix?([], _)` is false — so a naive "no shared prefix ⇒
  # ok" would read a dispatch that cannot be resolved as "independent lineage"
  # AND would short-circuit the agent-id fallback. Both halves are closed here:
  # an empty lineage on either side blocks, and the agent-id equality check is
  # evaluated IN ADDITION to (never instead of) the lineage comparison.
  defp verify_lineage_separated(story, orchestrator_agent_id, impl, verifier) do
    cond do
      impl == [] or verifier == [] ->
        Logger.warning(
          "unresolvable_dispatch_lineage: verify blocked — dispatch lineage could not be " <>
            "resolved (fail closed) story_id=#{story.id} tenant_id=#{story.tenant_id} " <>
            "caller_agent_id=#{inspect(orchestrator_agent_id)}"
        )

        {:error, :unresolvable_dispatch_lineage}

      Dispatches.lineage_shares_prefix?(impl, verifier) ->
        {:error, :self_verify_blocked}

      not is_nil(story.assigned_agent_id) and story.assigned_agent_id == orchestrator_agent_id ->
        {:error, :self_verify_blocked}

      true ->
        {:ok, story}
    end
  end

  defp get_dispatch_lineage(tenant_id, dispatch_id) do
    case Dispatches.get_dispatch(tenant_id, dispatch_id) do
      {:ok, dispatch} -> dispatch.lineage_path
      {:error, _} -> []
    end
  end

  # INVARIANT 1: a story is "custody orphaned" when it is reported_done and still
  # unverified but carries no provenance for who did the work — no assigned agent
  # and no implementer dispatch lineage. Such a story cannot be legitimately
  # verified or reviewed (there is no implementer to separate the verifier/reviewer
  # from), so the self-* guards fail closed on it. The DB CHECK
  # stories_reported_done_requires_agent does NOT make this state unreachable: it
  # is satisfied whenever `implementer_dispatch_id IS NULL`, which is precisely
  # the custody-orphaned shape. This predicate is the only enforcement for a
  # never-dispatched agentless story.
  defp custody_orphaned?(%Story{
         agent_status: :reported_done,
         verified_status: :unverified,
         assigned_agent_id: nil,
         implementer_dispatch_id: nil
       }),
       do: true

  defp custody_orphaned?(_story), do: false

  # Observability for INVARIANT 1: emit a warning (no tenant halt, unlike the
  # byzantine self_verify path) whenever the custody-orphaned guard fires, so
  # operators can distinguish a broken import batch (recoverable via
  # backfill/mark-complete) from a probing attempt. Includes story + tenant +
  # calling identity.
  defp log_custody_orphaned(%Story{} = story, caller_agent_id, operation) do
    Logger.warning(
      "custody_orphaned_blocked: #{operation} blocked — reported_done story has no " <>
        "assigned agent or dispatch lineage (custody chain broken) " <>
        "story_id=#{story.id} tenant_id=#{story.tenant_id} " <>
        "caller_agent_id=#{inspect(caller_agent_id)}"
    )
  end

  defp validate_verifiable(story) do
    cond do
      story.agent_status != :reported_done ->
        {:error,
         {:invalid_transition,
          %{
            current_agent_status: story.agent_status,
            current_verified_status: story.verified_status,
            attempted_action: "verify",
            hint: "Story must be in 'reported_done' agent_status before it can be verified"
          }}}

      story.verified_status == :verified ->
        {:error,
         {:invalid_transition,
          %{
            current_agent_status: story.agent_status,
            current_verified_status: story.verified_status,
            attempted_action: "verify",
            hint: "Story is already verified"
          }}}

      true ->
        {:ok, story}
    end
  end

  defp validate_review_record_exists(tenant_id, story_id, story) do
    reported_done_at = story.reported_done_at

    query =
      ReviewRecord
      |> where([r], r.tenant_id == ^tenant_id and r.story_id == ^story_id)

    query =
      if reported_done_at do
        # Primary structural guard (INVARIANT 2): the review must have reviewed
        # THIS report generation — reviewed_report_at is snapshotted from
        # reported_done_at at review-creation time. If the story was re-reported
        # since, the snapshot no longer matches and the review no longer qualifies
        # (a fresh review of the new generation is required). Legacy pre-migration
        # reviews have reviewed_report_at IS NULL and are grandfathered as matching
        # (see migration 20260702130200). Secondary guard (kept): the review must
        # have completed after the report (completed_at > reported_done_at).
        query
        |> where(
          [r],
          is_nil(r.reviewed_report_at) or r.reviewed_report_at == ^reported_done_at
        )
        |> where([r], r.completed_at > ^reported_done_at)
      else
        query
      end

    # Use limit 1 + order by to handle multiple review records for same story
    # (e.g., both orchestrator and forked review agent called review_complete)
    query = query |> order_by([r], desc: r.completed_at) |> limit(1)

    case AdminRepo.one(query) do
      nil ->
        {:error, :review_not_conducted}

      _record ->
        {:ok, :review_record_present}
    end
  end

  defp validate_rejectable(story) do
    if story.agent_status == :reported_done or story.verified_status == :verified do
      {:ok, story}
    else
      {:error,
       {:invalid_transition,
        %{
          current_agent_status: story.agent_status,
          current_verified_status: story.verified_status,
          attempted_action: "reject",
          hint:
            "Story must be 'reported_done' or 'verified' before it can be rejected. " <>
              "Did the agent report done first?"
        }}}
    end
  end

  defp apply_verified_status(story) do
    now = DateTime.utc_now()

    story
    |> Ecto.Changeset.change(%{
      verified_status: :verified,
      verified_at: now,
      rejected_at: nil,
      rejection_reason: nil
    })
    |> AdminRepo.update()
  end

  defp apply_rejected_status(story, reason) do
    now = DateTime.utc_now()

    story
    |> Ecto.Changeset.change(%{
      verified_status: :rejected,
      rejected_at: now,
      rejection_reason: reason
    })
    |> AdminRepo.update()
  end

  defp insert_verification_result(multi, tenant_id, orch_agent_id, result, params) do
    Multi.run(multi, :verification_result, fn _repo, %{lock: story} ->
      iteration = count_verifications(tenant_id, story.id) + 1

      %VerificationResult{
        tenant_id: tenant_id,
        story_id: story.id,
        orchestrator_agent_id: orch_agent_id
      }
      |> VerificationResult.create_changeset(
        Map.merge(params, %{result: result, iteration: iteration})
      )
      |> AdminRepo.insert()
    end)
  end

  defp audit_verification(multi, tenant_id, action, actor_id, actor_label, orch_agent_id) do
    Audit.log_in_multi(multi, :audit, fn %{story: updated, lock: old} ->
      %{
        tenant_id: tenant_id,
        entity_type: "story",
        entity_id: updated.id,
        action: action,
        actor_type: "api_key",
        actor_id: actor_id,
        actor_label: actor_label,
        old_state: %{"verified_status" => to_string(old.verified_status)},
        new_state: %{
          "verified_status" => to_string(updated.verified_status),
          "orchestrator_agent_id" => orch_agent_id
        }
      }
    end)
  end

  defp maybe_complete_epic(multi, tenant_id, actor_id, actor_label) do
    Multi.run(multi, :epic_completion, fn _repo, %{story: story} ->
      check_epic_completion(tenant_id, story.epic_id, actor_id, actor_label)
    end)
  end

  defp check_epic_completion(tenant_id, epic_id, actor_id, actor_label) do
    total_stories = count_stories_in_epic(tenant_id, epic_id)
    unverified_count = count_unverified_in_epic(tenant_id, epic_id)

    cond do
      # Zero-story epics never complete
      total_stories == 0 ->
        {:ok, :no_stories}

      # Not all verified yet
      unverified_count > 0 ->
        {:ok, :incomplete}

      # All verified - check if already completed (idempotent)
      epic_already_completed?(tenant_id, epic_id) ->
        {:ok, :already_completed}

      # All verified and not yet completed - fire event
      true ->
        record_epic_completion(tenant_id, epic_id, total_stories, actor_id, actor_label)
    end
  end

  defp count_stories_in_epic(tenant_id, epic_id) do
    Story
    |> where([s], s.tenant_id == ^tenant_id and s.epic_id == ^epic_id)
    |> AdminRepo.aggregate(:count, :id)
  end

  defp count_unverified_in_epic(tenant_id, epic_id) do
    Story
    |> where([s], s.tenant_id == ^tenant_id and s.epic_id == ^epic_id)
    |> where([s], s.verified_status != :verified)
    |> AdminRepo.aggregate(:count, :id)
  end

  defp epic_already_completed?(tenant_id, epic_id) do
    AuditLog
    |> where([a], a.tenant_id == ^tenant_id)
    |> where([a], a.entity_type == "epic" and a.entity_id == ^epic_id)
    |> where([a], a.action == "completed")
    |> AdminRepo.exists?()
  end

  defp record_epic_completion(tenant_id, epic_id, story_count, actor_id, actor_label) do
    epic = AdminRepo.get!(Epic, epic_id)

    payload = %{
      "event" => "epic.completed",
      "epic_id" => epic_id,
      "epic_number" => epic.number,
      "epic_title" => epic.title,
      "project_id" => epic.project_id,
      "story_count" => story_count,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    }

    with {:ok, _audit} <-
           Audit.create_log_entry(tenant_id, %{
             entity_type: "epic",
             entity_id: epic_id,
             action: "completed",
             actor_type: "api_key",
             actor_id: actor_id,
             actor_label: actor_label,
             new_state: %{
               "epic_id" => epic_id,
               "epic_number" => epic.number,
               "epic_title" => epic.title,
               "project_id" => epic.project_id,
               "story_count" => story_count
             }
           }) do
      insert_events_with_delivery(tenant_id, "epic.completed", epic.project_id, payload)

      {:ok, :completed}
    end
  end

  defp unwrap_verification_transaction(multi) do
    case AdminRepo.transaction(multi) do
      # When auto-reset happened, return the reset story (non-nil means reset was performed),
      # and announce the chain entry its release escalation appended, now that it committed.
      {:ok, %{auto_reset: {%Story{} = reset_story, released}}} ->
        Stages.announce_release(released)
        {:ok, reset_story}

      {:ok, %{story: updated}} ->
        {:ok, updated}

      {:error, _step, {:invalid_transition, _ctx} = reason, _completed} ->
        {:error, reason}

      {:error, _step, reason, _completed} ->
        {:error, reason}
    end
  end

  defp maybe_auto_reset(multi, tenant_id, orchestrator_agent_id, verifier_lineage) do
    Multi.run(multi, :auto_reset, fn _repo, %{lock: old_story, story: rejected_story} ->
      with {:ok, tenant} <- Tenants.get_tenant(tenant_id),
           true <- Tenants.get_tenant_settings(tenant, "auto_reset_on_rejection", true) do
        perform_auto_reset(
          rejected_story,
          old_story,
          tenant_id,
          orchestrator_agent_id,
          verifier_lineage
        )
      else
        false -> {:ok, nil}
        error -> error
      end
    end)
  end

  # A REJECT spent an attempt — the work was judged and was wrong — so an in-flight row is
  # re-contracted below the retry ceiling and escalated at it (US-44.4). A row already past
  # `ci` (merged, deployed) is only rebound, as before, and the story stays `pending`.
  defp perform_auto_reset(story, old_story, tenant_id, orchestrator_agent_id, verifier_lineage) do
    changeset =
      Ecto.Changeset.change(
        story,
        # The THIRD site that clears assigned_agent_id on a worked story. Only
        # `:story_rejected` in guard_backfillable/2 masks it today; stamp the durable
        # marker here too so the backfill guard never depends on that coincidence — but
        # only when there was a marker to clear (see lifecycle_stamp_change/1). The
        # epoch is bumped for the same reason every release bumps it (#803).
        %{
          agent_status: :pending,
          assigned_agent_id: nil,
          assigned_at: nil,
          reported_done_at: nil
        }
        |> Map.merge(lifecycle_stamp_change(story))
        |> Map.merge(claim_release_change(story))
      )

    with {:ok, reset_story} <- AdminRepo.update(changeset),
         # #803: the stage row follows the release inside the reject's transaction.
         {:ok, released} <-
           Stages.follow_release(
             tenant_id,
             reset_story.id,
             reset_story.claim_epoch,
             :claim_released,
             cause: :attempt,
             actor_lineage: verifier_lineage,
             actor_label: "system:auto_reset"
           ),
         {:ok, _audit} <-
           Audit.create_log_entry(tenant_id, %{
             entity_type: "story",
             entity_id: reset_story.id,
             action: "auto_reset",
             actor_type: "system",
             actor_id: nil,
             actor_label: "system:auto_reset",
             old_state: %{
               "agent_status" => to_string(old_story.agent_status),
               "assigned_agent_id" => old_story.assigned_agent_id
             },
             new_state: %{
               "agent_status" => "pending",
               "assigned_agent_id" => nil
             }
           }),
         _events <-
           generate_auto_reset_events(
             tenant_id,
             reset_story,
             orchestrator_agent_id
           ) do
      # AFTER the reset's own audit entry and webhook (see `Stages.recontract_released/4`). The
      # release result rides along so `unwrap_verification_transaction/1` can announce its
      # escalation's chain entry after the commit.
      with {:ok, story} <-
             Stages.recontract_released(tenant_id, released, reset_story, "system:auto_reset"),
           do: {:ok, {story, released}}
    end
  end

  defp generate_auto_reset_events(tenant_id, story, orchestrator_agent_id) do
    payload = %{
      "event" => "story.auto_reset",
      "story_id" => story.id,
      "project_id" => story.project_id,
      "epic_id" => story.epic_id,
      "reason" => "rejected",
      "orchestrator_agent_id" => orchestrator_agent_id,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    }

    insert_events_with_delivery(tenant_id, "story.auto_reset", story.project_id, payload)
  end

  defp insert_events_with_delivery(tenant_id, event_type, project_id, payload) do
    require Logger

    EventGenerator.matching_webhooks(tenant_id, event_type, project_id)
    |> Enum.each(fn webhook ->
      insert_single_event_with_delivery(tenant_id, webhook, event_type, payload)
    end)
  end

  defp insert_single_event_with_delivery(tenant_id, webhook, event_type, payload) do
    require Logger

    with {:ok, event} <-
           %WebhookEvent{tenant_id: tenant_id, webhook_id: webhook.id}
           |> WebhookEvent.create_changeset(%{event_type: event_type, payload: payload})
           |> AdminRepo.insert(),
         {:ok, _job} <-
           WebhookDeliveryWorker.new(%{webhook_event_id: event.id, tenant_id: tenant_id})
           |> Oban.insert() do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "Failed webhook event/delivery for webhook #{webhook.id}: #{inspect(reason)}"
        )
    end
  end

  defp extract_verification_params(params) do
    result = parse_verification_result(Map.get(params, "result") || Map.get(params, :result))

    %{
      summary: Map.get(params, "summary") || Map.get(params, :summary),
      findings: Map.get(params, "findings") || Map.get(params, :findings, %{}),
      review_type: Map.get(params, "review_type") || Map.get(params, :review_type),
      result: result
    }
  end

  defp parse_verification_result("partial"), do: :partial
  defp parse_verification_result(:partial), do: :partial
  defp parse_verification_result(_), do: :pass

  defp extract_rejection_params(params) do
    reason = Map.get(params, "reason") || Map.get(params, :reason)

    %{
      summary: reason,
      findings: Map.get(params, "findings") || Map.get(params, :findings, %{}),
      review_type: Map.get(params, "review_type") || Map.get(params, :review_type)
    }
  end

  # --- Private helpers ---

  defp lock_story(tenant_id, story_id) do
    query =
      Story
      |> where([s], s.id == ^story_id and s.tenant_id == ^tenant_id)
      |> lock("FOR UPDATE")

    case AdminRepo.one(query) do
      nil -> {:error, :not_found}
      story -> {:ok, story}
    end
  end

  # State machine: valid transitions for agent_status
  @valid_transitions %{
    pending: :contracted,
    contracted: :assigned,
    assigned: :implementing,
    implementing: :reported_done
  }

  defp validate_transition(current_status, target_status) do
    if Map.get(@valid_transitions, current_status) == target_status do
      :ok
    else
      # Return specific errors for common out-of-order transition attempts
      case {current_status, target_status} do
        {:pending, :assigned} -> {:error, :must_contract_first}
        {:pending, :implementing} -> {:error, :must_contract_first}
        {:contracted, :implementing} -> {:error, :must_claim_first}
        _ -> {:error, :invalid_transition}
      end
    end
  end

  # Returns :ok or {:error, {:invalid_transition, context}} with rich context for the caller.
  defp validate_transition_ctx(story, target_status, attempted_action) do
    case validate_transition(story.agent_status, target_status) do
      :ok ->
        :ok

      {:error, :invalid_transition} ->
        {:error,
         {:invalid_transition,
          %{
            current_agent_status: story.agent_status,
            current_verified_status: story.verified_status,
            attempted_action: attempted_action
          }}}

      other ->
        other
    end
  end

  defp validate_assigned_agent(story, agent_id) do
    if story.assigned_agent_id == agent_id do
      :ok
    else
      {:error, :not_assigned_agent}
    end
  end

  # nil agent_id: unknown identity is treated as untrusted (US-26.1.3)
  defp validate_not_self_report(_story, nil, _reporter_lineage),
    do: {:error, :self_report_blocked}

  defp validate_not_self_report(story, agent_id, reporter_lineage) do
    # INVARIANT 1 (fail closed): a story with NO assigned agent and NO implementer
    # dispatch has no implementer to separate the reporter from, so every check
    # below would pass VACUOUSLY and ANY agent key could mark it reported_done. The
    # DB CHECK stories_reported_done_requires_agent does not close this (it is
    # satisfied when implementer_dispatch_id IS NULL), so this is the enforcement,
    # mirroring verify/review-complete.
    if custody_unattributed?(story) do
      log_custody_orphaned(story, agent_id, "report")
      {:error, :missing_assigned_agent}
    else
      # US-26.2.2 AC-2: lineage comparison (primary). The reporter's lineage is
      # derived SERVER-SIDE from the caller's dispatch (never client-supplied); a
      # sub-agent dispatched BY the implementer shares its lineage root and is
      # blocked even though its agent_id differs. A DECLARED-but-unresolvable
      # implementer dispatch is an integrity failure, not a self-report — it fails
      # closed under its own error code (see lineage_status/2).
      case lineage_status(story, reporter_lineage) do
        :unresolvable -> {:error, :unresolvable_dispatch_lineage}
        :unlineaged -> {:error, :caller_lineage_required}
        :conflict -> {:error, :self_report_blocked}
        :ok -> validate_report_not_same_agent(story, agent_id)
      end
    end
  end

  defp validate_report_not_same_agent(story, agent_id) do
    if not is_nil(story.assigned_agent_id) and story.assigned_agent_id == agent_id do
      {:error, :self_report_blocked}
    else
      :ok
    end
  end

  # A story carrying no provenance at all for who did the work. Distinct from
  # custody_orphaned?/1, which additionally requires the reported_done/unverified
  # state (report runs while the story is still `implementing`).
  defp custody_unattributed?(%Story{assigned_agent_id: nil, implementer_dispatch_id: nil}),
    do: true

  defp custody_unattributed?(_story), do: false

  # Classifies the caller's dispatch lineage against the implementer's, per LCP-1
  # §7.5, returning one of three states (docs/spec/LCP-1-custody-claims.md §7.5):
  #
  #   * `:conflict`     — caller and implementer share a lineage root (a sub-agent
  #                       dispatched BY the implementer). Blocked as a self-claim.
  #   * `:unresolvable` — the implementer dispatch is DECLARED but does not resolve.
  #                       An INTEGRITY failure, not an absence of delegation:
  #                       reachable when the recorded id belongs to ANOTHER tenant
  #                       (`get_dispatch/2` scopes by `(id, tenant_id)` while the FK
  #                       is table-wide). Fails CLOSED — resolving it to [] and
  #                       leaning on `lineage_shares_prefix?([], _) = false` would
  #                       read an unloadable dispatch as INDEPENDENT lineage, the
  #                       exact inverse of its meaning.
  #   * `:unlineaged`   — the CALLER's credential was not minted by a dispatch (legacy
  #                       env-var key; OQ2 deprecation window) while the WORK was. Its
  #                       separation cannot be SHOWN, so each gate decides: report,
  #                       review-complete and verify refuse it with
  #                       `:caller_lineage_required`; reject (the remediation path)
  #                       falls through to the agent-id check. Ranked AFTER
  #                       `:unresolvable` deliberately — an empty caller lineage used to
  #                       match first and mask a broken implementer dispatch as an
  #                       ordinary permit.
  #   * `:ok`           — no lineage conflict; the agent-id equality check decides.
  #
  # One absence yields `:ok` deliberately and is NOT an integrity failure:
  # `implementer_dispatch_id` is nil — no delegation ever recorded (pre-dispatch
  # story) — and there the agent-id equality check is the whole gate by design.
  #
  # The distance demanded is `lineage_same_chain?/2` at EVERY gate: the caller must not
  # be on the implementer's root-to-leaf chain, but a SIBLING dispatch passes. The
  # documented tree puts implementer and reviewer/verifier side by side under one
  # orchestrator, so demanding a separate ROOT means no principal in a normal tenant can
  # ever act (#621). Root separation is still enforced where selection can guarantee it
  # — `select_verifier/3` and `verify_lineage_separated/4` on the RECORDED verifier.
  #
  # Every state is evaluated IN ADDITION to the agent-id equality check, never instead
  # of it.
  defp lineage_status(%Story{implementer_dispatch_id: nil}, _caller_lineage), do: :ok

  defp lineage_status(story, caller_lineage) do
    case get_dispatch_lineage(story.tenant_id, story.implementer_dispatch_id) do
      [] ->
        # Declared-but-unresolvable implementer dispatch — fail closed.
        Logger.warning(
          "unresolvable_dispatch_lineage: custody gate blocked — implementer dispatch " <>
            "could not be resolved (fail closed) story_id=#{story.id} " <>
            "tenant_id=#{story.tenant_id} implementer_dispatch_id=#{story.implementer_dispatch_id}"
        )

        :unresolvable

      _impl when caller_lineage == [] ->
        :unlineaged

      impl ->
        if Dispatches.lineage_same_chain?(impl, caller_lineage), do: :conflict, else: :ok
    end
  end

  defp validate_not_self_review(story, reviewer_agent_id, reviewer_lineage) do
    cond do
      # INVARIANT 1 (fail closed): reviewing a custody-orphaned reported_done story
      # is illegitimate — there is no known implementer, so the reviewer cannot be
      # proven distinct and the check below would pass vacuously. Fires regardless
      # of reviewer identity (including nil human reviewers). Backstops the DB
      # CHECK stories_reported_done_requires_agent.
      custody_orphaned?(story) ->
        log_custody_orphaned(story, reviewer_agent_id, "review")
        {:error, :missing_assigned_agent}

      # nil reviewer_agent_id AND no lineage: this is a human operator (user-role key
      # that no dispatch minted). Humans are structurally different from the assigned
      # implementing agent, so nil cannot equal any agent_id — pass through. The
      # controller enforces that agent/orchestrator-role keys must provide a real
      # reviewer_agent_id. The `reviewer_lineage == []` half is load-bearing: a
      # DISPATCH-minted user-role key also carries no agent_id, and permitting it on nil
      # alone let an ANCESTOR of the implementer rubber-stamp its own subtree — the
      # lineage this function is handed was never read on that path.
      is_nil(reviewer_agent_id) and reviewer_lineage == [] ->
        :ok

      # US-26.2.2 AC-2: lineage comparison (primary), from the caller's dispatch
      # resolved server-side. Blocks a sub-agent dispatched by the implementer; a
      # declared-but-unresolvable implementer dispatch fails closed under its own
      # integrity error code (see lineage_status/2).
      true ->
        case lineage_status(story, reviewer_lineage) do
          :unresolvable -> {:error, :unresolvable_dispatch_lineage}
          :unlineaged -> {:error, :caller_lineage_required}
          :conflict -> {:error, :self_review_blocked}
          :ok -> validate_review_not_same_agent(story, reviewer_agent_id)
        end
    end
  end

  defp validate_review_not_same_agent(story, reviewer_agent_id) do
    if not is_nil(story.assigned_agent_id) and story.assigned_agent_id == reviewer_agent_id do
      {:error, :self_review_blocked}
    else
      :ok
    end
  end

  defp validate_story_implementing(%Story{agent_status: :implementing}), do: :ok

  defp validate_story_implementing(story) do
    {:error,
     {:invalid_transition,
      %{
        current_agent_status: story.agent_status,
        current_verified_status: story.verified_status,
        attempted_action: "request-review",
        hint: "Story must be in 'implementing' status to request review"
      }}}
  end

  @doc """
  Whether `story`'s dependencies — its own and its epic's — are all verified: the check a claim
  makes under its lock. Also read by `Loopctl.Delivery.Placement` BEFORE it mints, so a story
  that cannot be claimed spends no dispatch.
  """
  @spec check_claim_dependencies(Ecto.UUID.t(), Story.t()) ::
          {:ok, :deps_satisfied} | {:error, :dependencies_not_met}
  def check_claim_dependencies(tenant_id, %Story{id: story_id}) do
    if Dependencies.dependencies_unmet?(tenant_id, story_id),
      do: {:error, :dependencies_not_met},
      else: {:ok, :deps_satisfied}
  end

  defp validate_unclaim(story, _agent_id) when story.agent_status == :pending do
    {:error, :invalid_transition}
  end

  defp validate_unclaim(story, _agent_id) when story.agent_status == :contracted do
    # Contracted stories have no assigned agent, so regular agents cannot
    # unclaim them. Only the orchestrator (via force_unclaim) can reset these.
    {:error, :not_assigned_to_you}
  end

  defp validate_unclaim(story, agent_id) do
    if story.assigned_agent_id == agent_id do
      :ok
    else
      {:error, :not_assigned_agent}
    end
  end

  defp validate_title(story, story_title) do
    if story.title == story_title do
      :ok
    else
      {:error, :title_mismatch}
    end
  end

  defp validate_ac_count(story, ac_count) do
    actual_count = length(story.acceptance_criteria || [])

    if actual_count == ac_count do
      :ok
    else
      {:error,
       {:contract_mismatch,
        %{expected_ac_count: actual_count, provided_ac_count: ac_count, field: :ac_count}}}
    end
  end

  defp maybe_validate_contract(_story, _story_title, _ac_count, true), do: :ok

  defp maybe_validate_contract(story, story_title, ac_count, false) do
    with :ok <- validate_title(story, story_title) do
      validate_ac_count(story, ac_count)
    end
  end

  defp maybe_create_artifact(multi, _tenant_id, _story_id, _agent_id, nil), do: multi

  defp maybe_create_artifact(multi, tenant_id, story_id, agent_id, params) do
    Multi.run(multi, :artifact, fn _repo, _changes ->
      changeset =
        %ArtifactReport{
          tenant_id: tenant_id,
          story_id: story_id,
          reported_by: :agent,
          reporter_agent_id: agent_id
        }
        |> ArtifactReport.create_changeset(params)

      AdminRepo.insert(changeset)
    end)
  end

  defp maybe_create_token_usage_report(multi, _tenant_id, _story_id, _agent_id, nil), do: multi

  defp maybe_create_token_usage_report(multi, tenant_id, story_id, agent_id, params) do
    Multi.run(multi, :token_usage_report, fn _repo, %{lock: story} ->
      attrs =
        params
        |> Map.put("story_id", story_id)
        |> Map.put("agent_id", agent_id)
        |> Map.put("project_id", story.project_id)

      changeset =
        %TokenUsage.Report{
          tenant_id: tenant_id,
          story_id: story_id,
          agent_id: agent_id,
          project_id: story.project_id
        }
        |> TokenUsage.Report.create_changeset(attrs)

      AdminRepo.insert(changeset)
    end)
  end

  defp maybe_audit_token_usage(multi, _tenant_id, _actor_id, _actor_label, nil), do: multi

  defp maybe_audit_token_usage(multi, tenant_id, actor_id, actor_label, _params) do
    Audit.log_in_multi(multi, :audit_token_usage, fn changes ->
      report = Map.get(changes, :token_usage_report)

      %{
        tenant_id: tenant_id,
        entity_type: "token_usage_report",
        entity_id: report.id,
        action: "created",
        actor_type: "api_key",
        actor_id: actor_id,
        actor_label: actor_label,
        new_state: %{
          "story_id" => report.story_id,
          "agent_id" => report.agent_id,
          "input_tokens" => report.input_tokens,
          "output_tokens" => report.output_tokens,
          "model_name" => report.model_name,
          "cost_millicents" => report.cost_millicents,
          "phase" => report.phase
        }
      }
    end)
  end

  defp validate_reason(nil), do: {:error, :reason_required}

  defp validate_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "" do
      {:error, :reason_required}
    else
      :ok
    end
  end

  defp validate_reason(_), do: {:error, :reason_required}

  defp count_verifications(tenant_id, story_id) do
    VerificationResult
    |> where([v], v.tenant_id == ^tenant_id and v.story_id == ^story_id)
    |> AdminRepo.aggregate(:max, :iteration) || 0
  end
end
