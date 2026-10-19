defmodule Loopctl.Changes do
  @moduledoc """
  Story ↔ chg change bindings (US-47.1, Epic 47 PRD §4) — the one join both halves of the
  change protocol need.

  A story may bind several changes over its life (a revert, a re-submit); exactly one is
  CURRENT, the newest not superseded. The writer is the change-events webhook (US-47.3); the
  reader tool is US-47.7. Neither exists yet, so this module has no route and no MCP tool.

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
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Changes.Binding
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

      %Binding{story_id: story_id} when story_id == story.id ->
        Repo.rollback(:change_superseded)

      %Binding{} ->
        Repo.rollback(:change_bound_to_other_story)

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
      {:error, reason} -> Repo.rollback(reason)
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
