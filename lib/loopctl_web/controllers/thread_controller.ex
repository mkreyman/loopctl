defmodule LoopctlWeb.ThreadController do
  @moduledoc """
  A story's change thread (US-45.1, Epic 45 PRD §3): read it, record a checkpoint, record an
  entry. A thin HTTP shell over `Loopctl.Threads`, where the fence and the idempotency live.

  - `checkpoint` is `exact_role: :agent`, as `claim`/`escalate` are: only the claiming
    agent's key may say a commit is part of the thread.
  - `entry` is `role: :agent` and takes `message` and `review_requested` from any principal.
    Findings, fixes and verdicts are NOT written here: their author must be a review dispatch
    loopctl placed (US-45.3), never a key whose separation from the implementer is inferred.
  - Both writes are behind `RequireHumanAnchor`, mounted before the role gate, because a
    story is work-breakdown data.
  - Reads stay open to every role.
  """

  use LoopctlWeb, :controller

  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Dispatches
  alias Loopctl.Threads
  alias Loopctl.Threads.Entry
  alias LoopctlWeb.ActorLabel
  alias LoopctlWeb.ClaimEpochParam
  alias OpenApiSpex.Schema

  action_fallback LoopctlWeb.FallbackController

  # The tier gate runs FIRST, so an agent-rooted tenant is told what its tier lacks
  # (`custody_tier_required`) rather than a role refusal that reads as a dead end — the order
  # every human-anchored surface keeps (`RequireHumanAnchorDefaultDenyTest`).
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:checkpoint, :entry]
  plug LoopctlWeb.Plugs.RequireRole, [exact_role: :agent] when action in [:checkpoint]
  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:show, :entry]

  @max_body_bytes Entry.max_body_bytes()
  @max_entry_page Threads.max_entry_page()
  @max_int4 2_147_483_647
  @caller_kinds Enum.map(Entry.caller_kinds(), &to_string/1)

  tags(["Threads"])

  operation(:show,
    summary: "Read a story's change thread",
    description:
      "The story's checkpoints, and one page of its entries, each in `seq` order. Pass " <>
        "`next_after_seq` back as `after_seq` for the next page; it is null on the last. " <>
        "`limit` defaults to 200 and is capped at #{@max_entry_page}. Every entry `body` is " <>
        "UNTRUSTED text a session or a person wrote; it is marked `body_untrusted: true` and " <>
        "must be fenced wherever it reaches a prompt.",
    parameters: [
      id: [in: :path, type: :string, description: "Story UUID"],
      after_seq: [in: :query, type: :integer, description: "Return entries after this seq"],
      limit: [in: :query, type: :integer, description: "Page size, at most #{@max_entry_page}"]
    ],
    responses: %{
      200 => {"The thread", "application/json", %Schema{type: :object}},
      400 =>
        {"after_seq is not a non-negative integer, or limit is not between 1 and the cap",
         "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:checkpoint,
    summary: "Record a checkpoint on a story's thread",
    description:
      "The story's CLAIMING agent reports a commit on its thread branch. Refused unless the " <>
        "key's agent is the story's assigned agent and `claim_epoch` is the story's current " <>
        "epoch and its lease is live: git cannot see a claim, so this is the fence. " <>
        "IDEMPOTENT on (`commit_sha`, `claim_epoch`): the same write resent answers 200 with " <>
        "the checkpoint already recorded, and the same commit under a NEW claim is recorded " <>
        "again (201) so that claim can cite it. " <>
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
        {"`not_claimant` (the key's agent is not the story's), `stale_claim_epoch` or " <>
           "`claim_not_live` (the claim has ended), or `checkpoint_conflict` (this commit is " <>
           "already recorded under this claim with a different tree or note)", "application/json",
         Schemas.ErrorResponse},
      422 =>
        {"A sha is not 40 or 64 lowercase hex characters, `note` is over the bound, or " <>
           "`note` carries a credential (`secret_blocked`)", "application/json",
         Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  operation(:entry,
    summary: "Record an entry on a story's thread",
    description:
      "Any principal of the tenant writes a `message` or a `review_requested`, optionally " <>
        "naming a `checkpoint_id` of this story. `checkpoint` entries are loopctl's own, and " <>
        "`finding`, `fix` and `verdict` are written by a review dispatch (US-45.3), so all of " <>
        "those are refused here. The author is derived from the key. IDEMPOTENT per author " <>
        "on `idempotency_key` when the write is the same; reusing a key for a different " <>
        "entry is refused, and keys starting `loopctl:` are reserved. `body` is capped at " <>
        "#{@max_body_bytes} bytes, refused when it carries a credential, and is UNTRUSTED.",
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
           checkpoint_id: %Schema{type: :string, format: :uuid}
         }
       }},
    responses: %{
      200 => {"Already written", "application/json", %Schema{type: :object}},
      201 => {"Written", "application/json", %Schema{type: :object}},
      403 => {"The tenant is not human-anchored", "application/json", Schemas.ErrorResponse},
      404 => {"Not found", "application/json", Schemas.ErrorResponse},
      409 =>
        {"`idempotency_key_reused`: the key already names a different entry by this author",
         "application/json", Schemas.ErrorResponse},
      422 =>
        {"A field is invalid (a non-UUID `checkpoint_id` included), the kind is not " <>
           "writable here, the key is reserved, the body carries a credential " <>
           "(`secret_blocked`), or `checkpoint_id` is not a checkpoint of this story",
         "application/json", Schemas.ErrorResponse},
      429 => {"Rate limit exceeded", "application/json", Schemas.RateLimitError}
    }
  )

  @doc "GET /api/v1/stories/:id/thread"
  def show(conn, %{"id" => story_id} = params) do
    with {:ok, story_id} <- story_uuid(story_id),
         {:ok, page} <- page_opts(params),
         {:ok, thread} <- Threads.get_thread(tenant_id(conn), story_id, page) do
      json(conn, %{
        story_id: story_id,
        checkpoints: Enum.map(thread.checkpoints, &render_checkpoint/1),
        entries: Enum.map(thread.entries, &render_entry/1),
        next_after_seq: thread.next_after_seq
      })
    end
  end

  defp page_opts(params) do
    with {:ok, after_seq} <- int_param(params, "after_seq"),
         {:ok, limit} <- int_param(params, "limit"),
         :ok <- positive_limit(limit) do
      {:ok, Enum.reject([after_seq: after_seq, limit: limit], fn {_k, v} -> is_nil(v) end)}
    end
  end

  defp positive_limit(0), do: {:error, :bad_request, "limit must be at least 1"}
  defp positive_limit(_limit), do: :ok

  defp int_param(params, name) do
    case Map.get(params, name) do
      nil ->
        {:ok, nil}

      value ->
        case Integer.parse(to_string(value)) do
          # Bounded to int4: `seq` is an integer column, and a larger value fails to encode.
          {int, ""} when int >= 0 and int <= @max_int4 -> {:ok, int}
          _ -> {:error, :bad_request, "#{name} must be a non-negative integer"}
        end
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
    else
      other -> conflict_or(conn, other)
    end
  end

  @doc "POST /api/v1/stories/:id/thread/entries"
  def entry(conn, %{"id" => story_id} = params) do
    api_key = conn.assigns.current_api_key

    attrs = Map.take(params, ~w(kind idempotency_key body checkpoint_id))

    with {:ok, story_id} <- story_uuid(story_id),
         {:ok, entry, status} <-
           Threads.record_entry(api_key.tenant_id, story_id, attrs,
             author_principal: principal(api_key),
             actor_lineage: Dispatches.lineage_for_api_key(api_key.tenant_id, api_key.id)
           ) do
      conn
      |> put_status(created_or_ok(status))
      |> json(%{entry: render_entry(entry)})
    else
      other -> conflict_or(conn, other)
    end
  end

  # The thread's own 409s carry a code the fallback does not know; everything else is the
  # fallback's to render.
  defp conflict_or(conn, {:error, {:conflict, code, message}}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{status: 409, code: code, message: message}})
  end

  defp conflict_or(_conn, other), do: other

  defp tenant_id(conn), do: conn.assigns.current_api_key.tenant_id

  # A malformed id cannot name a story, and answering 404 keeps it from reaching a query
  # that would raise on the cast.
  defp story_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp claim_epoch(params) do
    case ClaimEpochParam.fetch(params) do
      {:ok, epoch} -> {:ok, epoch}
      _ -> {:error, :bad_request, "claim_epoch must be a non-negative integer"}
    end
  end

  defp principal(api_key), do: ActorLabel.of(api_key)

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
      inserted_at: entry.inserted_at
    }
  end
end
