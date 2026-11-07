defmodule Loopctl.Agents.Candidates do
  @moduledoc """
  One candidate read, built from a spec's predicate list (Epic 48, US-48.3).

  `TriageDispatcher.candidates/1` and `DispatchDriver.candidates/1` were the same ranked read
  written twice with different filters. Each is now `query(spec, limit: n)` over its spec's
  `candidates`, so a new spec picks its stories by naming predicates, never by writing a query.

  ## The closed set

  | predicate | the story is a candidate only when |
  |---|---|
  | `{:stage, stage}` | its stage row is at `stage` (exactly one per spec) |
  | `:intake_record_required` | it was filed from an intake record (inner join) |
  | `:intake_record_optional` | always; joins its record when it has one (left join) |
  | `:single_active_source` | its project is bound to exactly ONE unrevoked intake source |
  | `:issue_not_closed` | its issue's latest delivered state is not `closed` (NULL passes) |
  | `:requires_ticket_if_source_says` | its source does not set `triage_requires_ticket`, or its record carries a `ticket_id` |
  | `:no_live_dispatch_of_self` | no unreleased ledger row of the SPEC'S OWN kind names it |
  | `{:agent_status_in, statuses}` | its `agent_status` is one of `statuses` |
  | `:dependencies_met` | no unmet story or epic dependency (`Loopctl.WorkBreakdown.Dependencies`) |

  `validate/1` holds the combinations together: one stage, at most one intake-record predicate
  and one status list, `:issue_not_closed` and `:requires_ticket_if_source_says` only with a
  record joined, and the ticket predicate only with the single source it reads the flag from.
  `Loopctl.Agents.Spec` calls it while a spec module compiles, so a bad list is a build failure.

  ## Why each exclusion is IN the read rather than discovered per story

  Every one closes the same trap. A story the pass selects but cannot act on keeps its
  `updated_at` frozen, so it sits at the head of an oldest-first ranking for ever, and twenty
  of them fill every batch while the worker reports a clean run. A project with no source or
  two names no repository; a story with a live dispatch of the same kind is already being
  worked; a story whose dependencies are unmet is refused by `Placement` before it mints; a
  closed issue was finished or withdrawn (2026-11-07: every one of HCB's five support-ticket
  candidates had been fixed and closed days before the loop reached it).

  ## The ranking, `:round_robin_project_tenant`

  Oldest first within a project, every project's oldest before any project's second, every
  tenant's first before any tenant's second; ties broken on `story_id`. Whether a runner
  accepts a story's repository is decided per story AFTER this read, so a plain oldest-first
  ranking let one project's backlog fill the whole batch, the same batch every pass: on
  2026-11-06, 79 loopctl, chg and claude-config stories older than HCB's support tickets held
  all 20 slots against a fleet that accepts only HCB (#1019).

  ## Tenancy

  The read runs on `AdminRepo` (BYPASSRLS), so the explicit predicates are the only isolation:
  every join is on `tenant_id` as well as the id, and `tenant_id:` in `opts` scopes the whole
  read to one tenant. Without it the read is fleet-wide, which is what both passes want: one
  bound is shared by the whole fleet and the ranking is what keeps it fair.
  """

  import Ecto.Query

  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Intake.Record
  alias Loopctl.Intake.Source
  alias Loopctl.Runners.DispatchRecord
  alias Loopctl.WorkBreakdown.Dependencies
  alias Loopctl.WorkBreakdown.Story

  @type predicate ::
          {:stage, atom()}
          | :intake_record_required
          | :intake_record_optional
          | :single_active_source
          | :issue_not_closed
          | :requires_ticket_if_source_says
          | :no_live_dispatch_of_self
          | {:agent_status_in, [atom()]}
          | :dependencies_met

  @type order :: :round_robin_project_tenant

  @type candidates :: %{predicates: [predicate()], order: order()}

  @typedoc "One selected row: what both passes read."
  @type row :: %{
          tenant_id: Ecto.UUID.t(),
          story_id: Ecto.UUID.t(),
          updated_at: NaiveDateTime.t()
        }

  @record_predicates [:intake_record_required, :intake_record_optional]

  @atom_predicates @record_predicates ++
                     [
                       :single_active_source,
                       :issue_not_closed,
                       :requires_ticket_if_source_says,
                       :no_live_dispatch_of_self,
                       :dependencies_met
                     ]

  @orders [:round_robin_project_tenant]

  @doc "The predicates that take no argument; `{:stage, s}` and `{:agent_status_in, l}` do."
  @spec atom_predicates() :: [atom()]
  def atom_predicates, do: @atom_predicates

  @doc "The rankings."
  @spec orders() :: [order()]
  def orders, do: @orders

  @doc """
  `:ok`, or `{:error, message}` naming what is wrong with `candidates`.

  `candidates` is a spec's `candidates` field, `%{predicates: [...], order: ...}`.
  """
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(%{predicates: predicates, order: order} = candidates)
      when map_size(candidates) == 2 do
    with :ok <- check_list(predicates),
         :ok <- check_known(predicates),
         :ok <- check_combinations(predicates) do
      if order in @orders,
        do: :ok,
        else: {:error, "candidates.order #{inspect(order)} is not one of #{inspect(@orders)}"}
    end
  end

  def validate(value),
    do: {:error, "candidates must be %{predicates: [...], order: ...}, got #{inspect(value)}"}

  @doc """
  The candidate read for `spec`: at most `opts[:limit]` rows of `t:row/0`, in ranking order.

  Run it on `Loopctl.AdminRepo`. `spec` is a `Loopctl.Agents.Spec` (or any map with `kind` and
  `candidates`); `:no_live_dispatch_of_self` reads the ledger for `spec.kind`.

  ## Options

    * `:limit` (required) — a positive integer.
    * `:tenant_id` — scope the read to one tenant. Absent, the read is fleet-wide.

  Raises `ArgumentError` on a predicate list `validate/1` refuses or a missing `:limit`.
  """
  @spec query(
          %{
            required(:kind) => String.t(),
            required(:candidates) => candidates(),
            optional(atom()) => term()
          },
          keyword()
        ) :: Ecto.Query.t()
  def query(%{kind: kind, candidates: candidates}, opts) when is_list(opts) do
    limit = Keyword.get(opts, :limit)

    unless is_integer(limit) and limit > 0 do
      raise ArgumentError,
            "Candidates.query/2: :limit must be a positive integer, got #{inspect(limit)}"
    end

    case validate(candidates) do
      :ok -> :ok
      {:error, message} -> raise ArgumentError, "Candidates.query/2: " <> message
    end

    %{predicates: predicates, order: :round_robin_project_tenant} = candidates

    from(s in StoryStage,
      as: :stage,
      join: st in Story,
      as: :story,
      on: st.id == s.story_id and st.tenant_id == s.tenant_id
    )
    |> scope_tenant(Keyword.get(opts, :tenant_id))
    |> apply_predicates(predicates, kind)
    |> round_robin_project_tenant(limit)
  end

  # ── validation ──────────────────────────────────────────────────────────────────────────────

  defp check_list(predicates) do
    cond do
      not is_list(predicates) ->
        {:error, "candidates.predicates must be a list, got #{inspect(predicates)}"}

      predicates == [] ->
        {:error, "candidates.predicates must name at least one predicate"}

      Enum.uniq(predicates) != predicates ->
        {:error, "candidates.predicates names a predicate twice: #{inspect(predicates)}"}

      true ->
        :ok
    end
  end

  defp check_known(predicates) do
    case Enum.reject(predicates, &known?/1) do
      [] ->
        :ok

      unknown ->
        # Each inspected alone: a list of two-tuples would print as a keyword list.
        {:error,
         "candidates.predicates [#{Enum.map_join(unknown, ", ", &inspect/1)}] not in the " <>
           "closed set: " <>
           "#{inspect(@atom_predicates)}, {:stage, stage} with stage in " <>
           "StageMachine.stages/0, {:agent_status_in, statuses} with statuses a non-empty " <>
           "list of distinct Story.agent_statuses/0"}
    end
  end

  defp known?(predicate) when predicate in @atom_predicates, do: true
  defp known?({:stage, stage}), do: stage in StageMachine.stages()

  defp known?({:agent_status_in, statuses}) when is_list(statuses) and statuses != [],
    do: Enum.uniq(statuses) == statuses and Enum.all?(statuses, &(&1 in Story.agent_statuses()))

  defp known?(_predicate), do: false

  defp check_combinations(predicates) do
    with :ok <- check_cardinality(predicates), do: check_needs(predicates)
  end

  defp check_cardinality(predicates) do
    stages = for {:stage, _} = p <- predicates, do: p
    statuses = for {:agent_status_in, _} = p <- predicates, do: p
    records = Enum.filter(predicates, &(&1 in @record_predicates))

    cond do
      length(stages) != 1 ->
        {:error,
         "candidates.predicates must name exactly one {:stage, stage}, got #{inspect(stages)}"}

      length(statuses) > 1 ->
        {:error, "candidates.predicates may name at most one {:agent_status_in, statuses}"}

      length(records) > 1 ->
        {:error, "candidates.predicates may name at most one of #{inspect(@record_predicates)}"}

      true ->
        :ok
    end
  end

  # A filter that reads a binding only another predicate's join introduces: without one of
  # `any_of` the query would name a binding that does not exist.
  @needs [
    {:issue_not_closed, @record_predicates, "one of #{inspect(@record_predicates)}"},
    {:requires_ticket_if_source_says, @record_predicates,
     "one of #{inspect(@record_predicates)}"},
    {:requires_ticket_if_source_says, [:single_active_source],
     ":single_active_source, the source it reads triage_requires_ticket from"}
  ]

  defp check_needs(predicates) do
    Enum.find_value(@needs, :ok, fn {predicate, any_of, what} ->
      if predicate in predicates and not Enum.any?(any_of, &(&1 in predicates)),
        do: {:error, "candidates.predicates: #{inspect(predicate)} needs #{what}"}
    end)
  end

  # ── the read ────────────────────────────────────────────────────────────────────────────────

  defp scope_tenant(query, nil), do: query

  defp scope_tenant(query, tenant_id) when is_binary(tenant_id) do
    where(query, [stage: s, story: st], s.tenant_id == ^tenant_id and st.tenant_id == ^tenant_id)
  end

  # Joins before filters: a filter names the binding its join introduces, and `validate/1` has
  # already refused a filter whose join is absent.
  defp apply_predicates(query, predicates, kind) do
    predicates
    |> Enum.sort_by(&phase/1)
    |> Enum.reduce(query, &apply_predicate(&1, &2, kind))
  end

  defp phase(predicate) when predicate in [:single_active_source | @record_predicates], do: 0
  defp phase(_predicate), do: 1

  defp apply_predicate({:stage, stage}, query, _kind),
    do: where(query, [stage: s], s.stage == ^stage)

  # `bool_or/1` over a group of exactly one row is that row's flag: the aggregate is only how a
  # grouped query is allowed to name it.
  defp apply_predicate(:single_active_source, query, _kind) do
    bound_projects =
      from src in Source,
        where: is_nil(src.revoked_at),
        group_by: [src.tenant_id, src.project_id],
        having: count(src.id) == 1,
        select: %{
          tenant_id: src.tenant_id,
          project_id: src.project_id,
          requires_ticket: fragment("bool_or(?)", src.triage_requires_ticket)
        }

    join(query, :inner, [story: st], b in subquery(bound_projects),
      as: :source,
      on: b.tenant_id == st.tenant_id and b.project_id == st.project_id
    )
  end

  # Triage's payload IS the reporter's words, so a story with no record has nothing to triage.
  defp apply_predicate(:intake_record_required, query, _kind) do
    join(query, :inner, [story: st], rec in Record,
      as: :record,
      on: rec.id == st.intake_record_id and rec.tenant_id == st.tenant_id
    )
  end

  # An authored story (no record) stays a candidate; one with a record is read through it.
  defp apply_predicate(:intake_record_optional, query, _kind) do
    join(query, :left, [story: st], rec in Record,
      as: :record,
      on: rec.id == st.intake_record_id and rec.tenant_id == st.tenant_id
    )
  end

  # The state is the latest delivery's, so a reopened issue is a candidate again (#1022).
  defp apply_predicate(:issue_not_closed, query, _kind) do
    where(query, [record: rec], is_nil(rec.issue_state) or rec.issue_state != "closed")
  end

  # A source with `triage_requires_ticket` takes only an issue filed from a support ticket: one
  # whose record carries the `ticket_id` `Loopctl.Intake.TicketFacts` keeps only when a single
  # Ticket line AND a single HomeCareBilling footer agree on it (#1018). A structured fact, not
  # an untrusted field. It is still a CLAIM: whoever can open an issue can type both lines, so
  # on a private repository it keeps out issues filed in any other format, not a collaborator
  # set on forging one. Any other story is simply not a candidate and costs nothing.
  defp apply_predicate(:requires_ticket_if_source_says, query, _kind) do
    where(query, [source: b, record: rec], not b.requires_ticket or not is_nil(rec.ticket_id))
  end

  # The ledger row is the thing that ENDS: `Loopctl.Runners.Capacity.heal/3` releases a
  # reservation whose session outran its wall clock, so a dead session stops excluding its story
  # and the next pass sends a fresh dispatch. A row of ANOTHER kind does not exclude.
  defp apply_predicate(:no_live_dispatch_of_self, query, kind) when is_binary(kind) do
    live =
      from d in DispatchRecord,
        where: d.kind == ^kind and is_nil(d.released_at),
        where:
          d.tenant_id == parent_as(:stage).tenant_id and d.story_id == parent_as(:stage).story_id,
        select: 1

    where(query, not exists(subquery(live)))
  end

  defp apply_predicate({:agent_status_in, statuses}, query, _kind),
    do: where(query, [story: st], st.agent_status in ^statuses)

  # The claim's own definition (`Dependencies`), not a copy. Both read the story bound `:story`.
  # A story left out here is still visible as blocked (`Queries.list_blocked_stories/2`).
  defp apply_predicate(:dependencies_met, query, _kind) do
    query
    |> where(not exists(Dependencies.unmet_story_dependencies()))
    |> where(not exists(Dependencies.unmet_epic_dependencies()))
  end

  defp round_robin_project_tenant(filtered, limit) do
    ranked_in_project =
      from [stage: s, story: st] in filtered,
        select: %{
          tenant_id: s.tenant_id,
          story_id: s.story_id,
          updated_at: s.updated_at,
          project_rank:
            over(row_number(),
              partition_by: [st.tenant_id, st.project_id],
              order_by: [asc: s.updated_at, asc: s.story_id]
            )
        }

    ranked =
      from p in subquery(ranked_in_project),
        select: %{
          tenant_id: p.tenant_id,
          story_id: p.story_id,
          updated_at: p.updated_at,
          rank:
            over(row_number(),
              partition_by: p.tenant_id,
              order_by: [asc: p.project_rank, asc: p.updated_at, asc: p.story_id]
            )
        }

    from r in subquery(ranked),
      order_by: [asc: r.rank, asc: r.updated_at, asc: r.story_id],
      limit: ^limit,
      select: %{tenant_id: r.tenant_id, story_id: r.story_id, updated_at: r.updated_at}
  end
end
