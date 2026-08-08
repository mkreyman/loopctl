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
  alias Loopctl.Dispatches
  alias Loopctl.Tenants
  alias Loopctl.TokenUsage
  alias Loopctl.Webhooks.EventGenerator
  alias Loopctl.Webhooks.WebhookEvent
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.EpicDependency
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.WorkBreakdown.StoryDependency
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
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :lock, reason, _} -> {:error, reason}
      {:error, :validate, reason, _} -> {:error, reason}
      {:error, :story, changeset, _} -> {:error, changeset}
    end
  end

  @doc """
  Claims a story: assigns the agent to a contracted story.

  Transitions agent_status from `contracted` to `assigned`.
  Uses pessimistic locking (SELECT FOR UPDATE) to prevent race conditions.

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if not in contracted state
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
      |> Multi.run(:check_deps, fn _repo, %{lock: story} ->
        check_claim_dependencies(story)
      end)
      |> Multi.run(:story, fn _repo, %{lock: story} ->
        now = DateTime.utc_now()
        dispatch_id = Keyword.get(opts, :dispatch_id)

        changes = %{
          agent_status: :assigned,
          assigned_agent_id: agent_id,
          assigned_at: now
        }

        # US-26.2.2 AC-3: record implementer's dispatch at claim time
        changes =
          if dispatch_id,
            do: Map.put(changes, :implementer_dispatch_id, dispatch_id),
            else: changes

        story
        |> Ecto.Changeset.change(changes)
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
            "assigned_agent_id" => agent_id,
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
        # US-26.3.1 AC-5: mint a start_cap for the claiming lineage, and return it
        # on the struct (#621) so the caller can present it to POST /start.
        lineage = Keyword.get(opts, :lineage, [])
        cap = mint_cap(tenant_id, "start_cap", updated.id, lineage)
        {:ok, %{updated | minted_capability: cap}}

      {:error, :lock, reason, _} ->
        {:error, reason}

      {:error, :validate, reason, _} ->
        {:error, reason}

      {:error, :check_deps, reason, _} ->
        {:error, reason}

      {:error, :story, changeset, _} ->
        {:error, changeset}
    end
  end

  # Mints a capability token and RETURNS it, so the caller can hand it to the
  # agent that will need it for the next custody op. Returns nil when minting
  # is impossible or fails.
  #
  # Issue #621: this used to discard the token "to keep the return type
  # backward-compatible", and no other path delivered it either — so every
  # keyed tenant's next lifecycle call hit `:missing_capability` (see
  # maybe_consume_cap/6). The token is now returned and surfaced on the story
  # struct's virtual :minted_capability field.
  #
  # A mint failure is only tolerable for a PRE-V2 (keyless) tenant, where
  # maybe_consume_cap/6 lets a nil cap through. For a KEYED tenant the
  # capability is MANDATORY, so a silent nil here wedges the lifecycle exactly
  # the way #621 did — hence the loud log + telemetry rather than a bare nil.
  defp mint_cap(tenant_id, typ, story_id, lineage) do
    case Capabilities.mint(tenant_id, typ, story_id, lineage) do
      {:ok, cap} ->
        cap

      {:error, reason} ->
        if tenant_has_audit_key?(tenant_id) do
          Logger.error(
            "capability_mint_failed: KEYED tenant could not mint a capability — the next " <>
              "custody call for this story will fail with missing_capability until the agent " <>
              "recovers one via POST /stories/:id/recover-cap. " <>
              "tenant_id=#{tenant_id} story_id=#{story_id} cap_type=#{typ} reason=#{inspect(reason)}"
          )

          :telemetry.execute(
            [:loopctl, :custody, :cap_mint_failed],
            %{count: 1},
            %{tenant_id: tenant_id, story_id: story_id, cap_type: typ, reason: reason}
          )
        end

        nil
    end
  end

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

  defp cap_refusal_action(reason) when reason in @cap_rejected_refusals,
    do: "capability_forged"

  defp cap_refusal_action(_reason), do: "capability_refused"

  defp cap_refusal_log("capability_forged", tenant_id, story_id, reason, ctx) do
    "capability_forged: #{reason} — the presented token did not verify against the " <>
      "tenant's audit signing key. This is not a stale token; investigate the caller. " <>
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
        with :ok <- validate_transition_ctx(story, :implementing, "start"),
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
        with :ok <- validate_transition_ctx(story, :reported_done, "report"),
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
             :ok <- validate_assigned_agent(story, agent_id) do
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

  ## Parameters

  - `tenant_id` -- the tenant UUID
  - `story_id` -- the story UUID
  - `opts` -- keyword list with `:agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  - `{:error, :invalid_transition}` if already pending
  - `{:error, :not_assigned_agent}` if calling agent is not the assigned agent
  """
  @spec unclaim_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Story.t()} | {:error, atom()}
  def unclaim_story(tenant_id, story_id, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    multi =
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
        |> Ecto.Changeset.change(%{
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

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :lock, reason, _} -> {:error, reason}
      {:error, :validate, reason, _} -> {:error, reason}
      {:error, :story, changeset, _} -> {:error, changeset}
    end
  end

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
        |> maybe_auto_reset(tenant_id, orchestrator_agent_id)

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
  - `opts` -- keyword list with `:orchestrator_agent_id`, `:actor_id`, `:actor_label`

  ## Returns

  - `{:ok, %Story{}}` on success
  - `{:error, :not_found}` if story not found in tenant
  """
  @spec force_unclaim_story(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Story.t()} | {:error, atom()}
  def force_unclaim_story(tenant_id, story_id, opts \\ []) do
    orchestrator_agent_id = Keyword.get(opts, :orchestrator_agent_id)
    actor_id = Keyword.get(opts, :actor_id)
    actor_label = Keyword.get(opts, :actor_label)

    multi =
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
          |> Ecto.Changeset.change(%{
            agent_status: :pending,
            assigned_agent_id: nil,
            assigned_at: nil,
            reported_done_at: nil,
            reported_by_agent_id: nil,
            # See unclaim_story/3: the durable half of the anti-launder guard, stamped
            # at the moment the erasable dispatch markers are erased.
            lifecycle_entered_at: lifecycle_stamp(story)
          })
          |> AdminRepo.update()
        end
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

    case AdminRepo.transaction(multi) do
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, :lock, reason, _} -> {:error, reason}
      {:error, :story, changeset, _} -> {:error, changeset}
    end
  end

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
      # When auto-reset happened, return the reset story (non-nil means reset was performed)
      {:ok, %{auto_reset: %Story{} = reset_story}} -> {:ok, reset_story}
      {:ok, %{story: updated}} -> {:ok, updated}
      {:error, _step, {:invalid_transition, _ctx} = reason, _completed} -> {:error, reason}
      {:error, _step, reason, _completed} -> {:error, reason}
    end
  end

  defp maybe_auto_reset(multi, tenant_id, orchestrator_agent_id) do
    Multi.run(multi, :auto_reset, fn _repo, %{lock: old_story, story: rejected_story} ->
      with {:ok, tenant} <- Tenants.get_tenant(tenant_id),
           true <- Tenants.get_tenant_settings(tenant, "auto_reset_on_rejection", true) do
        perform_auto_reset(rejected_story, old_story, tenant_id, orchestrator_agent_id)
      else
        false -> {:ok, nil}
        error -> error
      end
    end)
  end

  defp perform_auto_reset(story, old_story, tenant_id, orchestrator_agent_id) do
    changeset =
      Ecto.Changeset.change(
        story,
        # The THIRD site that clears assigned_agent_id on a worked story. Only
        # `:story_rejected` in guard_backfillable/2 masks it today; stamp the durable
        # marker here too so the backfill guard never depends on that coincidence — but
        # only when there was a marker to clear (see lifecycle_stamp_change/1).
        Map.merge(
          %{
            agent_status: :pending,
            assigned_agent_id: nil,
            assigned_at: nil,
            reported_done_at: nil
          },
          lifecycle_stamp_change(story)
        )
      )

    with {:ok, reset_story} <- AdminRepo.update(changeset),
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
      {:ok, reset_story}
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

  defp check_claim_dependencies(story) do
    # Check story-level dependencies: all depends_on stories must be verified
    story_deps_unmet =
      from(sd in StoryDependency,
        join: dep in Story,
        on: dep.id == sd.depends_on_story_id,
        where: sd.story_id == ^story.id and dep.verified_status != :verified,
        select: count(sd.id)
      )
      |> AdminRepo.one()

    if story_deps_unmet > 0 do
      {:error, :dependencies_not_met}
    else
      # Check epic-level dependencies: all stories in prerequisite epics must be verified
      epic_deps_unmet =
        from(ed in EpicDependency,
          where: ed.epic_id == ^story.epic_id,
          join: prereq_story in Story,
          on: prereq_story.epic_id == ed.depends_on_epic_id,
          where: prereq_story.verified_status != :verified,
          select: count(prereq_story.id)
        )
        |> AdminRepo.one()

      if epic_deps_unmet > 0 do
        {:error, :dependencies_not_met}
      else
        {:ok, :deps_satisfied}
      end
    end
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
