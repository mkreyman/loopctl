defmodule Loopctl.Changes do
  @moduledoc """
  Story ↔ chg change bindings (US-47.1, Epic 47 PRD §4) — the one join both halves of the
  change protocol need.

  A story may bind several changes over its life (a revert, a re-submit); exactly one is
  CURRENT, the newest not superseded. The writer is the change-events webhook (US-47.3,
  `Loopctl.Changes.Events`, through `bind_in_tenant_transaction/3` when a `submitted` event
  applies); the reader tool is US-47.7.

  ## What a bind refuses, and what it never reveals

  - **A story the tenant does not own never binds.** The story is read through RLS AND an
    explicit `tenant_id` predicate, so another tenant's story id is indistinguishable from an
    id nobody issued. Both answer `{:ok, :unbound}` and both record an
    `Loopctl.Changes.UnboundEvent` in the CALLING tenant — no row is written in the tenant
    that owns the story. See that module for why the event is not a nullable-story binding.
  - **A change binds one story.** The same `(repo, change_id)` re-bound to the SAME story
    returns the existing row while it is current (a redelivery is not an error). Once another
    change has superseded it, re-binding it is `{:error, :change_superseded}`: answering with
    the old row would read as "this change is current" while the story follows another one.
    Making a superseded change current again is a revert's decision (US-47.4), not a bind's.
    Bound to a DIFFERENT story it is `{:error, :change_bound_to_other_story}` — both stories
    are this tenant's own by then, so the refusal leaks nothing.
  - **Who submitted is not custody.** `bind/4` never writes `stories.assigned_agent_id` or
    `implementer_dispatch_id`. The submitter is an argument the CALLER resolved server-side
    (never a request field). It holds the claim only when its `agent_id` is the story's
    `assigned_agent_id` AND, on dispatch-minted work, its `actor_lineage` contains the story's
    `implementer_dispatch_id` (the implementer's dispatch or one beneath it) — the same agent
    in another session does not hold it. Otherwise (an unclaimed story included, and a machine
    caller with no lineage on dispatch-minted work) the binding is stored with
    `submitter_not_claimant: true`; the implementer of record is untouched either way.

  ## Concurrency

  Two guards, each backed by the database rather than by a read-then-write:

  - **One current binding per story.** The story row is locked `FOR NO KEY UPDATE` for the
    whole transaction, so two binds to one story serialize, and the second supersedes the
    first. The partial unique index `change_bindings_one_current_per_story` is the backstop:
    if the lock were ever lost, a second current row is a constraint error, never a fact.
    `NO KEY UPDATE` rather than `UPDATE` because the binding's own insert (and every other
    child row of the story) takes `FOR KEY SHARE` on the story, which `UPDATE` would block.
  - **One story per change.** Binds of one change to two DIFFERENT stories lock different
    story rows, so they race on the `(tenant_id, repo, change_id)` unique index instead. The
    insert is `ON CONFLICT DO NOTHING ... RETURNING`, the loser reads the winner's row, and its
    transaction — including the supersede it already made — rolls back.

  The lock waits are bounded (`Loopctl.Runners.Capacity.set_lock_timeout!/2`); contention
  answers `{:error, :busy}` through `Loopctl.Delivery.Stages.answering_busy/4`, which the
  webhook turns into a redelivery rather than a lost bind.

  ## Audit

  A new binding appends `change_bound`, and a new unbound event `change_unbound`, to the
  tenant's audit chain INSIDE the bind's transaction
  (`Loopctl.AuditChain.append_in_tenant_transaction/2`), announced after commit. An idempotent
  re-bind writes nothing, so it appends nothing.

  ## Reading a story's changes

  `story_changes/2` is what `GET /api/v1/stories/:id/changes` serves (US-47.7): the story's
  bindings OLDEST FIRST — the order they were made, so the current one is last — each with
  its change's APPLIED events in `event_seq` order. An event held ahead of a gap is not
  applied, so it is not listed. Both halves are bounded, by `max_bindings/0` and
  `max_events_per_change/0`; a truncated list keeps the NEWEST entries (the current binding
  is always present) and says so in its counts. The event's `data` and `effect` are not
  returned: `data` is untrusted chg-authored text, and nothing a reader of this list needs
  is in either.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Changes.Binding
  alias Loopctl.Changes.Event
  alias Loopctl.Changes.UnboundEvent
  alias Loopctl.Delivery.Stages
  alias Loopctl.Repo
  alias Loopctl.Runners.Capacity
  alias Loopctl.WorkBreakdown.Story

  @typedoc """
  The submitting principal as the CALLER resolved it server-side — never request data.
  `agent_id` is compared against the story's claim; `actor_lineage` attributes the audit-chain
  entry (`[]` for a machine caller holding no dispatch key, such as the change-events webhook).
  """
  @type submitter :: %{
          required(:agent_id) => Ecto.UUID.t() | nil,
          optional(:actor_lineage) => [String.t()]
        }

  @type bind_error ::
          Ecto.Changeset.t() | :change_bound_to_other_story | :change_superseded | :busy

  @input_types %{story_id: :string, repo: :string, change_id: :string}

  # The bounds on `story_changes/2`, held here once and read by the endpoint's response and its
  # operation spec alike (`LoopctlWeb.StoryChangeController`), so the documented limit and the
  # enforced one cannot drift. A change's life is a submit, a few revisions and their checks,
  # so 100 events holds every ordinary change whole; a story bound to more than 20 changes
  # has been re-submitted far past what a reader needs listed.
  @max_events_per_change 100
  @max_bindings 20

  @typedoc """
  One binding of `story_changes/2`: the row, its newest applied events (at most
  `max_events_per_change/0`, ascending `event_seq`), and how many applied events the change
  has in all.
  """
  @type story_change :: %{
          binding: Binding.t(),
          events: [Event.t()],
          applied_event_count: non_neg_integer()
        }

  @typedoc "`story_changes/2`'s answer: the listed bindings, oldest first, and their total."
  @type story_changes :: %{bindings: [story_change()], binding_count: non_neg_integer()}

  @doc """
  Binds `attrs.change_id` in `attrs.repo` to `attrs.story_id`.

  Returns `{:ok, binding}` (new, or the existing CURRENT row for an identical re-bind),
  `{:ok, :unbound}` when the story is not the tenant's — foreign, unknown and malformed ids
  alike — or `{:error, reason}` (`t:bind_error/0`).

  `opts` takes `:lock_timeout_ms` (tests only; see `Capacity.lock_timeout_ms/1`).
  """
  @spec bind(Ecto.UUID.t(), map(), submitter(), keyword()) ::
          {:ok, Binding.t() | :unbound} | {:error, bind_error()}
  def bind(tenant_id, attrs, submitter, opts \\ [])

  def bind(tenant_id, attrs, %{agent_id: agent_id} = submitter, opts)
      when is_binary(tenant_id) and is_map(attrs) and (is_nil(agent_id) or is_binary(agent_id)) do
    lineage = Map.get(submitter, :actor_lineage, [])

    with {:ok, input} <- validate_input(attrs) do
      Stages.answering_busy(tenant_id, [:loopctl, :changes, :bind_busy], "change bind", fn ->
        bind_valid(tenant_id, input, agent_id, lineage, opts)
      end)
    end
  end

  defp bind_valid(tenant_id, input, agent_id, lineage, opts) do
    tenant_id
    |> Repo.with_tenant(fn ->
      Capacity.set_lock_timeout!(Repo, opts)
      bind_in_transaction(tenant_id, input, agent_id, lineage)
    end)
    |> after_commit(tenant_id, input)
  end

  @typedoc """
  What `bind_in_tenant_transaction/3` did, for `after_bind_commit/1` to finish once the
  caller's transaction commits: `{outcome, tenant_id, input}`.
  """
  @type pending_bind ::
          {{:bound, Binding.t(), Entry.t()}
           | {:existing, Binding.t()}
           | {:unbound, Entry.t() | nil}
           | {:refused, bind_error()}, Ecto.UUID.t(), map()}

  @doc """
  `bind/4` INSIDE the caller's `Loopctl.Repo.with_tenant/2` transaction for `tenant_id` — for
  the change-events webhook (US-47.3), whose bind must commit or roll back with the event that
  carried it, under the lock it already holds on the change.

  A refusal that wrote nothing (`:change_bound_to_other_story`, `:change_superseded`, an
  invalid input) is RETURNED, inside `{:ok, pending}`, so the caller can record it and keep
  its own transaction; the lock-wait bound is the caller's. A failure after a write (the
  supersede already made) rolls the CALLER's transaction back, because nothing short of that
  undoes it. Pass the result to `after_bind_commit/1` after the caller commits: that is where
  the audit entry is announced and the unbound warning logged, as `bind/4` does.

  Raises outside a `Loopctl.Repo` transaction.
  """
  @spec bind_in_tenant_transaction(Ecto.UUID.t(), map(), submitter()) :: {:ok, pending_bind()}
  def bind_in_tenant_transaction(tenant_id, attrs, %{agent_id: agent_id} = submitter)
      when is_binary(tenant_id) and is_map(attrs) and (is_nil(agent_id) or is_binary(agent_id)) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "bind_in_tenant_transaction/3 needs a Loopctl.Repo transaction")

    lineage = Map.get(submitter, :actor_lineage, [])

    case validate_input(attrs) do
      {:ok, input} ->
        {:ok, {bind_in_transaction(tenant_id, input, agent_id, lineage), tenant_id, input}}

      {:error, changeset} ->
        {:ok, {{:refused, changeset}, tenant_id, attrs}}
    end
  end

  @doc """
  Finishes a `bind_in_tenant_transaction/3` after the caller's transaction committed, and
  answers what `bind/4` would have: `{:ok, binding}`, `{:ok, :unbound}` or `{:error, reason}`.
  """
  @spec after_bind_commit(pending_bind()) ::
          {:ok, Binding.t() | :unbound} | {:error, bind_error()}
  def after_bind_commit({outcome, tenant_id, input}),
    do: after_commit({:ok, outcome}, tenant_id, input)

  @doc "The story's current binding — the newest not superseded — or `nil`."
  @spec current_binding(Ecto.UUID.t(), Ecto.UUID.t()) :: Binding.t() | nil
  def current_binding(tenant_id, story_id) when is_binary(tenant_id) and is_binary(story_id) do
    {:ok, binding} =
      Repo.with_tenant(tenant_id, fn ->
        tenant_id
        |> story_bindings(story_id)
        |> where([b], is_nil(b.superseded_at))
        |> Repo.one()
      end)

    binding
  end

  @doc "Every binding the story has had, oldest first. `[]` for a story not the tenant's."
  @spec list_bindings(Ecto.UUID.t(), Ecto.UUID.t()) :: [Binding.t()]
  def list_bindings(tenant_id, story_id) when is_binary(tenant_id) and is_binary(story_id) do
    {:ok, bindings} =
      Repo.with_tenant(tenant_id, fn ->
        tenant_id
        |> story_bindings(story_id)
        |> order_by([b], asc: b.inserted_at, asc: b.id)
        |> Repo.all()
      end)

    bindings
  end

  @doc "The most applied events `story_changes/2` lists per change."
  @spec max_events_per_change() :: pos_integer()
  def max_events_per_change, do: @max_events_per_change

  @doc "The most bindings `story_changes/2` lists per story."
  @spec max_bindings() :: pos_integer()
  def max_bindings, do: @max_bindings

  @doc """
  The story's bindings, oldest first, each with its change's applied events — see "Reading a
  story's changes" above.

  `{:error, :not_found}` when the story is not the tenant's: another tenant's id, an id
  nobody issued and a malformed one answer alike. A tenant story with no binding is
  `{:ok, %{bindings: [], binding_count: 0}}`. Every read runs through `Repo` under the
  tenant's RLS context AND an explicit `tenant_id` predicate.
  """
  @spec story_changes(Ecto.UUID.t(), String.t()) :: {:ok, story_changes()} | {:error, :not_found}
  def story_changes(tenant_id, story_id) when is_binary(tenant_id) and is_binary(story_id) do
    with {:ok, id} <- Ecto.UUID.cast(story_id),
         {:ok, {:ok, changes}} <-
           Repo.with_tenant(tenant_id, fn -> read_story_changes(tenant_id, id) end) do
      {:ok, changes}
    else
      :error -> {:error, :not_found}
      {:ok, :not_found} -> {:error, :not_found}
    end
  end

  defp read_story_changes(tenant_id, story_id) do
    story? =
      Repo.exists?(from s in Story, where: s.id == ^story_id and s.tenant_id == ^tenant_id)

    if story?, do: {:ok, read_bindings(tenant_id, story_id)}, else: :not_found
  end

  # The newest `@max_bindings`, then put back oldest first. `binding_count` is the story's
  # total, so a reader can tell a truncated list from a whole one.
  defp read_bindings(tenant_id, story_id) do
    base = from(b in Binding, where: b.tenant_id == ^tenant_id and b.story_id == ^story_id)

    bindings =
      base
      |> order_by([b], desc: b.inserted_at, desc: b.id)
      |> limit(^@max_bindings)
      |> Repo.all()
      |> Enum.reverse()

    total = Repo.aggregate(base, :count)
    events = read_applied_events(tenant_id, Enum.map(bindings, & &1.id))

    %{
      binding_count: total,
      bindings:
        Enum.map(bindings, fn binding ->
          {listed, count} = Map.get(events, {binding.repo, binding.change_id}, {[], 0})
          %{binding: binding, events: listed, applied_event_count: count}
        end)
    }
  end

  # One query for every listed binding's events, not one per binding: each change's applied
  # events are ranked newest first and counted in a window, and the outer query keeps the
  # top `@max_events_per_change` of each. Answers `%{{repo, change_id} => {events, count}}`.
  defp read_applied_events(_tenant_id, []), do: %{}

  defp read_applied_events(tenant_id, binding_ids) do
    ranked =
      from e in Event,
        join: b in Binding,
        on: b.tenant_id == e.tenant_id and b.repo == e.repo and b.change_id == e.change_id,
        where: e.tenant_id == ^tenant_id and b.tenant_id == ^tenant_id,
        where: b.id in ^binding_ids and not is_nil(e.applied_at),
        windows: [
          newest: [partition_by: [e.repo, e.change_id], order_by: [desc: e.event_seq]],
          change: [partition_by: [e.repo, e.change_id]]
        ],
        select: %{
          id: e.id,
          rank: over(row_number(), :newest),
          applied_count: over(count(e.id), :change)
        }

    from(e in Event,
      join: r in subquery(ranked),
      on: r.id == e.id,
      where: e.tenant_id == ^tenant_id and r.rank <= ^@max_events_per_change,
      order_by: [asc: e.repo, asc: e.change_id, asc: e.event_seq],
      select: {e, r.applied_count}
    )
    |> Repo.all()
    |> Enum.group_by(fn {e, _count} -> {e.repo, e.change_id} end)
    |> Map.new(fn {key, [{_e, count} | _] = rows} ->
      {key, {Enum.map(rows, fn {e, _} -> e end), count}}
    end)
  end

  @doc "The tenant's unbound events for one change, oldest first."
  @spec list_unbound_events(Ecto.UUID.t(), String.t(), String.t()) :: [UnboundEvent.t()]
  def list_unbound_events(tenant_id, repo, change_id)
      when is_binary(tenant_id) and is_binary(repo) and is_binary(change_id) do
    {:ok, events} =
      Repo.with_tenant(tenant_id, fn ->
        Repo.all(
          from e in UnboundEvent,
            where: e.tenant_id == ^tenant_id and e.repo == ^repo and e.change_id == ^change_id,
            order_by: [asc: e.inserted_at, asc: e.id]
        )
      end)

    events
  end

  # A story id that is not a UUID cannot be a story, but it is still answered as an unknown
  # one: refusing it here would be a second, shape-based answer.
  defp story_bindings(tenant_id, story_id) do
    case Ecto.UUID.cast(story_id) do
      {:ok, id} -> from(b in Binding, where: b.tenant_id == ^tenant_id and b.story_id == ^id)
      :error -> from(b in Binding, where: false)
    end
  end

  defp validate_input(attrs) do
    {%{}, @input_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@input_types))
    |> Ecto.Changeset.validate_required(Map.keys(@input_types))
    |> Ecto.Changeset.validate_length(:repo, max: Binding.max_length())
    |> Ecto.Changeset.validate_length(:change_id, max: Binding.max_length())
    |> Ecto.Changeset.validate_length(:story_id, max: Binding.max_length())
    |> Ecto.Changeset.apply_action(:bind)
  end

  defp bind_in_transaction(tenant_id, input, agent_id, lineage) do
    case lock_story(tenant_id, input.story_id) do
      nil -> record_unbound(tenant_id, input, agent_id, lineage)
      story -> bind_story(tenant_id, story, input, agent_id, lineage)
    end
  end

  defp lock_story(tenant_id, story_id) do
    case Ecto.UUID.cast(story_id) do
      {:ok, id} ->
        Repo.one(
          from s in Story,
            where: s.id == ^id and s.tenant_id == ^tenant_id,
            lock: "FOR NO KEY UPDATE",
            select: %{
              id: s.id,
              assigned_agent_id: s.assigned_agent_id,
              implementer_dispatch_id: s.implementer_dispatch_id
            }
        )

      :error ->
        nil
    end
  end

  defp bind_story(tenant_id, story, input, agent_id, lineage) do
    case existing_binding(tenant_id, input) do
      %Binding{story_id: story_id, superseded_at: nil} = binding when story_id == story.id ->
        {:existing, binding}

      # Refused before anything is written, so the answer is returned rather than raised: a
      # caller inside its own transaction (`bind_in_tenant_transaction/3`) keeps it.
      %Binding{story_id: story_id} when story_id == story.id ->
        {:refused, :change_superseded}

      %Binding{} ->
        {:refused, :change_bound_to_other_story}

      nil ->
        insert_binding(tenant_id, story, input, agent_id, lineage)
    end
  end

  defp existing_binding(tenant_id, %{repo: repo, change_id: change_id}) do
    Repo.one(
      from b in Binding,
        where: b.tenant_id == ^tenant_id and b.repo == ^repo and b.change_id == ^change_id
    )
  end

  defp insert_binding(tenant_id, story, input, agent_id, lineage) do
    now = DateTime.utc_now()

    {_count, superseded_ids} =
      Repo.update_all(
        from(b in Binding,
          where: b.tenant_id == ^tenant_id and b.story_id == ^story.id,
          where: is_nil(b.superseded_at),
          select: b.id
        ),
        set: [superseded_at: now, updated_at: now]
      )

    not_claimant = not claimant?(story, agent_id, lineage)

    changeset =
      %Binding{
        tenant_id: tenant_id,
        submitter_agent_id: agent_id,
        submitter_not_claimant: not_claimant
      }
      |> Binding.create_changeset(%{
        story_id: story.id,
        repo: input.repo,
        change_id: input.change_id
      })

    with {:ok, binding} <- insert_new(changeset, story),
         {:ok, entry} <-
           AuditChain.append_in_tenant_transaction(tenant_id, %{
             action: "change_bound",
             actor_lineage: lineage,
             entity_type: "story",
             entity_id: story.id,
             payload: %{
               "binding_id" => binding.id,
               "repo" => binding.repo,
               "change_id" => binding.change_id,
               "superseded_binding_ids" => superseded_ids,
               "submitter_agent_id" => agent_id,
               "submitter_not_claimant" => not_claimant
             }
           }) do
      {:bound, binding, entry}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The submitting SESSION holds the claim, not merely the same agent: on dispatch-minted
  # work the submitter's lineage must contain the implementer's dispatch.
  defp claimant?(%{assigned_agent_id: nil}, _agent_id, _lineage), do: false
  defp claimant?(_story, nil, _lineage), do: false

  defp claimant?(
         %{assigned_agent_id: assigned, implementer_dispatch_id: dispatch_id},
         agent_id,
         lineage
       ) do
    assigned == agent_id and (is_nil(dispatch_id) or dispatch_id in lineage)
  end

  # `RETURNING` answers whether the row landed: `{1, [row]}` inserted, `{0, []}` lost the
  # `(tenant, repo, change_id)` key to a concurrent bind, whose row is then read. Losing to a
  # bind of the same story cannot happen under the story lock, but it is answered as the
  # idempotent re-bind it would be rather than assumed away.
  defp insert_new(%Ecto.Changeset{valid?: false} = changeset, _story), do: {:error, changeset}

  defp insert_new(changeset, story) do
    binding = Ecto.Changeset.apply_changes(changeset)
    now = DateTime.utc_now()

    row =
      binding
      |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})
      |> Map.take(Binding.__schema__(:fields))

    case Repo.insert_all(Binding, [row],
           on_conflict: :nothing,
           conflict_target: [:tenant_id, :repo, :change_id],
           returning: true
         ) do
      {1, [inserted]} ->
        {:ok, inserted}

      {0, []} ->
        case existing_binding(binding.tenant_id, binding) do
          %Binding{story_id: story_id} = winner when story_id == story.id ->
            {:error, {:lost_to, winner}}

          _other ->
            {:error, :change_bound_to_other_story}
        end
    end
  end

  # A redelivery of the same unbound bind inserts nothing (`{0, []}`), so it appends nothing.
  defp record_unbound(tenant_id, input, agent_id, lineage) do
    changeset =
      %UnboundEvent{tenant_id: tenant_id, submitter_agent_id: agent_id}
      |> UnboundEvent.create_changeset(%{
        repo: input.repo,
        change_id: input.change_id,
        claimed_story_id: input.story_id
      })

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, event} -> insert_unbound(tenant_id, input, event, agent_id, lineage)
      {:error, reason} -> {:refused, reason}
    end
  end

  defp insert_unbound(tenant_id, input, event, agent_id, lineage) do
    now = DateTime.utc_now()

    row =
      event
      |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})
      |> Map.take(UnboundEvent.__schema__(:fields))

    case Repo.insert_all(UnboundEvent, [row],
           on_conflict: :nothing,
           conflict_target: [:tenant_id, :repo, :change_id, :claimed_story_id],
           returning: [:id]
         ) do
      {1, [%{id: id}]} -> {:unbound, append_unbound(tenant_id, input, id, agent_id, lineage)}
      {0, []} -> {:unbound, nil}
    end
  end

  defp append_unbound(tenant_id, input, id, agent_id, lineage) do
    case AuditChain.append_in_tenant_transaction(tenant_id, %{
           action: "change_unbound",
           actor_lineage: lineage,
           entity_type: "unbound_change_event",
           entity_id: id,
           payload: %{
             "repo" => input.repo,
             "change_id" => input.change_id,
             "claimed_story_id" => input.story_id,
             "submitter_agent_id" => agent_id
           }
         }) do
      {:ok, entry} -> entry
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp after_commit({:ok, {:bound, binding, %Entry{} = entry}}, _tenant_id, _input) do
    AuditChain.announce_entry(entry)
    {:ok, binding}
  end

  defp after_commit({:ok, {:existing, binding}}, _tenant_id, _input), do: {:ok, binding}
  defp after_commit({:ok, {:refused, reason}}, _tenant_id, _input), do: {:error, reason}

  defp after_commit({:ok, {:unbound, entry}}, tenant_id, input) do
    if entry do
      AuditChain.announce_entry(entry)

      # No story id in the line: it is the payload's claim, and the event row holds it.
      Logger.warning(
        "change bind named a story this tenant does not own: tenant_id=#{tenant_id} " <>
          "repo=#{inspect(input.repo)} change_id=#{inspect(input.change_id)}"
      )
    end

    {:ok, :unbound}
  end

  defp after_commit({:error, {:lost_to, winner}}, _tenant_id, _input), do: {:ok, winner}
  defp after_commit({:error, reason}, _tenant_id, _input), do: {:error, reason}
end
