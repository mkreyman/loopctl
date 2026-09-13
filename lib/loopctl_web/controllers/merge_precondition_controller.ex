defmodule LoopctlWeb.MergePreconditionController do
  @moduledoc """
  POST /api/v1/stories/:id/merge-precondition — the second run of both delivery gates, over
  the real pull request (issue #803, design §5 and §9).

  The delivery loop asks this before it merges. A `refuse` decision has ALREADY escalated
  the story on the `{:ci, :escalated, :merge_gate}` edge by the time the response is
  written, so the caller has nothing left to decide: the answer and its consequence are one
  call. An `allow` writes nothing — the caller performs the merge and then advances
  `{:ci, :merged}` carrying the sha GitHub returned, because the merge commit does not
  exist until the merge happens.

  ## Why `exact_role: [:orchestrator, :user]`

  The same gate `review-complete` is behind, for the same reason. An `:agent` key is the
  shape a dispatched implementer holds, and an implementer asking whether its own work may
  merge is the self-approval the product exists to prevent — so it is 403'd before any
  controller code runs. The loop's merge step runs under an orchestrator dispatch, and an
  operator's user key can ask directly.

  That gate is a structural separation and not the whole of the custody check: the verdict
  itself requires `verified_status: :verified` set through a verifier dispatch with a
  lineage separate from the implementer's, recomputed server-side on every call. A caller
  cannot clear it by asking with a more privileged key.

  ## What the caller may and may not supply

  Almost nothing that decides the outcome in its own favour. The repository is resolved from
  the story's intake source, the pull request number and the head CI ran on from the stage
  row, the diff and the diffstat from GitHub, the trigger list from operator configuration,
  and the custody facts from the database. `claim_epoch` can only get the call refused,
  never accepted, since it fences the write.

  **The two exceptions are named on every verdict, because they are assertions by the same
  principal that drives the merge.**

  - `trio_outputs` is Gate A's only input and there is nowhere else to read it from yet, so
    a fabricated trio clears Gate A. Every verdict carries
    `gate_a_inputs: "caller_asserted"` and every escalation reason begins with it. What
    closes it: triage persisting its verdict against the story, after which this parameter
    goes away.
  - `effect_proof` is recorded and judged but can no longer produce an ALLOW — a
    `prove_effect` outcome escalates whatever the proof says, because a fabricated proof
    would otherwise wave through exactly the changes the gate exists for. What closes it:
    the design's Gate B harness regenerating the fixture output server-side.

  ## Status codes

  `200` for every VERDICT, including a refusal — a refusal is an answer, not a request
  error. `503` for `unevaluated`, a transient forge fault where nothing was decided and
  nothing transitioned: the caller retries, and an HTTP status that cannot be mistaken for
  an answer is the point.

  A `503` always carries `Retry-After` — the forge's own delay when it gave one, else a
  fixed floor. The commonest cause of an unevaluated verdict is a rate limit, so a caller
  that retried at will would amplify the very condition it is waiting out. The retry is
  also BOUNDED at the other end: consecutive unevaluated results at one head escalate the
  story once they pass `Loopctl.Delivery.MergePrecondition.max_consecutive_unevaluated/0`,
  so a fault that never clears ends with a human being told rather than an endless loop.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.MergePrecondition.Verdict
  alias Loopctl.DeliveryGates.GateA
  alias Loopctl.DeliveryGates.GateB
  alias Loopctl.Dispatches

  action_fallback LoopctlWeb.FallbackController

  # The `Retry-After` an `unevaluated` verdict carries when the forge named no delay of its
  # own. Documented in the operation below, so the contract never reads as "retry at will".
  @default_retry_after_seconds 30

  @reason_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      kind: %OpenApiSpex.Schema{type: :string},
      detail: %OpenApiSpex.Schema{type: :string}
    }
  }

  @verdict_schema %OpenApiSpex.Schema{
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          decision: %OpenApiSpex.Schema{
            type: :string,
            enum: ["allow", "refuse", "already_merged", "head_moved", "unevaluated"],
            description:
              "`allow` licenses the merge, and the allow has been RECORDED against the " <>
                "head it judged. `refuse` has already escalated the story. " <>
                "`already_merged` reports a merge GitHub had already performed AND a " <>
                "recorded allow authorised — one nobody authorised is a `refuse` naming " <>
                "the sha. `head_moved` sends the story back to `implementing` because the " <>
                "pull request's head is not the one CI ran on. `unevaluated` (HTTP 503) is " <>
                "a transient forge fault: nothing was decided, nothing transitioned, retry."
          },
          reasons: %OpenApiSpex.Schema{
            type: :array,
            description: "Every reason a refusal is a refusal; empty otherwise.",
            items: @reason_schema
          },
          repo: %OpenApiSpex.Schema{type: :string, nullable: true},
          pr_number: %OpenApiSpex.Schema{type: :integer, nullable: true},
          head_sha: %OpenApiSpex.Schema{type: :string, nullable: true},
          merge_base_sha: %OpenApiSpex.Schema{type: :string, nullable: true},
          merge_sha: %OpenApiSpex.Schema{
            type: :string,
            nullable: true,
            description: "Set only on `already_merged`."
          },
          diffstat: %OpenApiSpex.Schema{type: :object, nullable: true},
          hard_bound: %OpenApiSpex.Schema{
            type: :object,
            description:
              "The design's ceiling, applied on top of the configured limits: a " <>
                "configuration may tighten it and may not loosen it."
          },
          custody: %OpenApiSpex.Schema{type: :string, nullable: true},
          gate_a: %OpenApiSpex.Schema{type: :object, nullable: true},
          gate_b: %OpenApiSpex.Schema{type: :object, nullable: true},
          proof: %OpenApiSpex.Schema{type: :object, nullable: true}
        }
      }
    }
  }

  plug LoopctlWeb.Plugs.RequireRole,
       [exact_role: [:orchestrator, :user]] when action in [:create]

  # The delivery loop is work-breakdown surface: a human-anchored tenant, as every other
  # chain-of-custody endpoint requires.
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:create]

  tags(["Progress"])

  operation(:create,
    summary: "Evaluate the merge precondition",
    description:
      "Runs Gate A and Gate B a second time, over the REAL pull request rather than the " <>
        "triage trio's predicted touches, and adds the design's hard bound of 12 files / " <>
        "1000 changed lines and the custody precondition (verified_status = verified, set " <>
        "by a verifier dispatch whose lineage is separate from the implementer's).\n\n" <>
        "Requires the story's stage row to be at `ci`. The repository, the pull request " <>
        "number, the diff, the diffstat and the trigger list are all resolved server-side; " <>
        "no caller-supplied value can turn a refusal into an allow.\n\n" <>
        "Fails CLOSED: a missing, empty or unparseable trigger configuration, an unknown " <>
        "repository, a project with no intake source, an unreachable or rate-limited " <>
        "GitHub, a truncated file list, a diff that does not parse, a stale trigger at " <>
        "either the head or the merge base, and an unverified or custody-unattributed " <>
        "story all REFUSE.\n\n" <>
        "A `refuse` decision escalates the story on the `merge_gate` edge before " <>
        "responding, and returns 200: a refusal is an answer, not a request error. An " <>
        "`already_merged` decision reports a pull request GitHub already merged, with its " <>
        "`merge_sha`, so a caller that crashed after merging adopts it instead of merging " <>
        "again. Only `allow` licenses a merge.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Merge precondition params", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         required: [:claim_epoch, :trio_outputs],
         properties: %{
           claim_epoch: %OpenApiSpex.Schema{
             type: :integer,
             minimum: 0,
             description:
               "The claim epoch the caller acts under. It fences the escalation a refusal " <>
                 "writes; a stale epoch refuses the write rather than permitting anything."
           },
           trio_outputs: %OpenApiSpex.Schema{
             type: :array,
             description:
               "The triage trio's three output objects, Gate A's only input. Anything " <>
                 "other than exactly three well-formed outputs escalates.",
             items: %OpenApiSpex.Schema{type: :object}
           },
           effect_proof: %OpenApiSpex.Schema{
             type: :object,
             nullable: true,
             description:
               "The effect proof for a change touching an effect path: `intent`, " <>
                 "`fixture_set`, `fixture_results` and `coverage`. Absent, a change that " <>
                 "must prove its effect is REFUSED rather than merged."
           }
         }
       }},
    responses: %{
      200 => {"Verdict", "application/json", @verdict_schema},
      503 =>
        {"Transient forge fault — nothing was decided and nothing transitioned. Retry no " <>
           "sooner than the `Retry-After` header, which is always present. Consecutive " <>
           "unevaluated results at one head escalate the story, so this cannot repeat " <>
           "for ever.", "application/json", @verdict_schema},
      403 =>
        {"Insufficient role (exact orchestrator or user)", "application/json",
         Schemas.ErrorResponse},
      404 => {"Story not found", "application/json", Schemas.ErrorResponse},
      422 =>
        {"Story has no stage row, is not at the ci stage, or the request is malformed",
         "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "POST /api/v1/stories/:id/merge-precondition"
  def create(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, claim_epoch} <- claim_epoch(params),
         {:ok, trio_outputs} <- trio_outputs(params),
         {:ok, verdict} <-
           enforce(tenant_id, story_id, api_key, claim_epoch, trio_outputs, params) do
      conn
      |> put_status(status_for(verdict))
      |> put_retry_after(verdict)
      |> json(%{data: render_verdict(verdict)})
    end
  end

  # A transient forge fault is not an answer, and must not read as one.
  defp status_for(%Verdict{decision: :unevaluated}), do: :service_unavailable
  defp status_for(%Verdict{}), do: :ok

  # The dominant cause of an unevaluated verdict is a rate limit, so a caller retrying at
  # will amplifies the condition it is waiting out. `Retry-After` carries the forge's own
  # delay when it gave one, and `@default_retry_after_seconds` when it did not — the
  # contract states a floor either way, so there is no reading of it that means "at once".
  defp put_retry_after(conn, %Verdict{decision: :unevaluated} = verdict) do
    seconds = verdict.retry_after || @default_retry_after_seconds
    put_resp_header(conn, "retry-after", Integer.to_string(seconds))
  end

  defp put_retry_after(conn, %Verdict{}), do: conn

  defp enforce(tenant_id, story_id, api_key, claim_epoch, trio_outputs, params) do
    opts = [
      claim_epoch: claim_epoch,
      trio_outputs: trio_outputs,
      effect_proof: effect_proof(params),
      actor_label: "api_key:#{api_key.id}",
      actor_role: api_key.role,
      actor_lineage: Dispatches.lineage_for_api_key(tenant_id, api_key.id)
    ]

    case MergePrecondition.enforce(tenant_id, story_id, opts) do
      {:ok, verdict} -> {:ok, verdict}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :no_stage} -> {:error, :unprocessable_entity, "Story has no delivery stage row"}
      {:error, :wrong_stage} -> {:error, :unprocessable_entity, "Story is not at the ci stage"}
    end
  end

  defp claim_epoch(%{"claim_epoch" => epoch}) when is_integer(epoch) and epoch >= 0,
    do: {:ok, epoch}

  defp claim_epoch(_params),
    do: {:error, :unprocessable_entity, "claim_epoch must be a non-negative integer"}

  # Gate A escalates on anything that is not exactly three well-formed outputs, so this
  # only insists on a LIST — the gate is what judges its contents, and it must be the one
  # that does, so a malformed trio is recorded as an escalation rather than a 422 the loop
  # could retry its way past.
  defp trio_outputs(%{"trio_outputs" => outputs}) when is_list(outputs), do: {:ok, outputs}

  defp trio_outputs(_params),
    do: {:error, :unprocessable_entity, "trio_outputs must be an array"}

  defp effect_proof(%{"effect_proof" => proof}) when is_map(proof), do: atomize_proof(proof)
  defp effect_proof(_params), do: nil

  # The proof's own shape is `Loopctl.DeliveryGates.GateB.judge_proof/4`'s business: an
  # unreadable one is a FAILED proof there, which routes to Gate A, so nothing here has to
  # validate it beyond naming the four keys.
  defp atomize_proof(proof) do
    %{
      intent: intent(proof["intent"]),
      fixture_set: proof["fixture_set"],
      fixture_results: fixture_results(proof["fixture_results"]),
      coverage: coverage(proof["coverage"])
    }
  end

  defp intent(%{"changes" => ids}) when is_list(ids), do: {:changes, ids}
  defp intent("no_output_change"), do: :no_output_change
  defp intent(other), do: other

  defp fixture_results(results) when is_map(results) do
    Map.new(results, fn
      {id, "changed"} -> {id, :changed}
      {id, "unchanged"} -> {id, :unchanged}
      {id, other} -> {id, other}
    end)
  end

  defp fixture_results(other), do: other

  defp coverage(%{"required" => required, "covered" => covered}),
    do: %{required: required, covered: covered}

  defp coverage(other), do: other

  # -- rendering -------------------------------------------------------------------------

  defp render_verdict(%Verdict{} = verdict) do
    %{
      decision: verdict.decision,
      reasons: Enum.map(verdict.reasons, &reason/1),
      repo: verdict.repo,
      pr_number: verdict.pr_number,
      head_sha: verdict.head_sha,
      recorded_head_sha: verdict.recorded_head_sha,
      merge_base_sha: verdict.merge_base_sha,
      merge_sha: verdict.merge_sha,
      diffstat: verdict.diffstat,
      hard_bound: MergePrecondition.hard_bound(),
      custody: verdict.custody,
      gate_a_inputs: verdict.gate_a_inputs,
      retry_after: verdict.retry_after,
      gate_a: gate_a(verdict.gate_a),
      gate_b: gate_b(verdict.gate_b),
      proof: proof(verdict.proof)
    }
  end

  # A reason is an Elixir term with no wire schema, so it is rendered as a stable KIND the
  # loop can branch on plus the inspected term for a human reading the escalation.
  defp reason(reason) when is_tuple(reason), do: %{kind: elem(reason, 0), detail: inspect(reason)}
  defp reason(reason), do: %{kind: reason, detail: inspect(reason)}

  # No nil clause: `judge/1` always evaluates Gate A (its inputs are the request's own, and
  # it escalates rather than declining), so a verdict never carries a nil one.
  defp gate_a(%GateA.Result{} = result) do
    %{
      decision: result.decision,
      verdict: result.verdict,
      reasons: Enum.map(result.reasons, &reason/1),
      confidences: result.confidences,
      soft_signals:
        Enum.map(result.soft_signals, fn {index, code} -> %{index: index, code: code} end)
    }
  end

  defp gate_b(nil), do: nil

  defp gate_b(%GateB.Result{} = result) do
    %{
      outcome: result.outcome,
      merge_precondition: result.merge_precondition?,
      reasons: Enum.map(result.reasons, &reason/1),
      effect_matches:
        Enum.map(result.effect_matches, fn {file, pattern} -> %{file: file, pattern: pattern} end)
    }
  end

  defp proof(nil), do: nil

  defp proof(%GateB.ProofResult{} = result) do
    %{
      verdict: result.verdict,
      failures: Enum.map(result.failures, &reason/1),
      route: result.route
    }
  end
end
