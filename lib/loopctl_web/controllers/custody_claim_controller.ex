defmodule LoopctlWeb.CustodyClaimController do
  @moduledoc """
  US-41.7 (AC-41.7.5) — the agent-readable custody-claim surface. JSON only; no
  UI, matching the epic's agent-native design principle.

  ## Role: `:agent` (read)

  A claim is a READ of the tenant's own recorded egress facts, and the whole
  point is that an agent can verify a harvest AFTER the fact with the key it
  already holds — the same argument that puts `GET /egress/posture` at `:agent`.
  It grants no destructive capability and no ability to weaken any gate.

  ## Visibility is ENFORCED, not advisory

  A claim discloses existence, the full operation timeline, occurred-at
  timestamps, endpoints and per-operation postures for one row. That is not the
  row's content, but it is plenty — and both subject kinds carry a per-caller
  visibility boundary that every other read enforces:

    * **memory** — `(tenant_id, subject_id)` is the ENFORCED isolation boundary
      (`Loopctl.Memory.Scope`), with `subject_id` derived server-side from the key.
      An `:agent` key may read claims only for its OWN memories.
    * **article** — `metadata.visibility` `private`/`owner` (#163). An `:agent` key
      may read claims only for articles it can SEE.

  Both are resolved BEFORE the claim is built, and both fail CLOSED (an unknown or
  invisible subject 404s). Higher roles are unfiltered, exactly as
  `LoopctlWeb.Helpers.Visibility` already specifies for reads.

  ## Failure surface

  `GET /custody/failures` lists entries whose chain append was dropped. A
  recording failure must be legible rather than silently absent, because a
  missing claim must never read as a satisfied one. It is the ENUMERABLE form of
  the surface above, so it is filtered by the same boundary: an agent sees only
  failures for subjects it can see.
  """

  use LoopctlWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Loopctl.ApiSpec.Schemas
  alias Loopctl.Custody
  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias LoopctlWeb.Helpers.Visibility

  action_fallback LoopctlWeb.FallbackController

  tags(["Custody"])

  @json "application/json"
  @free_object %OpenApiSpex.Schema{type: :object, additionalProperties: true}

  plug LoopctlWeb.Plugs.RequireRole, [role: :agent] when action in [:show, :failures]

  operation(:show,
    summary: "Egress custody claim for an article or memory",
    description:
      "Returns the recorded per-operation egress postures for one article or memory row " <>
        "and the aggregate claim over them. Three states: 'no_claim_recorded', " <>
        "'claim_pending', or 'claim_recorded' (itself 'complete', 'partial_history' or " <>
        "'incomplete'). `third_party_egress_on_covered_paths` is false ONLY when every " <>
        "recorded endpoint was NETWORK-local; a tenant-declared (unverified) endpoint " <>
        "yields 'tenant_declared_unverified'. The " <>
        "claim attests ONLY to the endpoints loopctl called for the recorded operations on " <>
        "this row, on the egress paths listed in `coverage` — never to what those " <>
        "endpoints did with the data afterwards, and never to a path listed as uncovered. " <>
        "Role :agent.",
    parameters: [
      subject_type: [in: :path, type: :string, description: "article | memory", required: true],
      subject_id: [in: :path, type: :string, description: "Row UUID", required: true]
    ],
    responses: %{
      200 => {"Custody claim", @json, @free_object},
      400 => {"Invalid subject type", @json, Schemas.ErrorResponse},
      401 => {"Unauthorized", @json, Schemas.ErrorResponse}
    }
  )

  def show(conn, %{"subject_type" => subject_type, "subject_id" => subject_id}) do
    key = conn.assigns.current_api_key

    # `subject_id` is a raw path segment compared against a `:binary_id` column, so
    # a non-UUID raised `Ecto.Query.CastError` -> 500 on a request any agent key
    # could make. 400 it before it reaches a query.
    with {:ok, subject_id} <- cast_subject_id(subject_id),
         :ok <- authorize_subject(conn, key, subject_type, subject_id),
         {:ok, claim} <- Custody.claim(key.tenant_id, subject_type, subject_id) do
      json(conn, %{data: claim})
    else
      {:error, {:not_visible, subject_id}} ->
        # Deliberately INDISTINGUISHABLE from a row that has no claim: a 404 (or any
        # differently-shaped response) would confirm the existence of another agent's
        # private subject, which is most of what this gate exists to withhold.
        json(conn, %{data: Custody.absent_claim(key.tenant_id, subject_type, subject_id)})

      {:error, :invalid_subject_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: %{message: "subject_id must be a UUID", code: "invalid_subject_id", status: 400}
        })

      {:error, :invalid_subject_type} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: %{
            message: "subject_type must be one of: article, memory",
            code: "invalid_subject_type",
            status: 400
          }
        })
    end
  end

  defp cast_subject_id(subject_id) do
    case Ecto.UUID.cast(subject_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_subject_id}
    end
  end

  # Fails CLOSED: an unknown subject, an invisible one, or a key whose memory
  # subject cannot be resolved all yield `{:not_visible, id}` — which the caller
  # renders as the ordinary "no claim recorded" payload.
  defp authorize_subject(conn, key, "article", subject_id) do
    if Knowledge.article_visible?(key.tenant_id, subject_id, visibility_agent_id(conn)) do
      :ok
    else
      {:error, {:not_visible, subject_id}}
    end
  end

  defp authorize_subject(_conn, %{role: :agent} = key, "memory", subject_id) do
    case Memory.subject_id_for(key) do
      {:ok, owner} ->
        if Memory.memory_owned?(key.tenant_id, owner, subject_id),
          do: :ok,
          else: {:error, {:not_visible, subject_id}}

      {:error, _} ->
        {:error, {:not_visible, subject_id}}
    end
  end

  # Non-agent roles (orchestrator/user/superadmin) are the trusted/observability
  # roles — the same line `LoopctlWeb.Helpers.Visibility` draws for article reads.
  defp authorize_subject(_conn, _key, "memory", _subject_id), do: :ok

  # Unknown subject_type: let `Custody.claim/3` produce the 400.
  defp authorize_subject(_conn, _key, _subject_type, _subject_id), do: :ok

  operation(:failures,
    summary: "Custody posture entries whose chain append was dropped or stranded",
    description:
      "Recording failures are surfaced, never silently dropped: each entry here degrades " <>
        "its row's claim to 'incomplete'. `stale_pending` lists entries that have been " <>
        "in flight longer than the stale window — a flush that died outside its own " <>
        "final-attempt error branch never marks anything failed, so without this those " <>
        "rows would read as an in-flight claim indefinitely and appear nowhere. Role :agent.",
    responses: %{
      200 => {"Failed and stranded custody posture entries", @json, @free_object},
      401 => {"Unauthorized", @json, Schemas.ErrorResponse}
    }
  )

  def failures(conn, _params) do
    key = conn.assigns.current_api_key

    # Filtered by the SAME boundary as `show/2`: this is the enumerable form of the
    # claim surface, and it emits subject_type/subject_id per row.
    visible = &visible_entries(conn, key, &1)

    failed = key.tenant_id |> Custody.list_failures() |> visible.() |> Enum.map(&render_entry/1)

    stale =
      key.tenant_id |> Custody.list_stale_pending() |> visible.() |> Enum.map(&render_entry/1)

    json(conn, %{
      data: failed,
      stale_pending: stale,
      meta: %{
        count: length(failed),
        stale_pending_count: length(stale),
        stale_pending_after_seconds: Custody.stale_pending_seconds()
      }
    })
  end

  defp visible_entries(conn, key, entries) do
    article_ids = subject_ids(entries, "article")
    memory_ids = subject_ids(entries, "memory")

    visible_articles =
      Knowledge.visible_article_ids(key.tenant_id, article_ids, visibility_agent_id(conn))

    visible_memories = MapSet.new(visible_memory_ids(key, memory_ids))

    Enum.filter(entries, fn entry ->
      case entry.subject_type do
        "article" -> MapSet.member?(visible_articles, entry.subject_id)
        "memory" -> MapSet.member?(visible_memories, entry.subject_id)
        _ -> false
      end
    end)
  end

  # `nil` for the trusted/observability roles (orchestrator/user/superadmin), the
  # agent's own id for an agent key — the same line `LoopctlWeb.Helpers.Visibility`
  # draws for every other read.
  defp visibility_agent_id(conn) do
    conn |> Visibility.scope_opts() |> Keyword.get(:visibility_agent_id)
  end

  defp subject_ids(entries, subject_type) do
    entries
    |> Enum.filter(&(&1.subject_type == subject_type))
    |> Enum.map(& &1.subject_id)
    |> Enum.uniq()
  end

  defp visible_memory_ids(%{role: :agent} = key, memory_ids) do
    case Memory.subject_id_for(key) do
      {:ok, owner} -> Memory.owned_memory_ids(key.tenant_id, owner, memory_ids)
      {:error, _} -> []
    end
  end

  defp visible_memory_ids(_key, memory_ids), do: memory_ids

  defp render_entry(entry) do
    %{
      subject_type: entry.subject_type,
      subject_id: entry.subject_id,
      operation_sequence: entry.operation_sequence,
      operation: entry.operation,
      occurred_at: entry.occurred_at,
      state: entry.state,
      outcome: entry.outcome,
      local_endpoints_only: entry.local_endpoints_only,
      network_local_endpoints_only: Map.get(entry.posture, "network_local_endpoints_only", false),
      failure_reason: entry.failure_reason
    }
  end
end
