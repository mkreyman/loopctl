defmodule LoopctlWeb.ThreadController do
  @moduledoc """
  A story's change thread (US-45.1, Epic 45 PRD §3): read it, record a checkpoint, record an
  entry. A thin HTTP shell over `Loopctl.Threads`, where the fence and the idempotency live.

  - `checkpoint` is `exact_role: :agent`, as `claim`/`escalate` are: only the claiming
    agent's key may say a commit is part of the thread, and the context compares it with the
    story's `assigned_agent_id` and `claim_epoch`.
  - `entry` is `role: :agent`: a reviewer is not the claimant, and neither is Mark, so any
    principal of the tenant may write the caller kinds. The author is derived from the key.
  - Both writes are behind `RequireHumanAnchor`, because a story is work-breakdown data.
  - Reads stay open to every role, as on the rest of the story surface.
  """

  use LoopctlWeb, :controller

  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Dispatches
  alias Loopctl.Threads
  alias Loopctl.Threads.Entry
  alias OpenApiSpex.Schema

  action_fallback LoopctlWeb.FallbackController

  # The tier gate runs FIRST, so an agent-rooted tenant is told what its tier lacks
  # (`custody_tier_required`) rather than a role refusal that reads as a dead end — the order
  # every human-anchored surface keeps (`RequireHumanAnchorDefaultDenyTest`).
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:checkpoint, :entry]
  plug LoopctlWeb.Plugs.RequireRole, [exact_role: :agent] when action in [:checkpoint]
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:show, :entry]

  @max_body_bytes Entry.max_body_bytes()
  @caller_kinds Enum.map(Entry.caller_kinds(), &to_string/1)

  tags(["Threads"])

  operation(:show,
    summary: "Read a story's change thread",
    description:
      "The story's checkpoints and entries, each in `seq` order. Every entry `body` is " <>
        "UNTRUSTED text a session or a person wrote; it is marked `body_untrusted: true` and " <>
        "must be fenced wherever it reaches a prompt.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    responses: %{
      200 => {"The thread", "application/json", %Schema{type: :object}},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:checkpoint,
    summary: "Record a checkpoint on a story's thread",
    description:
      "The story's CLAIMING agent reports a commit on its thread branch. Refused unless the " <>
        "key's agent is the story's assigned agent and `claim_epoch` is the story's current " <>
        "epoch: git cannot see a claim, so this is the fence. IDEMPOTENT on `commit_sha`: a " <>
        "resend answers 200 with the checkpoint already recorded; a new one answers 201. " <>
        "`note` is the claimant's reasoning for the checkpoint, stored as the checkpoint " <>
        "entry's body, capped at #{@max_body_bytes} bytes, UNTRUSTED.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Checkpoint", "application/json",
       %Schema{
         type: :object,
         required: [:claim_epoch, :commit_sha, :tree_sha],
         properties: %{
           claim_epoch: %Schema{type: :integer, minimum: 0},
           commit_sha: %Schema{type: :string, pattern: "^[0-9a-f]{40}([0-9a-f]{24})?$"},
           tree_sha: %Schema{type: :string, pattern: "^[0-9a-f]{40}([0-9a-f]{24})?$"},
           note: %Schema{type: :string, maxLength: @max_body_bytes}
         }
       }},
    responses: %{
      200 => {"Already recorded", "application/json", %Schema{type: :object}},
      201 => {"Recorded", "application/json", %Schema{type: :object}},
      400 => {"claim_epoch missing or not an integer", "application/json", Schemas.ErrorResponse},
      403 =>
        {"Not an agent key, or the tenant is not human-anchored", "application/json",
         Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 =>
        {"`not_claimant` (the key's agent is not the story's) or `stale_claim_epoch` (the " <>
           "claim has ended)", "application/json", Schemas.ErrorResponse},
      422 =>
        {"A sha is not 40 or 64 lowercase hex characters, or `note` is over the bound",
         "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:entry,
    summary: "Record an entry on a story's thread",
    description:
      "Any principal of the tenant writes a `message`, `review_requested`, `finding`, " <>
        "`fix` or `verdict`; `checkpoint`, `escalation` and `merge` entries are loopctl's " <>
        "own. The author is derived from the key. IDEMPOTENT per author on " <>
        "`idempotency_key`: a resend answers 200 with the entry already written.\n\n" <>
        "A `finding` must name a `checkpoint_id` of this story, and after the story's first " <>
        "completed review round it must also carry `introduced_by`: a checkpoint id of this " <>
        "story, or `none`. A `fix` must name at least one `finding_ids` entry, each a finding " <>
        "of this story. `body` is capped at #{@max_body_bytes} bytes and is UNTRUSTED.",
    parameters: [id: [in: :path, type: :string, description: "Story UUID"]],
    request_body:
      {"Entry", "application/json",
       %Schema{
         type: :object,
         required: [:kind, :idempotency_key, :body],
         properties: %{
           kind: %Schema{type: :string, enum: @caller_kinds},
           idempotency_key: %Schema{type: :string, minLength: 1, maxLength: 255},
           body: %Schema{type: :string, minLength: 1, maxLength: @max_body_bytes},
           checkpoint_id: %Schema{type: :string, format: :uuid},
           finding_ids: %Schema{type: :array, items: %Schema{type: :string, format: :uuid}},
           introduced_by: %Schema{
             type: :string,
             description: "A checkpoint id of this story, or `none`"
           },
           severity: %Schema{type: :string, enum: ~w(critical high medium low)}
         }
       }},
    responses: %{
      200 => {"Already written", "application/json", %Schema{type: :object}},
      201 => {"Written", "application/json", %Schema{type: :object}},
      403 => {"The tenant is not human-anchored", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      422 =>
        {"A field is invalid, the kind is loopctl's own, or a reference does not belong to " <>
           "this story", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/stories/:id/thread"
  def show(conn, %{"id" => story_id}) do
    with {:ok, story_id} <- story_uuid(story_id),
         {:ok, thread} <- Threads.get_thread(tenant_id(conn), story_id) do
      json(conn, %{
        story_id: story_id,
        checkpoints: Enum.map(thread.checkpoints, &render_checkpoint/1),
        entries: Enum.map(thread.entries, &render_entry/1)
      })
    end
  end

  @doc "POST /api/v1/stories/:id/thread/checkpoints"
  def checkpoint(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key

    with {:ok, story_id} <- story_uuid(story_id),
         {:ok, epoch} <- claim_epoch(params),
         {:ok, checkpoint, status} <-
           Threads.record_checkpoint(api_key.tenant_id, story_id,
             agent_id: api_key.agent_id,
             claim_epoch: epoch,
             commit_sha: params["commit_sha"],
             tree_sha: params["tree_sha"],
             note: params["note"],
             author_principal: principal(api_key),
             actor_lineage: Dispatches.lineage_for_api_key(api_key.tenant_id, api_key.id)
           ) do
      conn
      |> put_status(created_or_ok(status))
      |> json(%{checkpoint: render_checkpoint(checkpoint)})
    end
  end

  @doc "POST /api/v1/stories/:id/thread/entries"
  def entry(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key

    attrs =
      Map.take(
        params,
        ~w(kind idempotency_key body checkpoint_id finding_ids introduced_by severity)
      )

    with {:ok, story_id} <- story_uuid(story_id),
         {:ok, entry, status} <-
           Threads.record_entry(api_key.tenant_id, story_id, attrs,
             agent_id: api_key.agent_id,
             claim_epoch: params["claim_epoch"],
             author_principal: principal(api_key),
             actor_lineage: Dispatches.lineage_for_api_key(api_key.tenant_id, api_key.id)
           ) do
      conn
      |> put_status(created_or_ok(status))
      |> json(%{entry: render_entry(entry)})
    end
  end

  defp tenant_id(conn), do: conn.assigns.current_api_key.tenant_id

  # A malformed id cannot name a story, and answering 404 keeps it from reaching a query
  # that would raise on the cast.
  defp story_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp claim_epoch(%{"claim_epoch" => epoch}) when is_integer(epoch) and epoch >= 0,
    do: {:ok, epoch}

  defp claim_epoch(_params),
    do: {:error, :bad_request, "claim_epoch must be a non-negative integer"}

  # The same attribution shape the stage machine records: the agent when the key has one,
  # otherwise the key itself.
  defp principal(%{agent_id: nil, id: key_id}), do: "api_key:" <> key_id
  defp principal(%{agent_id: agent_id}), do: "agent:" <> agent_id

  defp created_or_ok(:created), do: :created
  defp created_or_ok(:existing), do: :ok

  defp render_checkpoint(checkpoint) do
    %{
      id: checkpoint.id,
      seq: checkpoint.seq,
      kind: checkpoint.kind,
      commit_sha: checkpoint.commit_sha,
      tree_sha: checkpoint.tree_sha,
      parent_checkpoint_id: checkpoint.parent_checkpoint_id,
      claim_epoch: checkpoint.claim_epoch,
      dispatch_id: checkpoint.dispatch_id,
      merge_commit_sha: checkpoint.merge_commit_sha,
      gate_evidence: checkpoint.gate_evidence,
      inserted_at: checkpoint.inserted_at
    }
  end

  defp render_entry(entry) do
    %{
      id: entry.id,
      seq: entry.seq,
      kind: entry.kind,
      author_principal: entry.author_principal,
      dispatch_id: entry.dispatch_id,
      idempotency_key: entry.idempotency_key,
      body: entry.body,
      body_untrusted: true,
      checkpoint_id: entry.checkpoint_id,
      finding_ids: entry.finding_ids,
      introduced_by: entry.introduced_by,
      severity: entry.severity,
      inserted_at: entry.inserted_at
    }
  end
end
