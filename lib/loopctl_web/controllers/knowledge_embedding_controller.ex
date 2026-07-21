defmodule LoopctlWeb.KnowledgeEmbeddingController do
  @moduledoc """
  US-41.1 — the per-tenant embedding DIMENSION surface.

  Before this controller existed, every US-41.1 entry point was unreachable from
  outside IEx (review #4): `Embeddings.recall_availability/1`, `enqueue_reembed/2`
  and `enqueue_system_corpus_materialization/2` had no production caller, and
  `tenants.tenant_embedding_dimension` appeared in no view, serializer or tool. The
  net effect was that AC-41.1.4's per-tenant read, AC-41.1.7's on-demand system-corpus
  materialization and AC-41.1.10's agent-triggerable re-embed were all dead code.

    * `GET  /api/v1/knowledge/embeddings` — the tenant's active dimension, whether
      semantic recall is available and WHY NOT if it is not (AC-41.1.4 / AC-41.1.8),
      the instance's supported set (AC-41.1.3), the system-corpus materialization
      state (AC-41.1.7) and re-embed progress (AC-41.1.10). Role: agent+.
    * `POST /api/v1/knowledge/embeddings/system-corpus` — materialize the shared
      system corpus for THIS tenant at its active dimension (AC-41.1.7). Purely
      constructive (it only ADDS rows), so agent+.
    * `POST /api/v1/knowledge/embeddings/reembed` — move the tenant's whole corpus
      onto `target_dimension` (AC-41.1.10). Role: **orchestrator+**, deliberately not
      agent: the operation re-bills the tenant for the entire corpus and its
      completion DELETES every stale-dimension row, and the loopctl trust model
      reserves data-REMOVING operations for higher roles. Orchestrator keeps it
      triggerable by an autonomous session — which is the defect this closes — without
      handing a bare agent a destructive, cost-bearing lever.

  Both POSTs are idempotent: the workers are `unique` per `(tenant_id, dimension)` and
  their batch queries are anti-joins, so re-posting while a run is in flight is a no-op.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Loopctl.Audit
  alias Loopctl.Auth.Role
  alias Loopctl.Embeddings

  action_fallback LoopctlWeb.FallbackController

  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:status, :system_corpus]
  plug LoopctlWeb.Plugs.RequireRole, [role: :orchestrator] when action in [:reembed]

  # The re-embed re-bills the tenant for its ENTIRE corpus and its completion DELETES
  # every stale-dimension row, so it is a data-removing, cost-bearing operation — the
  # default-deny tier gate applies. `status` is a read and `system_corpus` only ADDS
  # the caller's own rows with the caller's own credential, so neither is gated (both
  # are covered by the default-deny route audit's reviewed allowlist).
  plug LoopctlWeb.Plugs.RequireHumanAnchor when action in [:reembed]

  tags(["Knowledge Wiki"])

  operation(:status,
    summary: "Embedding dimension status",
    description:
      "The tenant's active embedding dimension, whether semantic recall is currently " <>
        "available (and the reason when it is not), the instance's supported dimension " <>
        "set, the shared system corpus's materialization state, and re-embed progress. " <>
        "Role: agent+.",
    responses: %{
      200 =>
        {"Embedding status", "application/json",
         %OpenApiSpex.Schema{
           type: :object
         }}
    }
  )

  def status(conn, _params) do
    tenant_id = conn.assigns.current_api_key.tenant_id
    availability = Embeddings.recall_availability(tenant_id)
    dimension = availability.dimension

    json(conn, %{
      dimension: dimension,
      supported_dimensions: Embeddings.supported_dimensions(),
      default_dimension: Embeddings.default_dimension(),
      reads_side_table: availability.reads_side_table,
      semantic_available: availability.semantic_available,
      reason: availability.reason,
      system_corpus: Embeddings.system_corpus_meta(tenant_id, dimension),
      dimension_counts: Embeddings.dimension_counts(tenant_id)
    })
  end

  operation(:system_corpus,
    summary: "Materialize the shared system corpus for this tenant",
    description:
      "Enqueues the AC-41.1.7 on-demand per-tenant materialization of the SYSTEM-scoped " <>
        "article corpus at this tenant's active dimension, using this tenant's own " <>
        "embedding credential. Idempotent. Role: agent+.",
    responses: %{202 => {"Enqueued", "application/json", %OpenApiSpex.Schema{type: :object}}}
  )

  def system_corpus(conn, _params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id
    dimension = Embeddings.active_dimension(tenant_id)

    # `force: true` bypasses the terminal-job gate that stops a cost-bearing
    # materialization from being re-driven forever (review). A PLAIN AGENT key does NOT
    # get it: a tenant whose materialization terminated permanently could otherwise be
    # re-driven by any agent every 300s. Only an orchestrator+ (a deliberate operator
    # decision) clears a terminal state — the retry is exactly how it is meant to be
    # cleared; a bare agent honours the gate.
    force? = Role.role_at_least?(api_key.role, :orchestrator)

    case Embeddings.enqueue_system_corpus_materialization(tenant_id,
           dimension: dimension,
           force: force?
         ) do
      {:ok, _job} ->
        conn
        |> put_status(:accepted)
        |> json(%{enqueued: true, dimension: dimension})

      {:error, :materialization_terminal} ->
        # A prior run for this (tenant, dimension) terminated permanently and this is a
        # plain agent key, which does not force. An orchestrator+ retry clears it.
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "materialization_terminal",
          detail:
            "a prior system-corpus materialization for this tenant and dimension " <>
              "terminated permanently (e.g. no embedding key). Retry requires an " <>
              "orchestrator+ key.",
          dimension: dimension
        })

      {:error, reason} ->
        enqueue_failed(conn, tenant_id, "system_corpus", reason)
    end
  end

  operation(:reembed,
    summary: "Re-embed the tenant's corpus onto a new dimension",
    description:
      "Enqueues the AC-41.1.10 re-embed onto `target_dimension`. Recall keeps serving at " <>
        "the CURRENT dimension for the whole run; the tenant's recorded dimension is " <>
        "flipped and the stale-dimension rows dropped only after the whole corpus " <>
        "(articles, per-tenant system-article materializations AND agent memories) is " <>
        "present at the target. One-time and cost-bearing: it re-bills the tenant for the " <>
        "entire corpus. Role: orchestrator+.",
    request_body:
      {"Re-embed request", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{target_dimension: %OpenApiSpex.Schema{type: :integer}},
         required: [:target_dimension]
       }},
    responses: %{202 => {"Enqueued", "application/json", %OpenApiSpex.Schema{type: :object}}}
  )

  def reembed(conn, params) do
    api_key = conn.assigns.current_api_key
    tenant_id = api_key.tenant_id

    with {:ok, target} <- parse_dimension(params["target_dimension"]),
         {:ok, _job} <- Embeddings.enqueue_reembed(tenant_id, target) do
      # AUDIT the enqueue (review): the re-embed re-bills the tenant for its whole
      # corpus and its completion DELETES every stale-dimension row. KB 3e89e251 only
      # permits a data-removing operation below `:user` when it is reversible AND
      # audited; keeping it at `:orchestrator` therefore requires the audited trail this
      # writes (an append-only, hash-chained audit_chain entry) on enqueue.
      Audit.create_log_entry(tenant_id, %{
        entity_type: "knowledge_embedding",
        entity_id: tenant_id,
        action: "embedding.reembed_enqueued",
        actor_type: "api_key",
        actor_id: api_key.id,
        actor_label: "api_key:#{api_key.id}",
        new_state: %{"target_dimension" => target}
      })

      conn
      |> put_status(:accepted)
      |> json(%{
        enqueued: true,
        target_dimension: target,
        progress: Embeddings.reembed_progress(tenant_id, target)
      })
    else
      {:error, :invalid_dimension} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "invalid_target_dimension",
          detail: "target_dimension must be a positive integer",
          supported_dimensions: Embeddings.supported_dimensions()
        })

      {:error, :unsupported_dimension} ->
        # AC-41.1.4: the error names BOTH sides — what was asked for and what this
        # instance can actually serve — rather than an opaque 422.
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "unsupported_dimension",
          detail:
            "this instance has pre-built ANN indexes only for the listed dimensions; " <>
              "an unlisted dimension would degrade recall to a sequential scan",
          requested: params["target_dimension"],
          supported_dimensions: Embeddings.supported_dimensions()
        })

      {:error, reason} ->
        enqueue_failed(conn, tenant_id, "reembed", reason)
    end
  end

  # STABLE error tag, raw reason to the LOG (review). `reason` here is whatever
  # `Oban.insert/1` returned — typically an `Ecto.Changeset` over `oban_jobs`, whose
  # `inspect/1` output carries schema and constraint internals. This is an
  # agent/orchestrator-facing endpoint and the rest of the API maps errors to stable
  # tags through `FallbackController`; leaking an internal structure into a 422 body
  # is neither useful to the caller nor safe to expose.
  defp enqueue_failed(conn, tenant_id, operation, reason) do
    Logger.error(
      "KnowledgeEmbeddingController: tenant=#{tenant_id} #{operation} enqueue failed: " <>
        inspect(reason)
    )

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "enqueue_failed",
      detail:
        "the #{operation} job could not be enqueued. This is a transient server-side " <>
          "condition; retry. The cause is recorded in the server log."
    })
  end

  defp parse_dimension(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_dimension(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, :invalid_dimension}
    end
  end

  defp parse_dimension(_), do: {:error, :invalid_dimension}
end
