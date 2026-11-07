defmodule Loopctl.ReplyDrafts do
  @moduledoc """
  Reply drafts (Epic 48, US-48.9): what `reply_draft@1` wrote for a support ticket that triage
  rejected or escalated, stored for a person to read and send.

  ## Nothing here sends anything

  A reply goes out in the operator's name, so loopctl STORES a draft and never delivers it: no
  forge call, no webhook, no mailer, no job (Epic 48 PRD, default 2). A person reads it
  through `GET /api/v1/projects/:project_id/reply_drafts` (`reply_draft_list` on the MCP
  server) and sends it themselves, or does not.

  ## The one effect, and the screen in front of it

  `reply_draft@1` names one effect, `:reply_draft`. `Loopctl.Agents.AgentResult` runs it
  inside the dispatch ledger's own transaction when a session's `agent_result` is recorded
  (`write_result/2`), so the ledger row and the draft commit together or not at all, once per
  dispatch.

  Before that, the body passes the `:injection_detector_draft` screen (`screen/1`): the SAME
  detector and the same calibrated signal set the drafted-story screen uses
  (`Loopctl.Delivery.TriageVerdict.draft_flags/1`). A body it flags is stored as a `refused`
  row carrying the screen code and the detector's own signal codes, and the body itself is NOT
  stored — not here, and not on the ledger row either (`withheld_result/1`): a refused body is
  instruction-shaped text a session produced after reading a stranger's words, and keeping it
  anywhere a person might copy it from is the failure the screen exists to prevent. What a
  person needs from a refusal is that it happened and why, which the codes say.

  A ticket too large to hand a session at all is refused at DISPATCH time instead
  (`refuse/4`, screen `:payload_too_large`), with no dispatch sent. Either way the story then
  has a row, so it is no longer a candidate (`:no_reply_draft`).

  ## Tenancy

  Every read and write is on the RLS `Loopctl.Repo` with an explicit `tenant_id` predicate as
  well, and every function takes `tenant_id` first. `write_result/2` runs inside a
  transaction the ledger already opened in that tenant.
  """

  import Ecto.Query

  alias Loopctl.Delivery.TriageVerdict
  alias Loopctl.Intake.Record
  alias Loopctl.KeysetCursor
  alias Loopctl.ReplyDrafts.ReplyDraft
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.WorkBreakdown.Story

  require Logger

  @injection_screen :injection_detector_draft
  @cursor_namespace "reply_draft_cursor"
  @default_limit 50
  @max_limit 100

  @typedoc "What `screen/1` decided about a body."
  @type screened :: {:drafted, String.t()} | {:refused, atom(), [String.t()]}

  @typedoc "One page of `list/3`."
  @type page :: %{
          data: [ReplyDraft.t()],
          has_more: boolean(),
          next_cursor: KeysetCursor.position() | nil
        }

  @doc "The screen a drafted body passes: `:injection_detector_draft`."
  @spec injection_screen() :: atom()
  def injection_screen, do: @injection_screen

  @doc """
  The `:injection_detector_draft` screen over a drafted reply body:
  `{:drafted, body}` when clean, `{:refused, :injection_detector_draft, signals}` when the
  detector's draft signals fire (`TriageVerdict.draft_flags/1`), with the detector's own
  `"<signal>:reply_body"` codes.
  """
  @spec screen(String.t()) :: screened()
  def screen(body) when is_binary(body) do
    case TriageVerdict.draft_flags([{"reply_body", body}]) do
      [] -> {:drafted, body}
      signals -> {:refused, @injection_screen, signals}
    end
  end

  @doc """
  What the dispatch ledger keeps of a result `screen/1` refused: the screen's name in place of
  the body, so the refused text is stored nowhere. A drafted result is kept whole.
  """
  @spec withheld_result(screened()) :: map() | nil
  def withheld_result({:refused, screen, _signals}), do: %{withheld: Atom.to_string(screen)}
  def withheld_result({:drafted, _body}), do: nil

  @doc """
  THE `:reply_draft` EFFECT: writes the draft row for the dispatch `record` just recorded a
  result on. Runs INSIDE the ledger's transaction (`Loopctl.Runners.DispatchLedger`), so it
  opens none of its own.

  The project and the ticket are read from loopctl's own rows — the story the dispatch names
  and its intake record — never from the result. A story whose record lost its ticket since
  the dispatch went out is stored `refused` with screen `:ticket_missing`, because a draft a
  person cannot match to a ticket is not one they can send. A story that no longer exists
  writes nothing.

  Idempotent: a second write for the same dispatch, or for a story that already has a row,
  inserts nothing (`ON CONFLICT DO NOTHING` over both unique indexes).
  """
  @spec write_result(DispatchRecord.t(), screened()) :: :ok
  def write_result(%DispatchRecord{tenant_id: tenant_id} = record, screened) do
    case story_facts(tenant_id, record.story_id) do
      nil ->
        Logger.warning(
          "ReplyDrafts: result for a story that no longer exists, nothing stored: " <>
            "dispatch_id=#{record.dispatch_id}",
          tenant_id: tenant_id
        )

        :ok

      {project_id, ticket_id} ->
        insert(%{
          tenant_id: tenant_id,
          project_id: project_id,
          story_id: record.story_id,
          dispatch_id: record.dispatch_id,
          ticket_id: ticket_id,
          screened: with_ticket(screened, ticket_id)
        })
    end
  end

  @doc """
  Stores a `refused` row for `story_id` WITHOUT a dispatch: the pass could not hand the ticket
  to a session at all (`screen`, e.g. `:payload_too_large`). Its own tenant transaction.
  `:ok` also when the story already has a row.
  """
  @spec refuse(Ecto.UUID.t(), Ecto.UUID.t(), atom(), [String.t()]) :: :ok | {:error, term()}
  def refuse(tenant_id, story_id, screen, signals \\ []) when is_atom(screen) do
    {:ok, result} =
      Repo.with_tenant(tenant_id, fn ->
        case story_facts(tenant_id, story_id) do
          nil ->
            {:error, :story_not_found}

          {project_id, ticket_id} ->
            insert(%{
              tenant_id: tenant_id,
              project_id: project_id,
              story_id: story_id,
              dispatch_id: nil,
              ticket_id: ticket_id,
              screened: {:refused, screen, signals}
            })
        end
      end)

    result
  end

  @doc """
  One page of `project_id`'s drafts in `tenant_id`, newest first.

  Options: `:limit` (default #{@default_limit}, at most #{@max_limit}) and `:cursor`, a
  position `decode_cursor/2` returned. `next_cursor` is the position to continue from, `nil`
  when the page is the last.
  """
  @spec list(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: {:ok, page()}
  def list(tenant_id, project_id, opts \\ []) do
    limit = (Keyword.get(opts, :limit) || @default_limit) |> min(@max_limit) |> max(1)

    query =
      from(d in ReplyDraft,
        where: d.tenant_id == ^tenant_id and d.project_id == ^project_id,
        order_by: [desc: d.inserted_at, desc: d.id],
        limit: ^(limit + 1)
      )
      |> after_cursor(Keyword.get(opts, :cursor))

    {:ok, rows} = Repo.with_tenant(tenant_id, fn -> Repo.all(query) end)
    {page, rest} = Enum.split(rows, limit)

    next =
      case {rest, List.last(page)} do
        {[_ | _], %ReplyDraft{} = last} -> {last.inserted_at, last.id}
        _ -> nil
      end

    {:ok, %{data: page, has_more: rest != [], next_cursor: next}}
  end

  @doc "The opaque, tenant-bound string for a `list/3` position."
  @spec encode_cursor(Ecto.UUID.t(), KeysetCursor.position()) :: String.t()
  def encode_cursor(tenant_id, position),
    do: KeysetCursor.encode(@cursor_namespace, tenant_id, position)

  @doc "A `list/3` position from its string, or `{:error, :invalid}` for any other string."
  @spec decode_cursor(Ecto.UUID.t(), String.t()) ::
          {:ok, KeysetCursor.position()} | {:error, :invalid}
  def decode_cursor(tenant_id, cursor),
    do: KeysetCursor.decode(@cursor_namespace, tenant_id, cursor)

  # ── internals ───────────────────────────────────────────────────────────────────────────────

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {%DateTime{} = at, id}) when is_binary(id) do
    where(query, [d], d.inserted_at < ^at or (d.inserted_at == ^at and d.id < ^id))
  end

  # The story's project and its intake record's ticket, from loopctl's own rows. Inside a
  # tenant transaction the caller holds.
  defp story_facts(tenant_id, story_id) do
    Repo.one(
      from st in Story,
        left_join: rec in Record,
        on: rec.id == st.intake_record_id and rec.tenant_id == st.tenant_id,
        where: st.id == ^story_id and st.tenant_id == ^tenant_id,
        select: {st.project_id, rec.ticket_id}
    )
  end

  defp with_ticket({:drafted, _body}, nil), do: {:refused, :ticket_missing, []}
  defp with_ticket(screened, _ticket_id), do: screened

  defp insert(%{screened: screened} = attrs) do
    {status, body, screen_code, signals} =
      case screened do
        {:drafted, body} -> {:drafted, body, nil, []}
        {:refused, screen, signals} -> {:refused, nil, Atom.to_string(screen), signals}
      end

    %ReplyDraft{
      tenant_id: attrs.tenant_id,
      project_id: attrs.project_id,
      story_id: attrs.story_id,
      dispatch_id: attrs.dispatch_id,
      ticket_id: attrs.ticket_id,
      status: status,
      body: body,
      screen_code: screen_code,
      screen_signals: signals
    }
    |> Repo.insert!(on_conflict: :nothing)

    :ok
  end
end
